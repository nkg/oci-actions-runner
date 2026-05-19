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

ARG RUNNER_VERSION=2.328.0
ARG DOCKER_CLI_VERSION=27.4.1
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
    curl -fsSL -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"; \
    mkdir -p /stage/runner; \
    tar -xzf runner.tar.gz -C /stage/runner; \
    rm runner.tar.gz

# Docker CLI binary only (no dockerd). Jobs that `docker build` /
# `docker run` against the mounted socket need just the client.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) DOCKER_ARCH=x86_64;; \
      arm64) DOCKER_ARCH=aarch64;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1;; \
    esac; \
    curl -fsSL -o docker.tgz \
      "https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/docker-${DOCKER_CLI_VERSION}.tgz"; \
    tar -xzf docker.tgz; \
    cp docker/docker /stage/docker; \
    rm -rf docker docker.tgz

# ─── Final image ────────────────────────────────────────────────────

FROM debian:13-slim

ARG RUNNER_VERSION=2.328.0
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
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
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

# Docker CLI → /usr/local/bin (in PATH for all users).
COPY --from=builder /stage/docker /usr/local/bin/docker
RUN chmod 0755 /usr/local/bin/docker

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
