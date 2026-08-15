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
| Runtime | bash, ca-certs, curl, git, jq, openssh-client, sudo, ICU (for the .NET-based agent) |
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
| `RUNNER_REMOVE_TOKEN` | no | — | **Removal** token, used to deregister on SIGTERM. A different credential from `RUNNER_TOKEN` — see below. |
| `RUNNER_LABELS` | no | `self-hosted,linux` | Comma-separated runner labels |
| `RUNNER_NAME` | no | `$HOSTNAME` | Display name in GitHub |
| `RUNNER_GROUP` | no | `default` | Runner group name |
| `RUNNER_EPHEMERAL` | no | `true` | `true` → register with `--ephemeral` |
| `RUNNER_WORK_DIR` | no | `_work` | Working directory for jobs |
| `EXTRA_RUNNER_ARGS` | no | — | Appended verbatim to `config.sh` (advanced) |

### Registration vs removal tokens

GitHub issues these as two distinct, single-use credentials.
`RUNNER_TOKEN` registers the runner and is consumed by `config.sh`
during startup; deregistering afterwards needs a *removal* token from
a different API endpoint (`gha-token-server` exposes it as
`/remove-token`).

For the normal ephemeral case you don't need one: with
`RUNNER_EPHEMERAL=true` (the default, and what the dispatcher sets)
GitHub retires the registration itself once the single job finishes,
and the entrypoint says so on shutdown rather than attempting a
removal that would fail.

Set `RUNNER_REMOVE_TOKEN` only for **long-lived** runners
(`RUNNER_EPHEMERAL=false`), where nothing else cleans up the
registration and a killed container would otherwise linger as an
offline runner in the GitHub UI.

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

## Verifying a release

Released images are signed with [cosign](https://docs.sigstore.dev/)
keyless OIDC, and carry an SPDX SBOM plus SLSA build provenance as
in-toto attestations. There is no long-lived signing key — the
signature is bound to the GitHub Actions workflow that produced the
image.

```bash
IMAGE=ghcr.io/nkg/oci-actions-runner:<tag>

# Signature. The identity regexp is what makes this meaningful:
# it asserts the image was built by *this* repo's workflow, not
# merely that someone signed it.
cosign verify "$IMAGE" \
  --certificate-identity-regexp '^https://github.com/nkg/oci-actions-runner/' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'

# Build provenance (what built it, from which commit)
gh attestation verify "oci://$IMAGE" --repo nkg/oci-actions-runner

# SBOM
cosign download sbom "$IMAGE"
```

Signatures bind the **digest**, not the tag — a tag can be moved, a
digest cannot. Pin by digest in production if you want the guarantee
to hold over time.

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

Without an init, the runner agent's spawned children leak as zombies
and `SIGTERM` from Nomad takes ~5s to propagate through to the agent.
`tini` reaps + forwards in single-digit milliseconds.

`tini` is the only init installed. `dumb-init` was carried alongside
it for a while — unused, since the `ENTRYPOINT` has always been
`tini` — and has been dropped.

### Pinned, checksum-verified runner agent

`RUNNER_VERSION` is a build arg with an explicit default, paired with
`RUNNER_SHA256_AMD64` / `RUNNER_SHA256_ARM64`. The downloaded tarball
is verified before extraction, so an unexpected hash fails the build.
Bumping means editing the version *and* both hashes, taken from the
[release page](https://github.com/actions/runner/releases).

The docker CLI is **not** version-pinned: it comes from Docker's apt
repo, so security updates roll in when the image is rebuilt. Pin the
image tag, not the CLI, if you need byte-for-byte reproducibility.

### Non-root runner user

The agent runs as uid 1001, not root. This is upstream's
recommendation and matches GitHub-hosted runner behaviour. Workflows
that need root inside the container can `sudo` without a password —
`/etc/sudoers.d/runner` grants the runner user `NOPASSWD:ALL`, the
same as GitHub's hosted runners.

That is deliberately not treated as a privilege boundary. The
container is handed the host's podman/docker socket, so a job that can
run here can already obtain host root through it; withholding sudo
would break ordinary workflows without changing what a job can reach.
If you need that boundary, it has to come from not mounting the socket
(see the `sysbox` / rootless-docker roadmap item), not from sudo.

### ICU is resolved at build time, not pinned

The runner agent is .NET and won't start without ICU, but Debian
renames the package on every ICU major bump (`libicu72` → `libicu76` →
…). The Dockerfile selects the highest `libicuNN` available in the
base image's apt sources instead of naming one, so bumping the `FROM`
tag doesn't break the build. An empty result fails the build rather
than producing an image whose agent won't start.

### Docker repo codename follows the base image

The Docker apt repo line takes its suite from the base image's
`/etc/os-release` rather than a hardcoded codename. It was previously
pinned to `bookworm` on a `trixie` base — harmless while it lasted,
since the CLI is a static Go binary, but it silently kept the image on
the previous release's packages. Docker now publishes a `trixie`
component, and deriving the codename means the next base bump tracks
automatically.

## Roadmap

- **v0.2** — Optional toolchain variants (`oci-actions-runner-node`, `-python`, `-go`) as separate images sharing this as a base
- **v0.3** — `sysbox` or rootless-docker variant for stricter isolation
- **v0.4** — Cosign signing of release images

## License

MIT.
