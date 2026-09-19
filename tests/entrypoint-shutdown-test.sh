#!/usr/bin/env bash
# Tests for entrypoint.sh's shutdown path.
#
# This path exists because it went wrong silently. Before this test,
# entrypoint.sh's idle watchdog sent SIGTERM to run.sh with the comment
# "run.sh unwinds cleanly, so the runner does not linger in GitHub as an
# offline registration". That was a prediction, not a fact: signalling
# the child bypasses the script's own trap, so nothing deregistered and
# the sproncy org accumulated 90 offline registrations against 0 online
# before anyone looked.
#
# Nothing here needs docker, a network, or a real runner package: the
# entrypoint shells out to config.sh and run.sh, so stubbing those two
# is enough to observe what it does and in what order.
#
# Run:  tests/entrypoint-shutdown-test.sh

# Each case runs the entrypoint inside its own ( … ) with its own
# exported RUNNER_* values, precisely so one case cannot leak
# configuration into the next. shellcheck reads that isolation as a
# mistake; here it is the design.
# shellcheck disable=SC2030,SC2031

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="${REPO_ROOT}/entrypoint.sh"

pass=0
fail=0

ok() {
  echo "  ok   — $1"
  pass=$((pass + 1))
}

bad() {
  echo "  FAIL — $1"
  fail=$((fail + 1))
}

# Builds a throwaway runner directory holding stub config.sh and run.sh.
#
# config.sh appends its argv to actions.log, so the test can assert both
# THAT deregistration happened and that it happened after the agent
# stopped — ordering is the half that was broken.
#
# run.sh traps SIGTERM and lingers briefly before exiting, standing in
# for a listener that needs a moment to unwind. A stub that died
# instantly would pass even if cleanup never waited for it.
make_runner_dir() {
  local dir="$1"
  mkdir -p "${dir}" "${dir}/proc"

  cat > "${dir}/config.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "config.sh $*" >> "${RUNNER_DIR}/actions.log"
exit 0
STUB

  # The trap kills its own sleep before exiting. Without that the sleep
  # is orphaned still holding the entrypoint's stdout, and the command
  # substitution that collects the exit code blocks on the pipe until it
  # expires — turning any failure in this file into a multi-minute wait
  # rather than an immediate answer.
  cat > "${dir}/run.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "run.sh started" >> "${RUNNER_DIR}/actions.log"
# Long enough that nothing here finishes on its own — every exit in
# these tests has to come from the entrypoint deciding to shut down.
sleep 30 &
child=$!
trap 'printf "%s\n" "run.sh got SIGTERM" >> "${RUNNER_DIR}/actions.log"; kill "${child}" 2>/dev/null; sleep 0.3; exit 0' SIGTERM
wait "${child}"
STUB

  chmod +x "${dir}/config.sh" "${dir}/run.sh"
}

# Runs entrypoint.sh against a stub dir and prints its exit code.
run_entrypoint() {
  local dir="$1"
  shift
  (
    cd "${dir}" || exit 99
    export RUNNER_DIR="${dir}"
    export RUNNER_PROC_DIR="${dir}/proc"
    export RUNNER_URL="https://github.com/example"
    export RUNNER_TOKEN="stub-registration-token"
    export RUNNER_NAME="stub-runner"
    "$@" bash "${ENTRYPOINT}" > "${dir}/stdout.log" 2>&1
    echo "$?" > "${dir}/exit_code"
  )
  cat "${dir}/exit_code"
}

# ── 1. idle timeout with a removal token ────────────────────────────
#
# The case the fleet actually runs, once the dispatcher supplies a
# removal token: no job arrives, the watchdog fires, and the runner must
# deregister itself rather than leaving a ghost.
echo "case: idle timeout, removal token present"
dir="$(mktemp -d)"
make_runner_dir "${dir}"
code="$(run_entrypoint "${dir}" env RUNNER_IDLE_TIMEOUT=1 RUNNER_REMOVE_TOKEN=stub-remove-token)"

if [[ "${code}" == "0" ]]; then
  ok "exits 0 (a reclaim is a designed outcome, not a failed allocation)"
else
  bad "exit code = ${code}, want 0"
fi

if grep -q 'config.sh remove --token stub-remove-token' "${dir}/actions.log"; then
  ok "deregisters with the removal token"
else
  bad "no 'config.sh remove' in actions.log:
$(sed 's/^/        /' "${dir}/actions.log")"
fi

# The ordering assertion. `config.sh remove` refuses while the listener
# is running, so a remove issued before the agent stops is a remove that
# silently fails.
term_line="$(grep -n 'run.sh got SIGTERM' "${dir}/actions.log" | head -1 | cut -d: -f1)"
remove_line="$(grep -n 'config.sh remove' "${dir}/actions.log" | head -1 | cut -d: -f1)"
if [[ -n "${term_line}" && -n "${remove_line}" && "${term_line}" -lt "${remove_line}" ]]; then
  ok "stops the agent before deregistering (line ${term_line} < ${remove_line})"
else
  bad "expected run.sh SIGTERM before config.sh remove, got ${term_line:-none} and ${remove_line:-none}"
fi
rm -rf "${dir}"

