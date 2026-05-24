# syntax=docker/dockerfile:1.6
#
# Proxmox Mail Gateway — test-only image for SDK E2E runs.
#
# Installs the upstream `proxmox-mailgateway` meta-package straight
# from the apt repo (no apt-preferences hackery). The meta pulls in
# the Proxmox kernel, postfix, and the mail-filtering stack — we
# never start any of it, the API is what we exercise.
#
# Build from the repo root:
#
#   docker build -f pmg/Dockerfile -t pmg-test .
#
# Run:
#
#   docker run --rm --privileged -p 8006:8006 pmg-test

FROM debian:trixie-slim

# "no-subscription" (default, stable) or "test" (upstream testing).
ARG PROXMOX_CHANNEL=no-subscription

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PROXMOX_PRODUCT=pmg \
    PROXMOX_CHANNEL=${PROXMOX_CHANNEL}

COPY scripts/setup-proxmox-repo.sh /usr/local/sbin/setup-proxmox-repo.sh
RUN chmod +x /usr/local/sbin/setup-proxmox-repo.sh \
 && /usr/local/sbin/setup-proxmox-repo.sh

RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
 && chmod +x /usr/sbin/policy-rc.d

# `debian:trixie-slim` strips /usr/share/doc; PMG postinst scripts
# read files out of there, so put it back before installing.
RUN rm -f /etc/dpkg/dpkg.cfg.d/docker

RUN apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        iproute2 \
        jq \
        proxmox-mailgateway \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

RUN sed -i.bak \
        "s|data.status !== 'Active'|false|g" \
        /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js 2>/dev/null || true

RUN dpkg-query -W -f='${Version}\n' pmg-api > /etc/proxmox-version \
 && echo "[build] pmg-api=$(cat /etc/proxmox-version) channel=${PROXMOX_CHANNEL}"

LABEL org.opencontainers.image.title="Proxmox Mail Gateway test image" \
      org.opencontainers.image.description="E2E-test-only PMG image. NOT FOR PRODUCTION. Ships hard-coded credentials, self-signed TLS, requires --privileged. See https://github.com/client-api/proxmox-docker" \
      org.opencontainers.image.source="https://github.com/client-api/proxmox-docker" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="client-api" \
      proxmox.channel="${PROXMOX_CHANNEL}" \
      proxmox.usage="test-only"

COPY scripts/common-entrypoint.sh /usr/local/lib/proxmox-common.sh
COPY pmg/entrypoint.sh /usr/local/sbin/entrypoint.sh
COPY pmg/healthcheck.sh /usr/local/sbin/healthcheck.sh
RUN chmod +x /usr/local/sbin/entrypoint.sh /usr/local/sbin/healthcheck.sh

EXPOSE 8006

HEALTHCHECK --interval=5s --timeout=5s --retries=30 --start-period=20s \
    CMD ["/usr/local/sbin/healthcheck.sh"]

ENV PMG_HOSTNAME=pmg-test \
    PMG_FQDN=pmg-test.local \
    PMG_ROOT_PASSWORD=proxmox123 \
    PMG_API_TOKEN_NAME=test

ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
