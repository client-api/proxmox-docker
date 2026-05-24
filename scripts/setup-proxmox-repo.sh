#!/bin/bash
#
# Shared Proxmox apt-repository setup. Sourced (or invoked) from every
# product Dockerfile.
#
# Usage:
#   PROXMOX_PRODUCT=pve|pbs|pmg|pdm \
#   PROXMOX_CHANNEL=no-subscription|test \
#   scripts/setup-proxmox-repo.sh
#
# PROXMOX_CHANNEL selects which apt component to wire up:
#   - no-subscription (default): the current stable, what most users run
#   - test:                       the upstream "testing" channel, used by
#                                 the nightly :dev image builds to surface
#                                 breakage before it lands in stable
#
# Requires DEBIAN_FRONTEND=noninteractive and root.

set -euo pipefail

product="${PROXMOX_PRODUCT:?must set PROXMOX_PRODUCT to one of pve|pbs|pmg|pdm}"
channel="${PROXMOX_CHANNEL:-no-subscription}"

case "$product" in
    pve|pbs|pmg|pdm) ;;
    *)
        echo "Unknown PROXMOX_PRODUCT: $product" >&2
        exit 1
        ;;
esac

case "$channel" in
    no-subscription|test) ;;
    *)
        echo "Unknown PROXMOX_CHANNEL: $channel (allowed: no-subscription, test)" >&2
        exit 1
        ;;
esac

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg

install -d -m 0755 /usr/share/keyrings
curl -fsSL https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
    -o /usr/share/keyrings/proxmox-archive-keyring.gpg

# Verify the SHA256 hash matches the one published in the wiki, so an
# upstream key swap surfaces as a build failure rather than a silent
# trust-on-first-use.
expected="136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45"
actual=$(sha256sum /usr/share/keyrings/proxmox-archive-keyring.gpg | awk '{print $1}')
if [ "$actual" != "$expected" ]; then
    echo "Proxmox archive keyring hash mismatch:" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
fi

cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/${product}
Suites: trixie
Components: ${product}-${channel}
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

echo "[setup-proxmox-repo] product=${product} channel=${channel}"
apt-get update
