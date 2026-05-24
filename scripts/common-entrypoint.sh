#!/bin/bash
#
# Shared helpers for the per-product entrypoint scripts. Each product
# sources this file and then calls product-specific functions.
#
# Conventions used by every product:
#   - Container hostname is set from $<PRODUCT>_HOSTNAME (e.g. PVE_HOSTNAME)
#   - /etc/hosts maps the hostname to a non-127.0.0.1 address (Proxmox
#     refuses to start otherwise)
#   - Credentials are written to /run/credentials.json on every boot
#   - All daemons are launched in the background; the entrypoint then
#     tails their logs to keep PID 1 alive

set -euo pipefail

log() {
    local prefix="${LOG_PREFIX:-proxmox}"
    echo "[$prefix] $*" >&2
}

# Print the test-only banner once at every boot. Keeps the warning
# visible to anyone who runs the container outside of CI and reads
# `docker logs`.
print_test_only_banner() {
    cat >&2 <<'EOF'

============================================================
  E2E TEST IMAGE — NOT FOR PRODUCTION USE
  - Hard-coded credentials (root@pam / proxmox123)
  - Self-signed TLS certificate
  - Requires --privileged
  - Workload paths (VMs, backups, mail, cluster) inoperative
  See: https://github.com/client-api/proxmox-docker
============================================================

EOF
}

# Pick the first non-loopback IPv4 we can find on this container.
# Falls back to 127.0.1.1 (a routable-looking loopback alias) so the
# hostname always resolves to something the Proxmox stack tolerates.
container_ip() {
    local ip
    ip=$(ip -4 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' \
        | cut -d/ -f1 \
        | head -1 || true)
    if [ -z "$ip" ]; then
        ip="127.0.1.1"
    fi
    echo "$ip"
}

# Configure /etc/hostname + /etc/hosts so PVE/PBS/PMG/PDM see a stable
# FQDN. Must be invoked before any Proxmox daemon starts.
ensure_hostname() {
    local hostname="$1"
    local fqdn="$2"
    local ip
    ip=$(container_ip)

    echo "$hostname" > /etc/hostname
    hostname "$hostname" 2>/dev/null || true

    cat > /etc/hosts <<EOF
127.0.0.1 localhost
$ip $fqdn $hostname
::1 ip6-localhost ip6-loopback
EOF

    log "hostname=$hostname fqdn=$fqdn ip=$ip"
}

# Poll an HTTPS URL until it returns any HTTP response (not just 2xx/3xx),
# or fail after $2 seconds. We treat a 401 as "the daemon is up" because
# some products (PDM) require auth on every endpoint including /version
# — what we care about is that TLS handshakes succeed and the server
# emits a real HTTP status line, not that it lets us in.
wait_for_https() {
    local url="$1"
    local timeout="${2:-60}"
    local i code

    for i in $(seq 1 "$timeout"); do
        code=$(curl -ks -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")
        # Anything in the 1xx–5xx range means the HTTP server is alive.
        # "000" means curl couldn't establish a connection — keep polling.
        if [ "$code" != "000" ] && [ "$code" -ge 100 ] && [ "$code" -le 599 ]; then
            log "ready: $url → $code (after ${i}s)"
            return 0
        fi
        sleep 1
    done
    log "ERROR: $url did not respond within ${timeout}s"
    return 1
}

# Emit a credentials JSON file consumed by SDK tests. The shape is
# product-agnostic — test code can read /run/credentials.json without
# branching on which Proxmox image it's pointed at.
#
# $7 is the separator between the token id and the token value in the
# Authorization-header form:
#
#   Perl family (PVE, PMG):  "="    → PVEAPIToken=root@pam!test=<uuid>
#   Rust family (PBS, PDM):  ":"    → PBSAPIToken=root@pam!test:<uuid>
#
# The two stacks (`pve-http-server` in Perl vs `proxmox-rest-server`
# in Rust) parse the header differently. We bake the right separator
# into `token_header_value` so callers never have to know.
write_credentials() {
    local host="$1"
    local port="$2"
    local user="$3"
    local password="$4"
    local token_id="$5"
    local token_value="$6"
    local token_sep="${7:-=}"
    local realm="${user##*@}"

    cat > /run/credentials.json <<EOF
{
  "host": "$host",
  "port": "$port",
  "url": "https://$host:$port",
  "user": "$user",
  "password": "$password",
  "realm": "$realm",
  "token_id": "$token_id",
  "token_value": "$token_value",
  "token_separator": "$token_sep",
  "token_header_value": "${token_id}${token_sep}${token_value}"
}
EOF
    chmod 0644 /run/credentials.json
    log "credentials written to /run/credentials.json"
}

# Forward SIGTERM/SIGINT to backgrounded daemons. Each product's
# entrypoint appends PIDs to $CHILD_PIDS.
declare -a CHILD_PIDS=()

graceful_shutdown() {
    log "received shutdown signal; stopping daemons"
    local pid
    for pid in "${CHILD_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    wait || true
    exit 0
}

trap graceful_shutdown TERM INT
