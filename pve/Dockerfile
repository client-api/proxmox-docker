# syntax=docker/dockerfile:1.6
#
# Proxmox VE — test-only image for SDK E2E runs.
#
# Installs the upstream `proxmox-ve` meta-package straight from the
# apt repo (no apt-preferences hackery). This pulls in the Proxmox
# kernel, postfix, chrony, openssh-server, and a few other host-only
# packages — we never start any of them, they're just on disk.
#
# Build from the repo root so the shared scripts/ tree is reachable:
#
#   docker build -f pve/Dockerfile -t pve-test .
#
# Run (must be --privileged for pmxcfs):
#
#   docker run --rm --privileged -p 8006:8006 pve-test

FROM debian:trixie-slim

# "no-subscription" (default, stable) or "test" (upstream testing).
ARG PROXMOX_CHANNEL=no-subscription

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PROXMOX_PRODUCT=pve \
    PROXMOX_CHANNEL=${PROXMOX_CHANNEL}

COPY scripts/setup-proxmox-repo.sh /usr/local/sbin/setup-proxmox-repo.sh
RUN chmod +x /usr/local/sbin/setup-proxmox-repo.sh \
 && /usr/local/sbin/setup-proxmox-repo.sh

# `policy-rc.d` returning 101 makes dpkg postinst service-start calls
# no-op in the container — we don't have systemd. Without this the
# postinst would error out trying to `systemctl start postfix` etc.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
 && chmod +x /usr/sbin/policy-rc.d

# `debian:trixie-slim` strips /usr/share/doc and /usr/share/locale via
# dpkg path-excludes. The pve-manager postinst copies aplinfo.dat out
# of /usr/share/doc/pve-manager/ and bails if it's missing, so we
# whitelist that path back in before installing.
RUN rm -f /etc/dpkg/dpkg.cfg.d/docker

RUN apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        iproute2 \
        jq \
        proxmox-ve \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Hide the no-subscription nag in the web UI.
RUN sed -i.bak \
        "s|data.status !== 'Active'|false|g" \
        /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js 2>/dev/null || true

RUN dpkg-query -W -f='${Version}\n' pve-manager > /etc/proxmox-version \
 && echo "[build] pve-manager=$(cat /etc/proxmox-version) channel=${PROXMOX_CHANNEL}"

LABEL org.opencontainers.image.title="Proxmox VE test image" \
      org.opencontainers.image.description="E2E-test-only PVE image. NOT FOR PRODUCTION. Ships hard-coded credentials, self-signed TLS, requires --privileged. See https://github.com/client-api/proxmox-docker" \
      org.opencontainers.image.source="https://github.com/client-api/proxmox-docker" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="client-api" \
      proxmox.channel="${PROXMOX_CHANNEL}" \
      proxmox.usage="test-only"

COPY scripts/common-entrypoint.sh /usr/local/lib/proxmox-common.sh
COPY pve/entrypoint.sh /usr/local/sbin/entrypoint.sh
COPY pve/healthcheck.sh /usr/local/sbin/healthcheck.sh
RUN chmod +x /usr/local/sbin/entrypoint.sh /usr/local/sbin/healthcheck.sh

EXPOSE 8006

HEALTHCHECK --interval=5s --timeout=5s --retries=30 --start-period=30s \
    CMD ["/usr/local/sbin/healthcheck.sh"]

ENV PVE_HOSTNAME=pve-test \
    PVE_FQDN=pve-test.local \
    PVE_ROOT_PASSWORD=proxmox123 \
    PVE_API_TOKEN_NAME=test

ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
