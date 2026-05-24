# syntax=docker/dockerfile:1.6
#
# Proxmox Backup Server — test-only image for SDK E2E runs.
#
# Installs the upstream `proxmox-backup-server` meta-package straight
# from the apt repo (no apt-preferences hackery, no package pinning).
# This pulls in the Proxmox kernel, openssh-server, and a few other
# host-only dependencies — we never start them, they're just on disk.
#
# Build from the repo root:
#
#   docker build -f pbs/Dockerfile -t pbs-test .
#
# Run:
#
#   docker run --rm --privileged -p 8007:8007 pbs-test

FROM debian:trixie-slim

# "no-subscription" (default, stable) or "test" (upstream testing).
ARG PROXMOX_CHANNEL=no-subscription

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PROXMOX_PRODUCT=pbs \
    PROXMOX_CHANNEL=${PROXMOX_CHANNEL}

COPY scripts/setup-proxmox-repo.sh /usr/local/sbin/setup-proxmox-repo.sh
RUN chmod +x /usr/local/sbin/setup-proxmox-repo.sh \
 && /usr/local/sbin/setup-proxmox-repo.sh

# `policy-rc.d` returning 101 makes dpkg postinst service-start calls
# no-op in the container — we don't have systemd. Without this the
# postinst would error out trying to `systemctl start postfix` etc.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
 && chmod +x /usr/sbin/policy-rc.d

RUN apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        iproute2 \
        jq \
        proxmox-backup-server \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Suppress the no-subscription nag.
RUN sed -i.bak \
        "s|data.status !== 'Active'|false|g" \
        /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js 2>/dev/null || true

RUN dpkg-query -W -f='${Version}\n' proxmox-backup-server > /etc/proxmox-version \
 && echo "[build] proxmox-backup-server=$(cat /etc/proxmox-version) channel=${PROXMOX_CHANNEL}"

LABEL org.opencontainers.image.title="Proxmox Backup Server test image" \
      org.opencontainers.image.description="E2E-test-only PBS image. NOT FOR PRODUCTION. Ships hard-coded credentials, self-signed TLS, requires --privileged. See https://github.com/client-api/proxmox-docker" \
      org.opencontainers.image.source="https://github.com/client-api/proxmox-docker" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="client-api" \
      proxmox.channel="${PROXMOX_CHANNEL}" \
      proxmox.usage="test-only"

COPY scripts/common-entrypoint.sh /usr/local/lib/proxmox-common.sh
COPY pbs/entrypoint.sh /usr/local/sbin/entrypoint.sh
COPY pbs/healthcheck.sh /usr/local/sbin/healthcheck.sh
RUN chmod +x /usr/local/sbin/entrypoint.sh /usr/local/sbin/healthcheck.sh

EXPOSE 8007

HEALTHCHECK --interval=5s --timeout=5s --retries=30 --start-period=20s \
    CMD ["/usr/local/sbin/healthcheck.sh"]

ENV PBS_HOSTNAME=pbs-test \
    PBS_FQDN=pbs-test.local \
    PBS_ROOT_PASSWORD=proxmox123 \
    PBS_API_TOKEN_NAME=test

ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
