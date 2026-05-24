#!/bin/bash
#
# proxmox-docker post-boot orchestration for the PVE image.
#
# Invoked by the `proxmox-docker-boot.service` systemd unit, NOT as
# the container's PID 1. By the time we run, pmxcfs has mounted /etc/pve
# and pvedaemon/pveproxy are listening on :8006. Our job is:
#
#   1. Bring up a `vmbr0` Linux bridge so qemu-server can validate the
#      net0 stanza in VM configs.
#   2. Seed the root@pam password + the E2E API token.
#   3. Stage the 256-byte-vm fixture (vmid 100, "tiny-test") so
#      lifecycle smoke tests have something real to start/stop.
#
# Everything is idempotent — re-running the unit on container restart
# updates the password and refreshes the token without recreating the
# fixture disk.

set -euo pipefail

LOG_PREFIX=pve
# shellcheck source=../scripts/common-entrypoint.sh
source /usr/local/lib/proxmox-common.sh

: "${PVE_ROOT_PASSWORD:=proxmox123}"
: "${PVE_API_TOKEN_NAME:=test}"
: "${PVE_SEED_FIXTURE_VM:=1}"
: "${PVE_SEED_FIXTURE_CT:=1}"

readonly FIXTURE_VMID=100
readonly FIXTURE_NAME=tiny-test
readonly FIXTURE_SRC=/usr/local/share/proxmox-docker/boot.qcow2

readonly FIXTURE_CTID=200
readonly FIXTURE_CT_NAME=tiny-ct
# Set by the Dockerfile when the template is baked in; resolved at
# runtime from /var/lib/vz/template/cache/ to whatever Alpine release
# the image was built with.
readonly FIXTURE_CT_TEMPLATE_DIR=/var/lib/vz/template/cache

ensure_vmbr0() {
    # qemu-server validates that the bridge in net0 actually exists on
    # the host. On a real PVE install ifupdown brings up vmbr0 from
    # /etc/network/interfaces. In a container we create a Linux bridge
    # by hand — traffic has nowhere to go, the bridge only needs to
    # exist so config validation passes.
    if ip link show vmbr0 >/dev/null 2>&1; then
        log "vmbr0 already present"
        return 0
    fi
    log "creating vmbr0 stub bridge"
    ip link add vmbr0 type bridge
    ip link set vmbr0 up
}

wait_for_api() {
    # systemd starts pvedaemon and pveproxy in parallel with us. The
    # ordering directives nudge them ahead, but the API socket can
    # still take a beat to start accepting connections — give it up
    # to 30s.
    wait_for_https "https://localhost:8006/api2/json/version" 30
}

seed_credentials() {
    log "setting root@pam password"
    echo "root:${PVE_ROOT_PASSWORD}" | chpasswd

    # Drop any token from a previous boot so the new one is the only
    # value in /run/credentials.json.
    pveum user token remove "root@pam" "${PVE_API_TOKEN_NAME}" \
        --output-format json 2>/dev/null || true

    log "creating API token root@pam!${PVE_API_TOKEN_NAME}"
    local token_json token_value
    token_json=$(pveum user token add "root@pam" "${PVE_API_TOKEN_NAME}" \
        --privsep 0 \
        --comment "SDK E2E test token" \
        --output-format json 2>/dev/null || echo '{}')
    token_value=$(echo "$token_json" | jq -r '.value // empty')

    if [ -z "$token_value" ]; then
        log "WARNING: token creation returned no value (password auth still works)"
        token_value="(unavailable)"
    fi

    write_credentials \
        "$(hostname)" \
        "8006" \
        "root@pam" \
        "${PVE_ROOT_PASSWORD}" \
        "PVEAPIToken=root@pam!${PVE_API_TOKEN_NAME}" \
        "${token_value}"
}

# Ensure PVE's default `local` directory storage advertises `images`
# alongside the iso/vztmpl/backup content types it ships with. Without
# `images` in its content list, qemu-server refuses to allocate the
# fixture disk under it.
configure_local_storage() {
    local cfg=/etc/pve/storage.cfg
    if [ ! -s "$cfg" ]; then
        log "writing default storage.cfg"
        cat > "$cfg" <<'EOF'
dir: local
	path /var/lib/vz
	content images,iso,vztmpl,backup,snippets,rootdir
	shared 0
EOF
        return
    fi
    if ! grep -qE '^\s*content.*\bimages\b' "$cfg"; then
        log "extending local storage with images content type"
        sed -i -E 's/^(\s*content\s+)(.*)$/\1images,\2/' "$cfg"
    fi
}

# True when the kernel exposes the cgroup v2 unified hierarchy. PVE 9
# is cgroupv2-only — on a cgroupv1 host (e.g. WSL2's default) `pct
# start` writes an unparseable `lxc.cgroup.cpuset.cpus = ` line and
# the container won't boot. We still seed the CT config (so list/
# get/clone tests work), but skip start-time validation.
host_has_cgroupv2() {
    test -f /sys/fs/cgroup/cgroup.controllers
}

