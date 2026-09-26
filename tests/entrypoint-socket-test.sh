#!/usr/bin/env bash
# Tests for entrypoint.sh's socket-group block.
#
# The block exists because the host's rootful podman socket is mounted
# root:root 0660 and the agent runs as uid 1001, so every docker step in
# every job failed with "permission denied" while the rest of the job
# passed. The fix re-executes the entrypoint through sudo with the
# socket's group added; these cases pin what it must and must not do.
#
# No real sudo, docker or root is needed: a stub `sudo` on PATH logs
# what it was asked and runs the re-exec, and stub config.sh/run.sh
# stand in for the agent, as in entrypoint-shutdown-test.sh.
#
# Run:  tests/entrypoint-socket-test.sh

# `cond && ok … || bad …` is used as if/else throughout. SC2015 warns
# that C can run after B fails; ok and bad always return 0, so it can't.
# shellcheck disable=SC2015

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="${REPO_ROOT}/entrypoint.sh"

pass=0
fail=0
ok()  { echo "  ok   — $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL — $1"; fail=$((fail + 1)); }

if [[ "$(id -u)" == "0" ]]; then
  # Root can write any socket, so the "not writable" branch is unreachable.
  echo "skip: running as root"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "skip: python3 is needed to create a unix socket"
  exit 0
fi

# make_dir DIR SUDO_WORKS — stub agent, stub sudo, and a real unix socket
# made unwritable with chmod.
make_dir() {
  local dir="$1" sudo_works="$2"
  mkdir -p "${dir}/bin"

  cat > "${dir}/config.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "config.sh groups=$(id -Gn)" >> "${RUNNER_DIR}/actions.log"
STUB
  # Exits straight away: these cases are about what happens before the
  # agent starts, not about its shutdown.
  cat > "${dir}/run.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "run.sh PATH=${PATH} done=${_ENTRYPOINT_SOCKET_GROUP_DONE:-}" >> "${RUNNER_DIR}/actions.log"
STUB

  # The stub logs every call. `-n true` is the capability probe; the
  # re-exec (`-- env ... script`) is run for real so the second pass of
  # the entrypoint executes.
  cat > "${dir}/bin/sudo" <<STUB
#!/usr/bin/env bash
printf '%s\n' "sudo \$*" >> "\${RUNNER_DIR}/sudo.log"
[[ "${sudo_works}" == "yes" ]] || exit 1
for ((i = 1; i <= \$#; i++)); do
  if [[ "\${!i}" == "--" ]]; then
    shift "\${i}"
    exec "\$@"
  fi
done
exit 0
STUB
  chmod +x "${dir}/config.sh" "${dir}/run.sh" "${dir}/bin/sudo"

  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "${dir}/docker.sock"
  chmod 000 "${dir}/docker.sock"
}

run_entrypoint() {
  local dir="$1"
  (
    cd "${dir}" || exit 99
    export RUNNER_DIR="${dir}" RUNNER_URL="https://github.com/example" \
           RUNNER_TOKEN="stub" RUNNER_NAME="stub-runner" \
           DOCKER_SOCKET="${dir}/docker.sock" \
           PATH="${dir}/bin:/mise/shims:${PATH}"
    bash "${ENTRYPOINT}" > "${dir}/stdout.log" 2>&1
    echo "$?" > "${dir}/exit_code"
  )
  cat "${dir}/exit_code"
}

# ── 1. unwritable socket, sudo available ────────────────────────────
echo "case: unwritable socket, sudo available"
dir="$(mktemp -d)"
make_dir "${dir}" yes
code="$(run_entrypoint "${dir}")"
me="$(id -un)"

[[ "${code}" == "0" ]] && ok "exits 0" || bad "exit code = ${code}, want 0"

if grep -q "sudo -n usermod -aG .* ${me}\$" "${dir}/sudo.log"; then
  ok "adds ${me} to the socket's group"
else
  bad "no usermod in sudo.log:
$(sed 's/^/        /' "${dir}/sudo.log")"
fi

if grep -q "sudo -n -E -u ${me} -- env PATH=" "${dir}/sudo.log"; then
  ok "re-executes as ${me}, passing PATH through"
else
  bad "no re-exec in sudo.log:
$(sed 's/^/        /' "${dir}/sudo.log")"
fi

# The second pass must not try again (the stub cannot really add the
# group, so the socket is still unwritable — exactly the loop to avoid).
reexecs="$(grep -c -- ' -- env ' "${dir}/sudo.log")"
[[ "${reexecs}" == "1" ]] && ok "re-executes exactly once" \
  || bad "re-executed ${reexecs} times"

if grep -q 'run.sh .*/mise/shims.* done=1' "${dir}/actions.log"; then
  ok "the agent starts after the re-exec with /mise/shims still on PATH"
else
  bad "agent did not start as expected:
$(sed 's/^/        /' "${dir}/actions.log" 2>/dev/null)"
fi
rm -rf "${dir}"

# ── 2. unwritable socket, no sudo ───────────────────────────────────
#
# e.g. a runtime with no-new-privileges. Must warn with the fix and
# still register, rather than crash-looping the allocation.
echo "case: unwritable socket, sudo unavailable"
dir="$(mktemp -d)"
make_dir "${dir}" no
code="$(run_entrypoint "${dir}")"

[[ "${code}" == "0" ]] && ok "exits 0" || bad "exit code = ${code}, want 0"
grep -q 'group_add' "${dir}/stdout.log" && ok "warns and names group_add" \
  || bad "no group_add hint in output:
$(sed 's/^/        /' "${dir}/stdout.log")"
grep -q 'config.sh' "${dir}/actions.log" && ok "still registers the runner" \
  || bad "runner was not registered"
grep -q 'usermod' "${dir}/sudo.log" && bad "tried usermod without sudo" \
  || ok "does not attempt usermod"
rm -rf "${dir}"

# ── 3. writable socket ──────────────────────────────────────────────
#
# The common case once the runtime sets group_add, and on a docker host
# where the user is already in the docker group: no sudo at all.
echo "case: writable socket"
dir="$(mktemp -d)"
make_dir "${dir}" yes
chmod 600 "${dir}/docker.sock"
code="$(run_entrypoint "${dir}")"

[[ "${code}" == "0" ]] && ok "exits 0" || bad "exit code = ${code}, want 0"
[[ ! -s "${dir}/sudo.log" ]] && ok "never calls sudo" \
  || bad "called sudo for a writable socket:
$(sed 's/^/        /' "${dir}/sudo.log")"
rm -rf "${dir}"

echo
echo "${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
