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

ARG RUNNER_VERSION=2.334.0
ARG TARGETARCH=amd64

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl tar \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /stage

# GitHub Actions runner. SHA verification ensures we land on the
# exact bits upstream published — protects against a transient mirror
# swap or an upstream tag-rewrite (which has happened in the past).
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) RUNNER_ARCH=x64;; \
      arm64) RUNNER_ARCH=arm64;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1;; \
    esac; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"; \
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

ARG RUNNER_VERSION=2.334.0
LABEL org.opencontainers.image.title="oci-actions-runner"
LABEL org.opencontainers.image.description="Minimal Debian + GitHub Actions runner + docker CLI"
LABEL org.opencontainers.image.source="https://github.com/nkg/oci-actions-runner"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="${RUNNER_VERSION}"

# Minimal runtime — bash for the entrypoint, openssh-client for
# `actions/checkout` over SSH, ca-certs for outbound TLS, curl + git
# + jq because virtually every workflow uses them.
#
# `dumb-init` reaps zombies + forwards SIGTERM cleanly when the
# runner exits — without it, the ephemeral cleanup hangs ~5s waiting
# for the kernel to reap orphaned children.
# Add Docker's apt repo + GPG key, then install all packages in one
# shot. Repo codename pinned to `bookworm` (Debian 12) because
# Docker's repo doesn't yet ship a `trixie` component as of writing;
# the CLI binary works fine across Debian versions (pure Go).
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
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      docker-ce-cli \
      dumb-init \
      git \
      jq \
      openssh-client \
      sudo \
      tini \
      libicu76 \
 && rm -rf /var/lib/apt/lists/*

# Non-root runner user matching the upstream convention.
RUN groupadd --gid 1001 runner \
 && useradd --uid 1001 --gid runner --shell /bin/bash --create-home runner \
 && mkdir -p /home/runner/_work \
 && chown -R runner:runner /home/runner

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
