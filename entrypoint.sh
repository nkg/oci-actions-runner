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
#   RUNNER_IDLE_TIMEOUT (optional) seconds to wait for a FIRST job
#                                  before giving up and exiting. Unset
#                                  or 0 disables it. See the watchdog
#                                  below for why this exists.
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
RUNNER_IDLE_TIMEOUT="${RUNNER_IDLE_TIMEOUT:-0}"

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

# Idle watchdog: give up if no job is ever claimed.
#
# An --ephemeral runner exits after ONE job, but BEFORE its first job it
# waits indefinitely. That matters because the dispatcher spawns a
# runner per queued workflow_job without checking labels: a runner
# created for a job another runner claimed, or for a job whose labels it
# cannot satisfy, does not fail — it sits at "Listening for Jobs"
# holding its Nomad allocation.
#
# Observed 2026-09-15: eight of eight allocations idle, one having
# waited 18h21m before picking up unrelated work, while eleven jobs
# queued elsewhere. On a single-tenant pool that is untidy; on a shared
# one it is starvation, because a second owner never gets a slot.
#
# Detecting "a job started" without procps (deliberately not in this
# image): the agent forks Runner.Worker per job, so scan /proc for it.
# This asks "is a job running NOW", which is the right question — a job
# that had already finished would have exited the ephemeral runner and
# taken the container with it.
if [[ "${RUNNER_IDLE_TIMEOUT}" =~ ^[0-9]+$ ]] && (( RUNNER_IDLE_TIMEOUT > 0 )); then
  (
    sleep "${RUNNER_IDLE_TIMEOUT}"
    for f in /proc/[0-9]*/cmdline; do
      # Guard the glob: if it matches nothing it stays literal, and the
      # redirection below would fail noisily before tr could swallow it.
      # A process can also exit between the glob and the read.
      [[ -r "${f}" ]] || continue
      # tr because cmdline is NUL-separated.
      if tr '\0' ' ' < "${f}" 2>/dev/null | grep -q 'Runner\.Worker'; then
        exit 0   # a job is running — leave it alone
      fi
    done
    echo "[entrypoint] no job claimed within ${RUNNER_IDLE_TIMEOUT}s —" \
         "exiting so the allocation is reclaimed"
    # TERM, not KILL: run.sh unwinds cleanly, so the runner does not
    # linger in GitHub as an offline registration.
    kill -TERM "${runner_pid}" 2>/dev/null || true
  ) &
  watchdog_pid=$!
  echo "[entrypoint] idle watchdog armed (${RUNNER_IDLE_TIMEOUT}s)"
fi

# `wait` yields the child's exit status. Under `set -e` a non-zero
# status aborts the script at this line, which would skip the log
# below — so capture it explicitly instead of reading $? afterwards.
exit_code=0
wait "${runner_pid}" || exit_code=$?

# Stop the watchdog before it can fire against a finished run: it would
# otherwise sleep out its full timeout and then signal a PID that may by
# then belong to something else.
if [[ -n "${watchdog_pid:-}" ]]; then
  kill "${watchdog_pid}" 2>/dev/null || true
fi

# With --ephemeral, the runner exits cleanly after one job. The
# Nomad job is `type = "batch"`, so a clean exit ends the allocation.
echo "[entrypoint] runner exited with ${exit_code}"
exit "${exit_code}"
