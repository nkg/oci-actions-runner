#!/usr/bin/env bash
# entrypoint.sh — register a single ephemeral GitHub Actions runner,
# run one job, and exit.
#
# Contract (env vars consumed at start time):
#
#   RUNNER_URL       (required)  https://github.com/{owner}/{repo}
#                                  or https://github.com/{owner}
#   RUNNER_TOKEN     (required)  single-use registration token from
#                                  GitHub (or token-server / dispatcher)
#   RUNNER_REMOVE_TOKEN (optional) removal token, used to deregister on
#                                  SIGTERM. This is a DIFFERENT
#                                  credential from RUNNER_TOKEN — see
#                                  the cleanup() comment below.
#   RUNNER_LABELS    (optional)  comma-separated labels (default:
#                                  "self-hosted,linux")
#   RUNNER_NAME      (optional)  defaults to the container hostname
#   RUNNER_GROUP     (optional)  runner group (default: "default")
#   RUNNER_EPHEMERAL (optional)  "true" → register with --ephemeral
#                                  (default: "true")
#   RUNNER_WORK_DIR  (optional)  defaults to _work
#   EXTRA_RUNNER_ARGS (optional) appended verbatim to config.sh
#
# This script is *intentionally tiny* — the upstream actions/runner
# package handles registration, job execution, deregistration, and
# self-cleanup. We're just shelling it with the right flags.

set -euo pipefail

: "${RUNNER_URL:?RUNNER_URL is required}"
: "${RUNNER_TOKEN:?RUNNER_TOKEN is required}"

RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux}"
RUNNER_REMOVE_TOKEN="${RUNNER_REMOVE_TOKEN:-}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_GROUP="${RUNNER_GROUP:-default}"
RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-true}"
RUNNER_WORK_DIR="${RUNNER_WORK_DIR:-_work}"
EXTRA_RUNNER_ARGS="${EXTRA_RUNNER_ARGS:-}"

cd /home/runner/runner

# Build the config.sh invocation. --unattended is required (no
# interactive prompts in a container); --replace lets the same
# RUNNER_NAME re-register cleanly after a previous instance died.
config_args=(
  --unattended
  --replace
  --url        "${RUNNER_URL}"
  --token      "${RUNNER_TOKEN}"
  --name       "${RUNNER_NAME}"
  --runnergroup "${RUNNER_GROUP}"
  --labels     "${RUNNER_LABELS}"
  --work       "${RUNNER_WORK_DIR}"
)

if [[ "${RUNNER_EPHEMERAL}" == "true" ]]; then
  config_args+=(--ephemeral)
fi

# shellcheck disable=SC2206  # word-splitting EXTRA_RUNNER_ARGS is intentional
extra_args=( ${EXTRA_RUNNER_ARGS} )

# Graceful shutdown: on SIGTERM (Nomad kill, container stop),
# deregister the runner so GitHub doesn't show a ghost offline runner.
#
# Deregistration needs a *removal* token, which is a different
# credential from the registration token in RUNNER_TOKEN — and the
# registration token is single-use, already spent by config.sh below.
# Passing it to `config.sh remove` (as this script used to) always
# fails. Supply RUNNER_REMOVE_TOKEN — e.g. from gha-token-server's
# /remove-token endpoint — to make shutdown deregistration work.
#
# With RUNNER_EPHEMERAL=true (the default, and what the dispatcher
# sets) GitHub retires the registration itself after the single job,
# so a removal token is only needed for long-lived runners.
#
# Disable covers two rules fired on trap-invoked code:
#   SC2329 — "function is never invoked" (called via trap)
#   SC2317 — "command appears unreachable" (older linters raise this
#            for every line inside; newer ones recognise the trap)
# shellcheck disable=SC2317,SC2329
cleanup() {
  if [[ -n "${RUNNER_REMOVE_TOKEN}" ]]; then
    echo "[entrypoint] SIGTERM received — deregistering runner"
    ./config.sh remove --token "${RUNNER_REMOVE_TOKEN}" \
      || echo "[entrypoint] warning: deregistration failed" >&2
  elif [[ "${RUNNER_EPHEMERAL}" == "true" ]]; then
    echo "[entrypoint] SIGTERM received — ephemeral runner, GitHub retires the registration on its own"
  else
    echo "[entrypoint] SIGTERM received — no RUNNER_REMOVE_TOKEN set;" \
         "runner will linger as offline in GitHub until removed" >&2
  fi
  exit 0
}

# Installed before registration: a SIGTERM arriving mid-`config.sh`
# was previously unhandled, because the trap was only set afterwards.
trap cleanup SIGTERM SIGINT

echo "[entrypoint] registering runner ${RUNNER_NAME} against ${RUNNER_URL}"
./config.sh "${config_args[@]}" "${extra_args[@]}"

echo "[entrypoint] starting runner"
./run.sh &
runner_pid=$!

# `wait` yields the child's exit status. Under `set -e` a non-zero
# status aborts the script at this line, which would skip the log
# below — so capture it explicitly instead of reading $? afterwards.
exit_code=0
wait "${runner_pid}" || exit_code=$?

# With --ephemeral, the runner exits cleanly after one job. The
# Nomad job is `type = "batch"`, so a clean exit ends the allocation.
echo "[entrypoint] runner exited with ${exit_code}"
exit "${exit_code}"
