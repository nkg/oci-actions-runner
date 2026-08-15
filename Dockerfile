# syntax=docker/dockerfile:1.7
#
# oci-actions-runner — minimal Debian 13 base + GitHub Actions runner
# agent + docker CLI (talks to a mounted podman or docker socket).
#
# Operators FROM this image to layer their toolchain:
#
#   FROM ghcr.io/nkg/oci-actions-runner:v0.1.0
#   RUN apt-get update && apt-get install -y --no-install-recommends \
#         python3 nodejs ... && rm -rf /var/lib/apt/lists/*

# ─── Builder: fetch + verify the runner agent and docker CLI ─────────

FROM debian:13-slim AS builder

ARG RUNNER_VERSION=2.336.0
ARG TARGETARCH=amd64

# SHA256 of the upstream release tarballs, published by actions/runner
# in the release body. Both arches are listed because this image is
# built multi-arch; the build picks the one matching TARGETARCH.
#
# When bumping RUNNER_VERSION, refresh BOTH hashes from:
#   https://github.com/actions/runner/releases/tag/v<RUNNER_VERSION>
ARG RUNNER_SHA256_AMD64=04cf0be1aff4c3ec3554466c39124ca250e3effd8873bb7e8d68535aa9505d5d
ARG RUNNER_SHA256_ARM64=58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl tar \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /stage

# GitHub Actions runner, verified against the SHA256 upstream
# published for this exact version. Protects against a transient
# mirror swap or an upstream tag-rewrite (which has happened before).
# The build fails closed: an unexpected hash aborts the layer.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) RUNNER_ARCH=x64;   RUNNER_SHA256="${RUNNER_SHA256_AMD64}";; \
      arm64) RUNNER_ARCH=arm64; RUNNER_SHA256="${RUNNER_SHA256_ARM64}";; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1;; \
    esac; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"; \
    echo "${RUNNER_SHA256}  runner.tar.gz" > runner.tar.gz.sha256; \
    sha256sum -c runner.tar.gz.sha256; \
    rm runner.tar.gz.sha256; \
    mkdir -p /stage/runner; \
    tar -xzf runner.tar.gz -C /stage/runner; \
    rm runner.tar.gz

# Docker CLI: installed from Docker's upstream apt repo in the final
# stage. Tried docker.io (Debian's package) first — on trixie the
# binary lands somewhere $PATH doesn't see, and the container-structure
# tests couldn't exec it. Also tried the static binary from
# download.docker.com — that URL flakes on Azure's CI network.
# Docker's apt repo is reliable, canonical, and ships docker-ce-cli
# as a separate package from the engine (no dockerd binary in the
# image).

# ─── Final image ────────────────────────────────────────────────────

FROM debian:13-slim

# Set pipefail so `curl ... | gpg --dearmor` failures propagate.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG RUNNER_VERSION=2.336.0
LABEL org.opencontainers.image.title="oci-actions-runner"
LABEL org.opencontainers.image.description="Minimal Debian + GitHub Actions runner + docker CLI"
LABEL org.opencontainers.image.source="https://github.com/nkg/oci-actions-runner"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="${RUNNER_VERSION}"

# Minimal runtime — bash for the entrypoint, openssh-client for
# `actions/checkout` over SSH, ca-certs for outbound TLS, curl + git
# + jq because virtually every workflow uses them.
#
# `tini` is the init: it reaps zombies and forwards SIGTERM cleanly
# when the runner exits — without it, the ephemeral cleanup hangs ~5s
# waiting for the kernel to reap orphaned children.
#
# Add Docker's apt repo + GPG key, then install all packages in one
# shot. The repo codename is taken from the base image's os-release
# rather than hardcoded, so it tracks automatically when the `FROM`
# tag is bumped instead of silently pointing at the previous release.
#
# libicu is resolved at build time rather than pinned. The runner
# agent is .NET and needs ICU, but Debian renames the package on every
# ICU bump (libicu72 -> 76 -> ...), so a literal name is a build break
# waiting for the next base-image bump. Upstream's own
# installdependencies.sh walks a fallback list for exactly this
# reason; picking the highest available libicuNN is the same idea
# without hardcoding a list that also goes stale. The result is
# re-filtered through grep rather than trusting apt-cache's regex
# dialect, so libicu-dev / libicu76-dbg / libicu-le-hb0 can't be
# selected, and an empty result fails the build rather than producing
# an image whose runner agent won't start.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
      https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
 && chmod a+r /etc/apt/keyrings/docker.gpg \
 && . /etc/os-release \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && ICU_PKG="$(apt-cache search --names-only '^libicu[0-9]+$' \
      | awk '{print $1}' | grep -E '^libicu[0-9]+$' | sort -V | tail -1)" \
 && if [ -z "${ICU_PKG}" ]; then echo "no libicuNN package available" >&2; exit 1; fi \
 && echo "using ICU package: ${ICU_PKG}" \
 && apt-get install -y --no-install-recommends \
      bash \
      docker-ce-cli \
      git \
      jq \
      openssh-client \
      sudo \
      tini \
      "${ICU_PKG}" \
 && rm -rf /var/lib/apt/lists/*

# Non-root runner user matching the upstream convention.
#
# Passwordless sudo, matching GitHub's hosted runners — workflows
# routinely `sudo apt-get install` a build dependency, and without a
# sudoers entry the `sudo` package installed above does nothing at
# all. This is not the privilege boundary it might look like: the
# container is handed the host's podman/docker socket, so any job that
# can run here can already obtain host root through it. Withholding
# sudo would break ordinary workflows without changing that.
#
# Written with `install -m 0440`, and validated with `visudo -c`, so a
# malformed file fails the build rather than at first `sudo` call —
# sudo refuses to run at all if any sudoers file is group/world
# writable or syntactically invalid.
RUN groupadd --gid 1001 runner \
 && useradd --uid 1001 --gid runner --shell /bin/bash --create-home runner \
 && mkdir -p /home/runner/_work \
 && chown -R runner:runner /home/runner \
 && echo 'runner ALL=(ALL) NOPASSWD:ALL' \
      | install -m 0440 -o root -g root /dev/stdin /etc/sudoers.d/runner \
 && visudo -c -f /etc/sudoers.d/runner

# Runner agent → /home/runner/runner (owned by runner uid).
COPY --from=builder --chown=runner:runner /stage/runner /home/runner/runner

# Entrypoint reads RUNNER_URL / RUNNER_TOKEN / RUNNER_LABELS /
# RUNNER_EPHEMERAL from env at start-time and shells the agent.
COPY --chown=root:root entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER runner
WORKDIR /home/runner

# Tini handles signals + zombie reaping.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
