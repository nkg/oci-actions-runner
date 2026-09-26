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
#   DOCKER_SOCKET    (optional)  docker-compatible socket jobs talk to
#                                  (default: /var/run/docker.sock). See
#                                  the socket-group block below.
#   EXTRA_RUNNER_ARGS (optional) appended verbatim to config.sh
#
# This script is *intentionally tiny* — the upstream actions/runner
# package handles registration, job execution, deregistration, and
# self-cleanup. We're just shelling it with the right flags.

set -euo pipefail

# Socket group: make the mounted socket usable by the runner user.
#
# The dispatcher mounts the host's rootful podman socket here, and podman
# creates it root:root 0660. The agent runs as `runner` (uid 1001), which
# is in neither, so EVERY job step that touches docker failed with
# "permission denied while trying to connect to the docker API" — while
# the rest of the job ran fine, which is what made it look like the
# job's fault. Observed 2026-09-26 on sproncy-secrets-deploy's compose
# integration job, the first docker-using job routed to this pool.
#
# The fix is group membership, not a chmod: the socket is a bind mount,
# so loosening its mode here would loosen it on the host for everyone.
# Supplementary groups are fixed when a process starts, so adding the
# group is not enough on its own — the script re-executes itself through
# sudo, which re-reads group membership (initgroups) for the new process,
# and the agent it starts inherits it.
#
# This grants nothing new. Holding this socket already means host root,
# and `runner` already has passwordless sudo (see the Dockerfile) — this
# only spends that sudo once, up front, instead of leaving every job to
# discover it needs `sudo docker`.
#
# The cleaner fix is the runtime adding the group itself (podman/Nomad
# `group_add = ["<socket gid>"]`), after which -w is already true and
# this block does nothing. Where sudo is unavailable (e.g. the container
# runs with no-new-privileges) it says so and carries on: registering a
# runner whose docker steps fail beats not registering one at all.
DOCKER_SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"
if [[ -S "${DOCKER_SOCKET}" && ! -w "${DOCKER_SOCKET}" \
      && -z "${_ENTRYPOINT_SOCKET_GROUP_DONE:-}" ]]; then
  sock_gid="$(stat -c %g "${DOCKER_SOCKET}")"
  me="$(id -un)"
  if sudo -n true 2>/dev/null; then
    sock_group="$(getent group "${sock_gid}" | cut -d: -f1 || true)"
    if [[ -z "${sock_group}" ]]; then
      sudo -n groupadd --gid "${sock_gid}" docker-host
      sock_group=docker-host
    fi
    sudo -n usermod -aG "${sock_group}" "${me}"
    echo "[entrypoint] ${DOCKER_SOCKET} is not writable by ${me};" \
         "added ${me} to group ${sock_group} (gid ${sock_gid}) and re-executing"
    # PATH is passed explicitly because sudo's secure_path would otherwise
    # replace it and drop /mise/shims, which the toolchain contract puts
    # first. The guard variable stops a second pass if the socket is still
    # not writable (e.g. an ACL or SELinux label is what's refusing us).
    exec sudo -n -E -u "${me}" -- env "PATH=${PATH}" \
      _ENTRYPOINT_SOCKET_GROUP_DONE=1 "$0" "$@"
  fi
  echo "[entrypoint] warning: ${DOCKER_SOCKET} (gid ${sock_gid}) is not writable by ${me}" \
       "and sudo is unavailable; docker steps will fail. Add the socket's group to the" \
       "container (e.g. podman/Nomad group_add = [\"${sock_gid}\"])." >&2
fi

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

# Overridable only so tests/entrypoint-shutdown-test.sh can point the
# script at stub config.sh/run.sh. Nothing in the image sets it, and
# the default is the only path production takes.
RUNNER_DIR="${RUNNER_DIR:-/home/runner/runner}"
cd "${RUNNER_DIR}"

# Where the idle watchdog looks for a running job. Overridable only so
# the tests can point it at a fixture directory: the runner container
# has its own PID namespace, so scanning /proc there sees this runner's
# processes and nothing else — but a test running on a CI machine would
# see that machine's real runner agent and conclude a job was in
# flight. Nothing in the image sets it.
RUNNER_PROC_DIR="${RUNNER_PROC_DIR:-/proc}"

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
  echo "[entrypoint] SIGTERM received — shutting down"

  # Stop the agent BEFORE deregistering. `config.sh remove` refuses
  # while the listener is running, so a remove issued first fails with
  # a message about the runner still being configured — which is how
  # this looked when it was tried the other way round.
  #
  # `wait` rather than a bare kill: the listener needs to finish
  # unwinding before its registration can be removed, and this trap is
  # entered from the `wait` below, so the child is still ours to reap.
  if [[ -n "${runner_pid:-}" ]] && kill -0 "${runner_pid}" 2>/dev/null; then
    kill -TERM "${runner_pid}" 2>/dev/null || true
    wait "${runner_pid}" 2>/dev/null || true
  fi

  if [[ -n "${RUNNER_REMOVE_TOKEN}" ]]; then
    echo "[entrypoint] deregistering runner"
    ./config.sh remove --token "${RUNNER_REMOVE_TOKEN}" \
      || echo "[entrypoint] warning: deregistration failed" >&2
  else
    # This used to claim that an ephemeral runner needs no removal
    # token because "GitHub retires the registration on its own". That
    # is true only after the runner COMPLETES a job. A listener that is
    # stopped before claiming its first — which is exactly what the
    # idle watchdog below does — leaves an offline registration behind.
    # Measured 2026-09-18 on the sproncy org: 90 offline registrations,
    # 0 online.
    echo "[entrypoint] no RUNNER_REMOVE_TOKEN set; if this runner never ran a job" \
         "its registration will linger as offline in GitHub until removed" >&2
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
    for f in "${RUNNER_PROC_DIR}"/[0-9]*/cmdline; do
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
    # Signal THIS SCRIPT, not run.sh. Sending TERM straight to the
    # child stops the agent but bypasses the trap above, so nothing
    # ever deregisters — the runner lingers as an offline registration
    # and the container exits 143, which Nomad reports as a failed
    # allocation for what is a designed reclaim. Going through cleanup
    # gives one shutdown path, exercised both by the watchdog and by
    # Nomad's own SIGTERM.
    #
    # `$$` is the PID of the script, not of this subshell, which is
    # what makes this work ($BASHPID would be the subshell). PID 1
    # ignores signals it has no handler for; this one is trapped.
    kill -TERM "$$" 2>/dev/null || true
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
