#!/bin/bash
#
# Proxmox Backup Server test-image entrypoint.
#
# PBS ships two Rust daemons (in /usr/lib/x86_64-linux-gnu/proxmox-backup/):
#   - proxmox-backup-api    — root-side API socket, runs as root
#   - proxmox-backup-proxy  — HTTPS frontend on :8007, runs as `backup`
#
# Boot sequence:
#   1. Configure hostname/FQDN/hosts
#   2. Ensure the `backup` system user exists (postinst creates it on
#      a real install; we guard here in case the base image shifts)
#   3. Create /run/proxmox-backup for PID files
#   4. Start the API daemon, then the proxy
#   5. Wait for :8007
#   6. Seed root@pam password + create the E2E API token
#   7. Tail logs to keep PID 1 alive

set -euo pipefail

LOG_PREFIX=pbs
# shellcheck source=../scripts/common-entrypoint.sh
source /usr/local/lib/proxmox-common.sh

: "${PBS_HOSTNAME:=pbs-test}"
: "${PBS_FQDN:=pbs-test.local}"
: "${PBS_ROOT_PASSWORD:=proxmox123}"
: "${PBS_API_TOKEN_NAME:=test}"

readonly PBS_API=/usr/lib/x86_64-linux-gnu/proxmox-backup/proxmox-backup-api
readonly PBS_PROXY=/usr/lib/x86_64-linux-gnu/proxmox-backup/proxmox-backup-proxy

prepare_user() {
    # The proxmox-backup-server postinst creates the `backup` system
    # user. With policy-rc.d returning 101 the postinst may skip a few
    # of its steps; we guard the user creation here.
    if ! id backup >/dev/null 2>&1; then
        adduser --system --group --no-create-home --quiet backup
    fi
}

prepare_runtime_dir() {
    # The daemons take care of /etc/proxmox-backup, /var/lib/proxmox-backup,
    # and /var/log/proxmox-backup on first start. The ONE thing they
    # can't do for us is mount /run/proxmox-backup as tmpfs — on a real
    # install that's handled by the package-shipped systemd unit
    # `run-proxmox\x2dbackup.mount` (`Type=tmpfs … uid=backup gid=backup`).
    # Without that mount PBS's TrafficControlCache fails with
    # `path "/run/proxmox-backup/shmem" is not on tmpfs` and every
    # subsequent request returns 401.
    install -d /run/proxmox-backup
    if ! mountpoint -q /run/proxmox-backup; then
        mount -t tmpfs \
            -o nodev,nosuid,noexec,uid=backup,gid=backup,mode=0755,nr_inodes=0,inode64 \
            tmpfs /run/proxmox-backup
    fi
}

start_daemons() {
    log "starting proxmox-backup-api"
    "$PBS_API" &
    CHILD_PIDS+=($!)
    # The proxy can't bind until the API socket exists.
    sleep 2

    log "starting proxmox-backup-proxy"
    runuser -u backup -- "$PBS_PROXY" &
    CHILD_PIDS+=($!)
}

seed_credentials() {
    # `root@pam` is the PAM-realm root — its password lives in /etc/shadow,
    # NOT in PBS's user.cfg. `proxmox-backup-manager user update root@pam
    # --password ...` would only touch user.cfg metadata; for the actual
    # ticket flow to accept us, we have to set the Linux password.
    log "setting root@pam password (Linux shadow)"
    echo "root:${PBS_ROOT_PASSWORD}" | chpasswd

    # Drop any previous token (idempotent across container restarts).
    proxmox-backup-manager user delete-token root@pam "${PBS_API_TOKEN_NAME}" \
        2>/dev/null || true

    log "creating API token root@pam!${PBS_API_TOKEN_NAME}"
    # `proxmox-backup-manager user generate-token` doesn't accept
    # --output-format on the current CLI build despite the docs; it
    # always prints `Result: { … JSON … }`. Strip the "Result: " prefix
    # and feed the rest to jq.
    local token_raw token_value
    token_raw=$(proxmox-backup-manager user generate-token \
        root@pam "${PBS_API_TOKEN_NAME}" 2>/dev/null || echo '')
    token_value=$(echo "$token_raw" \
        | sed 's/^Result: //' \
        | jq -r '.value // empty' 2>/dev/null || echo '')

    if [ -z "$token_value" ]; then
        log "WARNING: token creation returned no value (password auth still works)"
        token_value="(unavailable)"
    else
        # Grant the token full admin on / so it can do anything an SDK
        # test would do; without an explicit ACL, every authenticated
        # request returns 403.
        proxmox-backup-manager acl update / Admin \
            --auth-id "root@pam!${PBS_API_TOKEN_NAME}" \
            2>&1 || log "WARNING: ACL grant for token returned non-zero"
    fi

    write_credentials \
        "${PBS_HOSTNAME}" \
        "8007" \
        "root@pam" \
        "${PBS_ROOT_PASSWORD}" \
        "PBSAPIToken=root@pam!${PBS_API_TOKEN_NAME}" \
        "${token_value}" \
        ":"
}

main() {
    print_test_only_banner
    ensure_hostname "$PBS_HOSTNAME" "$PBS_FQDN"
    prepare_user
    prepare_runtime_dir
    start_daemons

    wait_for_https "https://localhost:8007/api2/json/version" 60 || exit 1
    seed_credentials

    log "PBS test container ready on https://${PBS_HOSTNAME}:8007"
    log "  user:     root@pam"
    log "  password: ${PBS_ROOT_PASSWORD}"
    log "  token:    /run/credentials.json"

    exec tail --pid=$$ -F \
        /var/log/proxmox-backup/api/api.log \
        /var/log/proxmox-backup/api/proxy.log 2>/dev/null \
        || sleep infinity
}

main "$@"