# Stage an Alpine LXC container at vmid 200. We invoke `pct create`
# (which extracts the template + writes the config) rather than
# building the config by hand, because pct's rootfs allocation
# negotiates with storage.cfg and we want that pre-flight to surface
# any misconfiguration loudly.
#
# `features=nesting=1` is the magic switch that lets a container run
# inside a container — without it, the kernel refuses some namespace
# operations that LXC needs.
seed_fixture_ct() {
    if [ "${PVE_SEED_FIXTURE_CT}" != "1" ]; then
        log "fixture CT seeding disabled (PVE_SEED_FIXTURE_CT=$PVE_SEED_FIXTURE_CT)"
        return 0
    fi
    if pct config "$FIXTURE_CTID" >/dev/null 2>&1; then
        log "CT ${FIXTURE_CTID} already configured — skipping create"
        return 0
    fi

    local template
    template=$(ls -1 "${FIXTURE_CT_TEMPLATE_DIR}"/alpine-*.tar.* 2>/dev/null | head -1 || true)
    if [ -z "$template" ]; then
        log "WARNING: no Alpine template under ${FIXTURE_CT_TEMPLATE_DIR} — skipping CT seed"
        return 0
    fi
    local template_name="${template##*/}"

    if ! host_has_cgroupv2; then
        log "WARNING: host is cgroupv1 — CT config will be seeded but \`pct start ${FIXTURE_CTID}\` will fail"
        log "         (PVE 9 LXC requires cgroupv2; switch the host to unified hierarchy or use a v2 runner)"
    fi

    log "creating CT ${FIXTURE_CTID} (${FIXTURE_CT_NAME}) from ${template_name}"
    # `unprivileged=0` keeps the CT root mapped to the host root, which
    # avoids the user-namespace machinery that fights with Docker. A
    # rootfs of 256 MiB on `local` (dir storage = raw) gives Alpine
    # enough headroom for /tmp scratch without bloating the image.
    pct create "$FIXTURE_CTID" \
        "local:vztmpl/${template_name}" \
        --hostname "$FIXTURE_CT_NAME" \
        --memory 64 \
        --swap 0 \
        --cores 1 \
        --rootfs "local:1" \
        --net0 "name=eth0,bridge=vmbr0,ip=dhcp,type=veth" \
        --ostype alpine \
        --unprivileged 0 \
        --features nesting=1 \
        --description "proxmox-docker fixture container — see https://github.com/client-api/proxmox-docker" \
        2>&1 || {
            log "WARNING: pct create failed; CT lifecycle will be unavailable"
            return 0
        }
}

# Stage the 256-byte-vm fixture as VM 100. Idempotent across boots —
# if the disk + config already exist, leave them in place.
seed_fixture_vm() {
    if [ "${PVE_SEED_FIXTURE_VM}" != "1" ]; then
        log "fixture VM seeding disabled (PVE_SEED_FIXTURE_VM=$PVE_SEED_FIXTURE_VM)"
        return 0
    fi
    if [ ! -s "$FIXTURE_SRC" ]; then
        log "WARNING: $FIXTURE_SRC missing — skipping fixture VM seed"
        return 0
    fi

    local disk_dir="/var/lib/vz/images/${FIXTURE_VMID}"
    local disk_path="${disk_dir}/vm-${FIXTURE_VMID}-disk-0.qcow2"
    local vm_conf="/etc/pve/qemu-server/${FIXTURE_VMID}.conf"

    install -d "$disk_dir"
    if [ ! -s "$disk_path" ]; then
        log "copying fixture disk to ${disk_path}"
        install -m 0640 "$FIXTURE_SRC" "$disk_path"
    fi

    if [ ! -s "$vm_conf" ]; then
        log "writing VM ${FIXTURE_VMID} (${FIXTURE_NAME}) config"
        # 64 MiB RAM, 1 vCPU, SeaBIOS, no guest agent. The guest's ACPI
        # power-button handler answers `qm shutdown` cleanly so tests
        # don't wait out the 3-minute force-kill timeout.
        cat > "$vm_conf" <<EOF
boot: order=scsi0
bios: seabios
cores: 1
memory: 64
name: ${FIXTURE_NAME}
net0: virtio,bridge=vmbr0
ostype: other
scsi0: local:${FIXTURE_VMID}/vm-${FIXTURE_VMID}-disk-0.qcow2,size=1M
scsihw: virtio-scsi-single
serial0: socket
vga: serial0
agent: 0
EOF
    fi
}

main() {
    print_test_only_banner
    ensure_vmbr0
    wait_for_api || exit 1
    seed_credentials
    configure_local_storage
    seed_fixture_vm
    seed_fixture_ct

    log "PVE test container ready on https://$(hostname):8006"
    log "  user:     root@pam"
    log "  password: ${PVE_ROOT_PASSWORD}"
    log "  token:    /run/credentials.json"
    if [ "${PVE_SEED_FIXTURE_VM}" = "1" ] && [ -s "$FIXTURE_SRC" ]; then
        log "  VM:       ${FIXTURE_VMID} (${FIXTURE_NAME}) — try \`qm start ${FIXTURE_VMID}\` if /dev/kvm is available"
    fi
    if [ "${PVE_SEED_FIXTURE_CT}" = "1" ] && pct config "$FIXTURE_CTID" >/dev/null 2>&1; then
        if host_has_cgroupv2; then
            log "  CT:       ${FIXTURE_CTID} (${FIXTURE_CT_NAME}) — try \`pct start ${FIXTURE_CTID}\`"
        else
            log "  CT:       ${FIXTURE_CTID} (${FIXTURE_CT_NAME}) — config only (host is cgroupv1, \`pct start\` unavailable)"
        fi
    fi
}

main "$@"
