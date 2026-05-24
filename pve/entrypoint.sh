#!/bin/bash
#
# Proxmox VE test-image entrypoint.
#
# Boot sequence:
#   1. Configure hostname/FQDN/hosts so PVE sees itself as a real node
#   2. Mount /etc/pve via pmxcfs in standalone (local) mode
#   3. Generate self-signed certs via pvecm updatecerts
#   4. Start pvedaemon, pvestatd, pveproxy
#   5. Wait for the API to answer on :8006
#   6. Seed root@pam password + create the E2E API token
#   7. Tail logs to keep PID 1 alive

set -euo pipefail

LOG_PREFIX=pve
# shellcheck source=../scripts/common-entrypoint.sh
source /usr/local/lib/proxmox-common.sh

: "${PVE_HOSTNAME:=pve-test}"
: "${PVE_FQDN:=pve-test.local}"
: "${PVE_ROOT_PASSWORD:=proxmox123}"
: "${PVE_API_TOKEN_NAME:=test}"

start_pmxcfs() {
    log "starting pmxcfs in local mode"
    mkdir -p /var/lib/pve-cluster /etc/pve

    # -l (local) → run without corosync; we only need /etc/pve mounted
    # so the rest of PVE can read its config.
    pmxcfs -l &
    CHILD_PIDS+=($!)

    local i
    for i in $(seq 1 30); do
        if mountpoint -q /etc/pve; then
            log "pmxcfs mounted (/etc/pve)"
            return 0
        fi
        sleep 1
    done
    log "ERROR: pmxcfs failed to mount /etc/pve within 30s"
    log "hint: container needs --privileged (or --cap-add SYS_ADMIN --device /dev/fuse)"
    exit 1
}

generate_certs() {
    log "generating PVE certificates"
    # Updatecerts is idempotent and runs on every boot — it'll reuse the
    # CA when one already exists. We don't fail the boot if it returns
    # non-zero because a missing /etc/pve/priv on first boot can trigger
    # one spurious "not a directory" warning.
    pvecm updatecerts --force 2>&1 || true
}

start_daemons() {
    log "starting pvedaemon"
    pvedaemon start
    log "starting pvestatd"
    pvestatd start
    log "starting pveproxy"
    pveproxy start
}

seed_credentials() {
    log "setting root@pam password"
    echo "root:${PVE_ROOT_PASSWORD}" | chpasswd

    # Remove any token left over from a previous boot so the create
    # below is deterministic.
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
        "${PVE_HOSTNAME}" \
        "8006" \
        "root@pam" \
        "${PVE_ROOT_PASSWORD}" \
        "PVEAPIToken=root@pam!${PVE_API_TOKEN_NAME}" \
        "${token_value}"
}

main() {
    print_test_only_banner
    ensure_hostname "$PVE_HOSTNAME" "$PVE_FQDN"
    start_pmxcfs
    generate_certs
    start_daemons

    wait_for_https "https://localhost:8006/api2/json/version" 60 || exit 1
    seed_credentials

    log "PVE test container ready on https://${PVE_HOSTNAME}:8006"
    log "  user:     root@pam"
    log "  password: ${PVE_ROOT_PASSWORD}"
    log "  token:    /run/credentials.json"

    # Keep PID 1 alive. Log files are tailed for observability; the
    # SIGTERM trap handles graceful shutdown.
    touch /var/log/pveproxy/access.log 2>/dev/null || true
    exec tail --pid=$$ -F \
        /var/log/pveproxy/access.log \
        /var/log/daemon.log 2>/dev/null \
        || sleep infinity
}

main "$@"
