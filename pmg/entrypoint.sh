#!/bin/bash
#
# Proxmox Mail Gateway test-image entrypoint.
#
# PMG is simpler than PVE/PBS — no pmxcfs FUSE mount, just a SQLite-
# backed config DB in /var/lib/pmg and two HTTP daemons.
#
# Boot sequence:
#   1. Configure hostname/FQDN/hosts
#   2. Initialise the PMG config DB if empty
#   3. Start pmgdaemon + pmgproxy
#   4. Wait for :8006 to answer
#   5. Seed root@pam password + create the E2E API token
#   6. Tail logs to keep PID 1 alive

set -euo pipefail

LOG_PREFIX=pmg
# shellcheck source=../scripts/common-entrypoint.sh
source /usr/local/lib/proxmox-common.sh

: "${PMG_HOSTNAME:=pmg-test}"
: "${PMG_FQDN:=pmg-test.local}"
: "${PMG_ROOT_PASSWORD:=proxmox123}"
: "${PMG_API_TOKEN_NAME:=test}"

start_postgres() {
    # PMG stores its user/rule/quarantine config in PostgreSQL, not in
    # a flat file the way PVE does. On a real install systemd brings
    # postgresql up before pmgdaemon; in the container we do it by
    # hand. `pg_ctlcluster` runs the cluster in the background.
    log "starting postgresql"
    local pg_version
    pg_version=$(ls /etc/postgresql/ 2>/dev/null | sort -n | tail -1)
    if [ -z "$pg_version" ]; then
        log "ERROR: no postgresql cluster config found under /etc/postgresql/"
        return 1
    fi
    pg_ctlcluster "$pg_version" main start 2>&1 \
        || log "WARNING: pg_ctlcluster start returned non-zero"
    # Wait for the socket — pmgdb init connects via /var/run/postgresql.
    local i
    for i in $(seq 1 20); do
        if su -s /bin/sh postgres -c 'psql -l' >/dev/null 2>&1; then
            log "postgresql ready"
            return 0
        fi
        sleep 1
    done
    log "ERROR: postgresql did not become ready within 20s"
    return 1
}

bootstrap_pmg_db() {
    log "initialising PMG database"
    install -d -m 0755 /var/lib/pmg /var/log/pmg /etc/pmg
    # `pmgdb init` is idempotent — on subsequent boots it sees the
    # existing schema and exits without recreating it.
    /usr/bin/pmgdb init 2>&1 || log "pmgdb init returned non-zero (may already exist)"
}

generate_certs() {
    log "ensuring TLS certificate exists"
    if [ ! -f /etc/pmg/pmg-api.pem ]; then
        # PMG uses /etc/pmg/pmg-api.pem for both cert and key. The
        # postinst usually generates one; we do it explicitly here to
        # decouple the first boot from systemd unit ordering.
        install -d -m 0700 /etc/pmg
        /usr/bin/pmgcm cert 2>&1 || log "pmgcm cert returned non-zero (may already exist)"
    fi
}

start_daemons() {
    log "starting pmgdaemon"
    pmgdaemon start
    log "starting pmgproxy"
    pmgproxy start
}

seed_credentials() {
    log "setting root@pam password (Linux shadow)"
    echo "root:${PMG_ROOT_PASSWORD}" | chpasswd

    # PMG 9.x does NOT expose an /access/users/{id}/token endpoint —
    # the /access subtree is ticket-only (ticket, auth-realm, oidc,
    # password, users, vncticket). The SDK's token-auth code path
    # therefore can't be exercised against PMG today; tests should
    # use password+ticket auth.
    log "PMG has no token API — skipping token creation (use ticket auth)"

    write_credentials \
        "${PMG_HOSTNAME}" \
        "8006" \
        "root@pam" \
        "${PMG_ROOT_PASSWORD}" \
        "PMGAPIToken=root@pam!${PMG_API_TOKEN_NAME}" \
        "(unsupported-by-pmg)"
}

main() {
    print_test_only_banner
    ensure_hostname "$PMG_HOSTNAME" "$PMG_FQDN"
    start_postgres
    bootstrap_pmg_db
    generate_certs
    start_daemons

    wait_for_https "https://localhost:8006/api2/json/version" 60 || exit 1
    seed_credentials

    log "PMG test container ready on https://${PMG_HOSTNAME}:8006"
    log "  user:     root@pam"
    log "  password: ${PMG_ROOT_PASSWORD}"
    log "  token:    /run/credentials.json"

    exec tail --pid=$$ -F \
        /var/log/pmgproxy/access.log \
        /var/log/daemon.log 2>/dev/null \
        || sleep infinity
}

main "$@"
