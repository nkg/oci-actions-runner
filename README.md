# oci-actions-runner

Minimal OCI image for ephemeral GitHub Actions runners. Designed to
be spawned by
[nkg/gha-nomad-dispatcher](https://github.com/nkg/gha-nomad-dispatcher)
on a Nomad cluster using the podman driver — one container per
workflow_job, registered with `--ephemeral --once`, exits after a
single job.

## What's in the box

| Layer | Contents |
|---|---|
| Base | `debian:13-slim` |
| Init | `tini` (signal forwarding + zombie reaping) |
| Runtime | bash, ca-certs, curl, dumb-init, git, jq, openssh-client, sudo |
| Container CLI | `docker-ce-cli` from Docker's upstream apt repo (CLI only, no daemon; talks to whatever docker-compat socket you mount) |
| Runner | Official `actions/runner` agent at a pinned version |
| User | `runner` (uid 1001) |

What's deliberately **not** in the box: Python, Node, Go, language runtimes, build toolchains. Operators FROM this image and add their stack:

```Dockerfile
FROM ghcr.io/nkg/oci-actions-runner:v0.1.0

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip nodejs npm \
 && rm -rf /var/lib/apt/lists/*

USER runner
```

This keeps the base small + neutral, lets each workload pick what it
actually needs, and avoids the "every runner has everything" anti-pattern.

## Runtime contract

The container's entrypoint reads these env vars at start time:

| Variable | Required | Default | Description |
|---|---|---|---|
| `RUNNER_URL` | yes | — | `https://github.com/{owner}/{repo}` (repo-scoped) or `https://github.com/{owner}` (org-scoped) |
| `RUNNER_TOKEN` | yes | — | Single-use registration token from GitHub (or via gha-nomad-dispatcher) |
| `RUNNER_LABELS` | no | `self-hosted,linux` | Comma-separated runner labels |
| `RUNNER_NAME` | no | `$HOSTNAME` | Display name in GitHub |
| `RUNNER_GROUP` | no | `default` | Runner group name |
| `RUNNER_EPHEMERAL` | no | `true` | `true` → register with `--ephemeral` |
| `RUNNER_WORK_DIR` | no | `_work` | Working directory for jobs |
| `EXTRA_RUNNER_ARGS` | no | — | Appended verbatim to `config.sh` (advanced) |

The container expects a docker-compatible socket to be mounted at
`/var/run/docker.sock` for jobs that `docker build` / `docker run` /
`docker compose`. Under the dispatcher's Nomad job spec this is the
host's podman socket (`/run/podman/podman.sock`). Under a real
Docker host, dockerd's socket works the same.

## Quick local test

```bash
# Build
docker build -t oci-actions-runner:dev .

# Run (against a real GitHub registration token)
docker run --rm \
  -e RUNNER_URL=https://github.com/your-org/your-repo \
  -e RUNNER_TOKEN=<single-use-token> \
  -e RUNNER_LABELS=self-hosted,linux,docker \
  -v /var/run/docker.sock:/var/run/docker.sock \
  oci-actions-runner:dev
```

The runner registers, picks up one queued job (if any), runs it, and
exits.

## Pulling from GHCR

After a tag is pushed, the release workflow publishes multi-arch
images:

```bash
docker pull ghcr.io/nkg/oci-actions-runner:v0.1.0
docker pull ghcr.io/nkg/oci-actions-runner:latest
```

Architectures: `linux/amd64`, `linux/arm64`.

## Wiring into gha-nomad-dispatcher

Set the dispatcher's `RUNNER_IMAGE` env var to the GHCR ref:

```
RUNNER_IMAGE=ghcr.io/nkg/oci-actions-runner:v0.1.0
RUNNER_LABELS=self-hosted,linux,x64,podman
```

That's it — the dispatcher takes care of token minting + Nomad job
submission; this image just runs the agent.

## Design notes

### Docker CLI from Docker's upstream apt repo

Image installs `docker-ce-cli` from Docker's official apt repo
(`download.docker.com/linux/debian`) — CLI only, no daemon. Reasons:

- Canonical source; the binary is exactly what `docker` ships
- Predictable install path (`/usr/bin/docker`, on PATH)
- No dockerd binary in the image (~30 MB lighter than `docker.io`)
- More reliable than the static binary at
  `download.docker.com/linux/static/*` which flakes on Azure CI

The repo is pinned to the `bookworm` (Debian 12) component because
Docker's repo doesn't ship a `trixie` component yet — the CLI is
pure Go and works across Debian versions.

At runtime, the CLI talks to whatever socket the runtime mounts at
`/var/run/docker.sock` (the dispatcher mounts the host's podman
socket, which is docker-API-compatible). Socket-mount is faster +
lighter than docker-in-docker.

Trade-off: a compromised job can escape via the socket if the
daemon has weak isolation. For the trust model this image targets
(private orgs only, no public PR CI), that's acceptable; for
stricter isolation needs, layer `sysbox` or run rootless docker
inside the runner.

### `tini` for signal handling

Without `tini` (or `dumb-init`), the runner agent's spawned children
leak as zombies and `SIGTERM` from Nomad takes ~5s to propagate
through to the agent. `tini` reaps + forwards in single-digit
milliseconds.

### Pinned runner + docker versions

Both `RUNNER_VERSION` and `DOCKER_CLI_VERSION` are build args with
explicit defaults. Bumping is a deliberate edit + tag.

### Non-root runner user

The agent runs as uid 1001, not root. This is upstream's
recommendation and matches GitHub-hosted runner behaviour. If a
workflow genuinely needs root inside the container (rare), it can
`sudo` — `sudo` is installed without a password requirement (the
runner user is in the sudoers file with NOPASSWD).

## Roadmap

- **v0.2** — Optional toolchain variants (`oci-actions-runner-node`, `-python`, `-go`) as separate images sharing this as a base
- **v0.3** — `sysbox` or rootless-docker variant for stricter isolation
- **v0.4** — Cosign signing of release images

## License

MIT.
