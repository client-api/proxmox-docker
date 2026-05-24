# syntax=docker/dockerfile:1.6
#
# Proxmox VE — test-only image for SDK E2E runs.
#
# Runs real systemd as PID 1 (`/sbin/init`). PVE's units bring up
# pmxcfs, pvedaemon, pvestatd, pveproxy; a single `proxmox-docker-boot`
# oneshot unit runs the orchestration that used to live in the old
# shell entrypoint (vmbr0 stub, credential seed, fixture VM seed).
#
# Build from the repo root so the shared scripts/ tree is reachable:
#
#   docker build -f pve/Dockerfile -t pve-test .
#
# Run (must be --privileged for pmxcfs + systemd cgroups; --device
# /dev/kvm enables real VM lifecycle):
#
#   docker run --rm --privileged --device /dev/kvm \
#       -p 8006:8006 pve-test

FROM debian:trixie-slim

# "no-subscription" (default, stable) or "test" (upstream testing).
ARG PROXMOX_CHANNEL=no-subscription

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PROXMOX_PRODUCT=pve \
    PROXMOX_CHANNEL=${PROXMOX_CHANNEL} \
    container=docker

COPY scripts/setup-proxmox-repo.sh /usr/local/sbin/setup-proxmox-repo.sh
RUN chmod +x /usr/local/sbin/setup-proxmox-repo.sh \
 && /usr/local/sbin/setup-proxmox-repo.sh

# `policy-rc.d` returning 101 makes dpkg postinst service-start calls
# no-op during the BUILD step. We remove the override later so systemd
# can start units at runtime.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
 && chmod +x /usr/sbin/policy-rc.d

# `debian:trixie-slim` strips /usr/share/doc; the pve-manager postinst
# reads files out of there (e.g. aplinfo.dat), so put it back.
RUN rm -f /etc/dpkg/dpkg.cfg.d/docker

RUN apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        e2fsprogs \
        iproute2 \
        jq \
        proxmox-ve \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# --- KVM fixture (256-byte-vm v1.0.0) -------------------------------------
# 1 MiB virtual qcow2; SeaBIOS-bootable; the guest installs an ACPI
# power-button handler so `qm shutdown` exits cleanly to S5 instead of
# being force-killed. SHA256 verified at build time.
ARG TINY_VM_VERSION=v1.0.0
ARG TINY_VM_SHA256=621533eea8fb3d955e5be11fd47ee0d25a74cc08d2e46b7f914710e950a729ac
RUN install -d /usr/local/share/proxmox-docker \
 && curl -fsSL -o /usr/local/share/proxmox-docker/boot.qcow2 \
        "https://github.com/client-api/256-byte-vm/releases/download/${TINY_VM_VERSION}/boot.qcow2" \
 && echo "${TINY_VM_SHA256}  /usr/local/share/proxmox-docker/boot.qcow2" \
        | sha256sum -c -

# --- LXC fixture (Alpine 3.21 minirootfs) ---------------------------------
# Alpine ships an officially-published 3.5 MB tarball-rootfs we can drop
# straight into PVE's template cache. The boot script then calls
# `pct create 200 ...` against it. SHA256 from latest-releases.yaml.
ARG ALPINE_TEMPLATE_VERSION=3.21.7
ARG ALPINE_TEMPLATE_DATE=20260415
ARG ALPINE_TEMPLATE_SHA256=8cba1ea3e8b500ea986a313d8eecf3d5952a2a0d23a69117bb81c023d9ceac05
ENV ALPINE_TEMPLATE_NAME=alpine-3.21-default_${ALPINE_TEMPLATE_DATE}_amd64.tar.gz
RUN install -d /var/lib/vz/template/cache \
 && curl -fsSL \
        -o "/var/lib/vz/template/cache/${ALPINE_TEMPLATE_NAME}" \
        "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-minirootfs-${ALPINE_TEMPLATE_VERSION}-x86_64.tar.gz" \
 && echo "${ALPINE_TEMPLATE_SHA256}  /var/lib/vz/template/cache/${ALPINE_TEMPLATE_NAME}" \
        | sha256sum -c -

# Hide the no-subscription nag in the web UI.
RUN sed -i.bak \
        "s|data.status !== 'Active'|false|g" \
        /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js 2>/dev/null || true

RUN dpkg-query -W -f='${Version}\n' pve-manager > /etc/proxmox-version \
 && echo "[build] pve-manager=$(cat /etc/proxmox-version) channel=${PROXMOX_CHANNEL}"

