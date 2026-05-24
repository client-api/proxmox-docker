#!/bin/bash
# PDM Docker HEALTHCHECK.
#
# PDM requires auth on every API endpoint including /version, so we
# can't use curl's -f flag (which fails on 4xx). A 401 with a real
# JSON body still means the daemon is up — that's what we care about.
set -euo pipefail

code=$(curl -ks -o /dev/null -w '%{http_code}' \
    https://localhost:8443/api2/extjs/version 2>/dev/null || echo "000")

# 200 (unexpected — would mean auth disabled) or 401 (the normal case)
# both indicate the HTTPS server is alive and parsing requests.
case "$code" in
    200|401) ;;
    *)
        echo "unexpected HTTP status from /api2/extjs/version: $code" >&2
        exit 1
        ;;
esac

test -s /run/credentials.json
