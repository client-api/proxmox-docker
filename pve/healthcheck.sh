#!/bin/bash
# PVE Docker HEALTHCHECK.
#
# /api2/json/version emits 401 on PVE 9.x without an Authorization
# header, so we can't use `curl -f` (which treats 4xx as failure).
# A real HTTP response — anything in 100–599 — proves the proxy is
# alive and accepting requests. The entrypoint also writes
# /run/credentials.json after seeding root@pam + the API token, so a
# missing/empty file means the seed step didn't complete yet.
set -euo pipefail

code=$(curl -ks -o /dev/null -w '%{http_code}' \
    https://localhost:8006/api2/json/version 2>/dev/null || echo "000")
case "$code" in
    2??|401) ;;
    *) echo "unexpected /api2/json/version status: $code" >&2; exit 1 ;;
esac

test -s /run/credentials.json