# ── 2. idle timeout without a removal token ─────────────────────────
#
# Today's deployed config. It cannot deregister — that needs the
# dispatcher change — but it must still exit cleanly and must say why
# the registration is about to linger, rather than claiming (as it used
# to) that GitHub retires it automatically.
echo "case: idle timeout, no removal token"
dir="$(mktemp -d)"
make_runner_dir "${dir}"
code="$(run_entrypoint "${dir}" env RUNNER_IDLE_TIMEOUT=1 RUNNER_EPHEMERAL=true)"

if [[ "${code}" == "0" ]]; then
  ok "exits 0"
else
  bad "exit code = ${code}, want 0"
fi

if grep -q 'config.sh remove' "${dir}/actions.log"; then
  bad "called 'config.sh remove' with no token to use"
else
  ok "does not attempt deregistration without a token"
fi

if grep -q 'linger as offline' "${dir}/stdout.log"; then
  ok "warns that the registration will linger"
else
  bad "no warning about a lingering registration:
$(sed 's/^/        /' "${dir}/stdout.log")"
fi
rm -rf "${dir}"

# ── 3. watchdog disabled ────────────────────────────────────────────
#
# RUNNER_IDLE_TIMEOUT unset or 0 must leave the old behaviour intact:
# an image deployed against a dispatcher that does not set the variable
# has to keep waiting rather than exiting after some default.
echo "case: watchdog disabled"
dir="$(mktemp -d)"
make_runner_dir "${dir}"
(
  cd "${dir}" || exit 99
  export RUNNER_DIR="${dir}" RUNNER_PROC_DIR="${dir}/proc" \
         RUNNER_URL="https://github.com/example" \
         RUNNER_TOKEN="stub" RUNNER_IDLE_TIMEOUT=0
  bash "${ENTRYPOINT}" > "${dir}/stdout.log" 2>&1 &
  ep=$!
  sleep 3
  if kill -0 "${ep}" 2>/dev/null; then
    echo "alive" > "${dir}/state"
  else
    echo "dead" > "${dir}/state"
  fi
  kill -TERM "${ep}" 2>/dev/null
  wait "${ep}" 2>/dev/null
)
if [[ "$(cat "${dir}/state")" == "alive" ]]; then
  ok "still running after 3s with the watchdog disabled"
else
  bad "exited with RUNNER_IDLE_TIMEOUT=0; the watchdog should be off"
fi

if grep -q 'idle watchdog armed' "${dir}/stdout.log"; then
  bad "armed the watchdog despite RUNNER_IDLE_TIMEOUT=0"
else
  ok "does not arm the watchdog"
fi
rm -rf "${dir}"

# ── 4. a running job is not interrupted ─────────────────────────────
#
# The watchdog asks "is a job running NOW" by scanning the proc
# directory for Runner.Worker, which the agent forks per job. The
# fixture below is a cmdline file shaped like the real one — NUL
# separated, argv[0] the worker binary — so this case needs no live
# process and behaves identically on Linux and macOS.
echo "case: a claimed job survives the idle deadline"
dir="$(mktemp -d)"
make_runner_dir "${dir}"
mkdir -p "${dir}/proc/1917"
printf '/home/runner/runner/bin/Runner.Worker\0spawnclient\0' > "${dir}/proc/1917/cmdline"

(
  cd "${dir}" || exit 99
  export RUNNER_DIR="${dir}" RUNNER_PROC_DIR="${dir}/proc" \
         RUNNER_URL="https://github.com/example" \
         RUNNER_TOKEN="stub" RUNNER_IDLE_TIMEOUT=1
  bash "${ENTRYPOINT}" > "${dir}/stdout.log" 2>&1 &
  ep=$!
  sleep 4   # well past the 1s deadline
  if kill -0 "${ep}" 2>/dev/null; then
    echo "alive" > "${dir}/state"
  else
    echo "dead" > "${dir}/state"
  fi
  kill -TERM "${ep}" 2>/dev/null
  wait "${ep}" 2>/dev/null
)

if [[ "$(cat "${dir}/state")" == "alive" ]]; then
  ok "leaves a runner alone while Runner.Worker is present"
else
  bad "killed a runner that had a job in flight"
fi

if grep -q 'no job claimed within' "${dir}/stdout.log"; then
  bad "watchdog announced a reclaim despite a job in flight"
else
  ok "does not announce a reclaim"
fi
rm -rf "${dir}"

# ── 5. an unrelated process does not look like a job ────────────────
#
# The counterpart to case 4, and the reason it is not vacuous: some
# other entry in the proc directory must NOT keep the runner alive.
echo "case: an unrelated process does not defer the deadline"
dir="$(mktemp -d)"
make_runner_dir "${dir}"
mkdir -p "${dir}/proc/2001"
printf '/usr/bin/some-other-thing\0--flag\0' > "${dir}/proc/2001/cmdline"
code="$(run_entrypoint "${dir}" env RUNNER_IDLE_TIMEOUT=1 RUNNER_REMOVE_TOKEN=stub-remove-token)"

if [[ "${code}" == "0" ]] && grep -q 'config.sh remove' "${dir}/actions.log"; then
  ok "still reclaims when nothing looks like Runner.Worker"
else
  bad "exit ${code}; actions.log:
$(sed 's/^/        /' "${dir}/actions.log")"
fi
rm -rf "${dir}"

echo
echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
