#!/bin/bash
#
# Set /etc/hostname + /etc/hosts so pmxcfs has a stable, resolvable
# FQDN before pve-cluster.service starts. Runs as a oneshot via
# proxmox-docker-hostname.service.
#
# Override at runtime by passing PVE_HOSTNAME / PVE_FQDN to
# `docker run -e`.

set -euo pipefail

: "${PVE_HOSTNAME:=pve-test}"
: "${PVE_FQDN:=${PVE_HOSTNAME}.local}"

ip=$(ip -4 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' \
        | cut -d/ -f1 \
        | head -1 || true)
# Fall back to the Debian-conventional non-loopback loopback so PVE's
# "must not be 127.0.0.1" check passes even on an entirely network-
# less container.
[ -z "$ip" ] && ip="127.0.1.1"

echo "[hostname-unit] setting hostname=$PVE_HOSTNAME fqdn=$PVE_FQDN ip=$ip"

echo "$PVE_HOSTNAME" > /etc/hostname
hostname "$PVE_HOSTNAME" 2>/dev/null || true

cat > /etc/hosts <<EOF
127.0.0.1 localhost
$ip $PVE_FQDN $PVE_HOSTNAME
::1 ip6-localhost ip6-loopback
EOF
