# syntax=docker/dockerfile:1.6
#
# Proxmox Datacenter Manager — test-only image for SDK E2E runs.
#
# PDM is the newest of the four (alpha-stage as of writing). It's the
# simplest to package: pure Rust binaries, no FUSE cluster filesystem,
# no Perl, and minimal kernel dependencies. The API listens on :8443.
#
# Build from the repo root:
#
#   docker build -f pdm/Dockerfile -t pdm-test .
#
# Run:
#
#   docker run --rm --privileged -p 8443:8443 pdm-test

FROM debian:trixie-slim

# "no-subscription" (default, stable) or "test" (upstream testing).
ARG PROXMOX_CHANNEL=no-subscription

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PROXMOX_PRODUCT=pdm \
    PROXMOX_CHANNEL=${PROXMOX_CHANNEL}

COPY scripts/setup-proxmox-repo.sh /usr/local/sbin/setup-proxmox-repo.sh
RUN chmod +x /usr/local/sbin/setup-proxmox-repo.sh \
 && /usr/local/sbin/setup-proxmox-repo.sh

RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
 && chmod +x /usr/sbin/policy-rc.d

# Install the PDM API stack straight from the apt repo. The PDM
# `proxmox-datacenter-manager` package doesn't pull the Proxmox kernel
# (unlike the PVE/PBS/PMG metas) so we don't need to use a separate
# meta-package here — these three are the full stack.
RUN apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        iproute2 \
        jq \
        proxmox-datacenter-manager \
        proxmox-datacenter-manager-client \
        proxmox-datacenter-manager-ui \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

COPY scripts/common-entrypoint.sh /usr/local/lib/proxmox-common.sh
COPY pdm/entrypoint.sh /usr/local/sbin/entrypoint.sh
COPY pdm/healthcheck.sh /usr/local/sbin/healthcheck.sh
RUN chmod +x /usr/local/sbin/entrypoint.sh /usr/local/sbin/healthcheck.sh

RUN dpkg-query -W -f='${Version}\n' proxmox-datacenter-manager > /etc/proxmox-version \
 && echo "[build] proxmox-datacenter-manager=$(cat /etc/proxmox-version) channel=${PROXMOX_CHANNEL}"

LABEL org.opencontainers.image.title="Proxmox Datacenter Manager test image" \
      org.opencontainers.image.description="E2E-test-only PDM image. NOT FOR PRODUCTION. Ships hard-coded credentials, self-signed TLS, requires --privileged. See https://github.com/client-api/proxmox-docker" \
      org.opencontainers.image.source="https://github.com/client-api/proxmox-docker" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="client-api" \
      proxmox.channel="${PROXMOX_CHANNEL}" \
      proxmox.usage="test-only"

EXPOSE 8443

HEALTHCHECK --interval=5s --timeout=5s --retries=30 --start-period=20s \
    CMD ["/usr/local/sbin/healthcheck.sh"]

ENV PDM_HOSTNAME=pdm-test \
    PDM_FQDN=pdm-test.local \
    PDM_ROOT_PASSWORD=proxmox123 \
    PDM_API_TOKEN_NAME=test

ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
