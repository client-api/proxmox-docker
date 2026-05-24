#!/bin/bash
#
# Proxmox Datacenter Manager test-image entrypoint.
#
# PDM ships two Rust daemons (in /usr/libexec/proxmox, NOT /usr/sbin):
#   - proxmox-datacenter-api            — public HTTPS server on :8443
#                                         (normally runs as www-data)
#   - proxmox-datacenter-privileged-api — root-only operations,
#                                         called by the public API
#                                         over a UNIX socket
#
# The management CLI is /usr/sbin/proxmox-datacenter-manager-admin.
#
# Both daemons are Type=notify under systemd; without sd_notify they
# don't try to signal anything, they just run.
#
# Boot sequence:
#   1. Configure hostname/FQDN/hosts
#   2. Pre-create config dirs
#   3. Run privileged-api 'setup' (idempotent — creates initial config)
#   4. Start privileged-api (as root)
#   5. Start the public api (as www-data)
#   6. Wait for :8443 to answer
#   7. Seed root@pam password + create the E2E API token
#   8. Tail logs to keep PID 1 alive

set -euo pipefail

LOG_PREFIX=pdm
# shellcheck source=../scripts/common-entrypoint.sh
source /usr/local/lib/proxmox-common.sh

: "${PDM_HOSTNAME:=pdm-test}"
: "${PDM_FQDN:=pdm-test.local}"
: "${PDM_ROOT_PASSWORD:=proxmox123}"
: "${PDM_API_TOKEN_NAME:=test}"

readonly PDM_PRIV_API=/usr/libexec/proxmox/proxmox-datacenter-privileged-api
readonly PDM_API=/usr/libexec/proxmox/proxmox-datacenter-api
readonly PDM_ADMIN=/usr/sbin/proxmox-datacenter-manager-admin

prepare_user() {
    # The PDM postinst doesn't create the www-data system user (it
    # assumes Debian's base-passwd or another package put it there). On
    # debian:trixie-slim it's already present, but we guard anyway —
    # if a future base image drops it, the daemons will exit silently
    # otherwise.
    if ! id www-data >/dev/null 2>&1; then
        adduser --system --group --no-create-home --quiet www-data
    fi

    # NOTE: We intentionally do NOT pre-create
    # /etc/proxmox-datacenter-manager, /var/lib/..., /var/log/..., or
    # /run/... here. The privileged-api `setup` subcommand creates each
    # directory with the exact ownership + mode bits it then validates
    # on every subsequent boot — pre-creating with even slightly wrong
    # permissions causes setup to refuse to proceed.
}

run_privileged_setup() {
    if [ ! -x "$PDM_PRIV_API" ]; then
        log "ERROR: $PDM_PRIV_API not found"
        exit 1
    fi
    log "running privileged-api setup"
    "$PDM_PRIV_API" setup 2>&1 || log "WARNING: setup returned non-zero"
}

start_daemons() {
    log "starting proxmox-datacenter-privileged-api"
    "$PDM_PRIV_API" &
    CHILD_PIDS+=($!)
    sleep 1

    log "starting proxmox-datacenter-api"
    # The public API normally drops privileges to www-data via the
    # systemd unit's User= directive. We replicate that with `runuser`
    # so file ownership in /var/lib stays consistent with a real install.
    runuser -u www-data -- "$PDM_API" &
    CHILD_PIDS+=($!)
}

