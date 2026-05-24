#!/bin/bash
# PMG Docker HEALTHCHECK — see ../pve/healthcheck.sh for the rationale.
set -euo pipefail

code=$(curl -ks -o /dev/null -w '%{http_code}' \
    https://localhost:8006/api2/json/version 2>/dev/null || echo "000")
case "$code" in
    2??|401) ;;
    *) echo "unexpected /api2/json/version status: $code" >&2; exit 1 ;;
esac

test -s /run/credentials.json