# --- systemd integration ----------------------------------------------------
#
# We let systemd own service startup so `qm start` (which goes through
# the systemd1 dbus API to place QEMU in a transient scope) works
# unchanged. Steps:
#
# 1. Mask units that block boot forever in a container (waiting for
#    physical interfaces, time sync, watchdog hardware, …).
# 2. Enable the four PVE units we actually need.
# 3. Install two oneshot units:
#      - proxmox-docker-hostname  runs BEFORE pve-cluster, writes
#        /etc/hostname + /etc/hosts so pmxcfs has a valid FQDN.
#      - proxmox-docker-boot      runs AFTER the API is up, seeds
#        credentials + the fixture VM.
# 4. Drop policy-rc.d so apt-triggered restarts inside the running
#    container behave like a real install.
#
# (Docker bind-mounts /etc/hostname and /etc/hosts read-only during the
# build phase, so we can't pre-populate them in a RUN step. The
# hostname unit handles it at boot.)

# Mask units that have no work to do in a container and would block
# `multi-user.target` if left alone.
RUN systemctl mask -- \
        systemd-networkd-wait-online.service \
        systemd-resolved.service \
        systemd-timesyncd.service \
        chrony.service \
        watchdog-mux.service \
        rpcbind.service \
        pve-ha-lrm.service \
        pve-ha-crm.service \
        pvefw-logger.service \
        pvescheduler.service \
        pve-firewall.service \
        spiceproxy.service \
        2>/dev/null || true

# pve-cluster ships pmxcfs and is the prerequisite for everything else.
# pvedaemon/pveproxy/pvestatd compose the management API.
RUN systemctl enable -- \
        pve-cluster.service \
        pvedaemon.service \
        pveproxy.service \
        pvestatd.service \
 && systemctl set-default multi-user.target

COPY pve/systemd/proxmox-docker-hostname.service \
     /etc/systemd/system/proxmox-docker-hostname.service
COPY pve/systemd/proxmox-docker-boot.service \
     /etc/systemd/system/proxmox-docker-boot.service
RUN systemctl enable proxmox-docker-hostname.service proxmox-docker-boot.service

# Without this drop-in, lxcfs.service refuses to start
# (`ConditionVirtualization=!container`), `pct start` then fails with
# `lxc_setup: Failed to run mount hooks` because PVE's LXC config
# pins `lxc.hook.mount = /usr/share/lxcfs/lxc.mount.hook` via
# common.conf.d/00-lxcfs.conf.
RUN install -d /etc/systemd/system/lxcfs.service.d
COPY pve/systemd/lxcfs-override.conf \
     /etc/systemd/system/lxcfs.service.d/override.conf

COPY scripts/common-entrypoint.sh /usr/local/lib/proxmox-common.sh
COPY pve/proxmox-docker-hostname.sh /usr/local/sbin/proxmox-docker-hostname.sh
COPY pve/entrypoint.sh /usr/local/sbin/proxmox-docker-boot.sh
COPY pve/healthcheck.sh /usr/local/sbin/healthcheck.sh
RUN chmod +x /usr/local/sbin/proxmox-docker-hostname.sh \
             /usr/local/sbin/proxmox-docker-boot.sh \
             /usr/local/sbin/healthcheck.sh

# Now that everything is configured, allow systemd to start units at
# runtime.
RUN rm -f /usr/sbin/policy-rc.d

LABEL org.opencontainers.image.title="Proxmox VE test image" \
      org.opencontainers.image.description="E2E-test-only PVE image. NOT FOR PRODUCTION. Ships hard-coded credentials, self-signed TLS, requires --privileged. See https://github.com/client-api/proxmox-docker" \
      org.opencontainers.image.source="https://github.com/client-api/proxmox-docker" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="client-api" \
      proxmox.channel="${PROXMOX_CHANNEL}" \
      proxmox.usage="test-only"

EXPOSE 8006

HEALTHCHECK --interval=5s --timeout=5s --retries=30 --start-period=60s \
    CMD ["/usr/local/sbin/healthcheck.sh"]

ENV PVE_HOSTNAME=pve-test \
    PVE_FQDN=pve-test.local \
    PVE_ROOT_PASSWORD=proxmox123 \
    PVE_API_TOKEN_NAME=test \
    PVE_SEED_FIXTURE_VM=1

# systemd's clean-shutdown signal — replaces SIGTERM for PID 1 = init.
STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/lib/systemd/systemd"]