seed_credentials() {
    log "setting root@pam password"
    echo "root:${PDM_ROOT_PASSWORD}" | chpasswd

    # PDM 1.0.x's admin CLI (`proxmox-datacenter-manager-admin`) doesn't
    # expose a `user` subcommand for token management. Create the token
    # over the public API instead — login via ticket, then POST to the
    # access/users/<user>/token/<id> endpoint with the CSRF header.
    local ticket csrf token_value cookie_jar=/tmp/pdm-cookie.txt

    log "fetching root@pam ticket for token creation"
    # PDM's /access/ticket response sets the ticket cookie as
    # `__Host-PDMAuthCookie` (Secure + HttpOnly + Path=/ prefix) via a
    # Set-Cookie header — it is NOT in the JSON body the way PVE does.
    # The body only echoes `CSRFPreventionToken`, `ticket-info`, and
    # `username`. So we drive curl through a cookie jar (which it then
    # replays automatically on the DELETE/POST below) and pull the
    # CSRF token from the JSON body.
    #
    # The daemon accepts /version well before its PAM auth path is
    # primed; retry for up to 20s so a slow-starting nightly doesn't
    # end up tokenless.
    local body_file=/tmp/pdm-ticket.body
    local i body
    for i in $(seq 1 20); do
        > "$cookie_jar"
        curl -ks -c "$cookie_jar" -o "$body_file" \
            -d "username=root@pam&password=${PDM_ROOT_PASSWORD}" \
            https://localhost:8443/api2/extjs/access/ticket 2>/dev/null || true
        body=$(cat "$body_file" 2>/dev/null || echo '{}')
        csrf=$(echo "$body" | jq -r '.data.CSRFPreventionToken // empty')
        # Any non-comment line in the cookie jar means we got an auth
        # cookie. Don't care about its exact name — curl will replay it.
        if grep -q -v '^#' "$cookie_jar" 2>/dev/null && [ -n "$csrf" ]; then
            ticket="set"  # sentinel, only used for the empty-check below
            break
        fi
        sleep 1
    done

    if [ -z "${ticket:-}" ] || [ -z "$csrf" ]; then
        log "WARNING: could not obtain a ticket after 20s; skipping token creation"
        log "  body: $body"
        token_value="(unavailable)"
    else
        # Drop any previous token first (idempotent across container restarts).
        curl -ks -X DELETE \
            -b "$cookie_jar" \
            -H "CSRFPreventionToken: $csrf" \
            "https://localhost:8443/api2/extjs/access/users/root@pam/token/${PDM_API_TOKEN_NAME}" \
            >/dev/null 2>&1 || true

        log "creating API token root@pam!${PDM_API_TOKEN_NAME}"
        # PDM's token-create endpoint rejects `privsep` (the param PVE/PBS
        # accept) — its schema doesn't have it. Posting with no body
        # creates a token with whatever privsep default the server uses.
        local create_resp
        create_resp=$(curl -ks -X POST \
            -b "$cookie_jar" \
            -H "CSRFPreventionToken: $csrf" \
            "https://localhost:8443/api2/extjs/access/users/root@pam/token/${PDM_API_TOKEN_NAME}" \
            2>/dev/null || echo '{}')
        token_value=$(echo "$create_resp" | jq -r '.data.value // empty')

        if [ -z "$token_value" ]; then
            log "WARNING: token API returned no value (password auth still works)"
            log "  response: $create_resp"
            token_value="(unavailable)"
        else
            # Grant the token Administrator on the entire path so it can
            # do anything an SDK test would do. Without this, token auth
            # would succeed but every request would 403.
            #
            # KNOWN LIMITATION (PDM 1.0.4): even with this ACL grant
            # persisted to /etc/proxmox-datacenter-manager/access/acl.cfg,
            # `Authorization: PDMAPIToken=root@pam!test=<uuid>` still
            # returns 401 in the current PDM build. The token row is
            # written, the ACL row is written, but the token verifier
            # in the public-api crate doesn't match. Once that upstream
            # bug is fixed, this seed becomes functional with no change
            # needed here.
            curl -ks -X PUT \
                -b "$cookie_jar" \
                -H "CSRFPreventionToken: $csrf" \
                --data-urlencode "auth-id=root@pam!${PDM_API_TOKEN_NAME}" \
                --data-urlencode "path=/" \
                --data-urlencode "role=Administrator" \
                --data-urlencode "propagate=1" \
                "https://localhost:8443/api2/extjs/access/acl" \
                >/dev/null 2>&1 || true
        fi
    fi

    rm -f "$cookie_jar" "$body_file"

    write_credentials \
        "${PDM_HOSTNAME}" \
        "8443" \
        "root@pam" \
        "${PDM_ROOT_PASSWORD}" \
        "PDMAPIToken=root@pam!${PDM_API_TOKEN_NAME}" \
        "${token_value}" \
        ":"
}

main() {
    print_test_only_banner
    ensure_hostname "$PDM_HOSTNAME" "$PDM_FQDN"
    prepare_user
    run_privileged_setup
    start_daemons

    wait_for_https "https://localhost:8443/api2/extjs/version" 90 \
        || wait_for_https "https://localhost:8443/api2/json/version" 30 \
        || exit 1
    seed_credentials

    log "PDM test container ready on https://${PDM_HOSTNAME}:8443"
    log "  user:     root@pam"
    log "  password: ${PDM_ROOT_PASSWORD}"
    log "  token:    /run/credentials.json"

    exec tail --pid=$$ -F \
        /var/log/proxmox-datacenter-manager/*.log 2>/dev/null \
        || sleep infinity
}

main "$@"
