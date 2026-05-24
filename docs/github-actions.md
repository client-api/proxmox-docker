# GitHub Actions integration

This guide shows how to use the published `proxmox-docker` images as service
containers in GitHub Actions to run SDK E2E tests against a real Proxmox API.

## TL;DR — single-product workflow

```yaml
name: SDK E2E

on: [push, pull_request]

jobs:
  e2e-pve:
    runs-on: ubuntu-latest
    services:
      pve:
        image: ghcr.io/client-api/proxmox-docker/pve-test:latest
        options: >-
          --privileged
          --device /dev/fuse
          --health-cmd "curl -ksf -o /dev/null https://localhost:8006/api2/json/version && test -s /run/credentials.json"
          --health-interval 5s
          --health-retries 30
          --health-timeout 5s
          --health-start-period 30s
        ports:
          - 8006:8006

    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
        with: { version: 10 }
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: pnpm }

      - run: pnpm install --frozen-lockfile
      - run: pnpm test:e2e:pve
        env:
          PVE_URL: https://localhost:8006
          PVE_USER: root@pam
          PVE_PASSWORD: proxmox123
          PVE_REJECT_UNAUTHORIZED: 'false'  # self-signed cert
```

## Matrix across all four products

```yaml
jobs:
  e2e:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include:
          - product: pve
            image_tag: pve-test
            port: 8006
            health_path: /api2/json/version
          - product: pbs
            image_tag: pbs-test
            port: 8007
            health_path: /api2/json/version
          - product: pmg
            image_tag: pmg-test
            port: 8006
            health_path: /api2/json/version
          - product: pdm
            image_tag: pdm-test
            port: 8443
            health_path: /api2/extjs/version

    services:
      proxmox:
        image: ghcr.io/client-api/proxmox-docker/${{ matrix.image_tag }}:latest
        options: >-
          --privileged
          --device /dev/fuse
          --health-cmd "curl -ksf -o /dev/null https://localhost:${{ matrix.port }}${{ matrix.health_path }} && test -s /run/credentials.json"
          --health-interval 5s
          --health-retries 30
        ports:
          - ${{ matrix.port }}:${{ matrix.port }}

    steps:
      - uses: actions/checkout@v4
      - name: Read service credentials
        run: |
          docker exec ${{ job.services.proxmox.id }} \
            cat /run/credentials.json > creds.json
          jq -r 'to_entries[] | "\(.key | ascii_upcase)=\(.value)"' creds.json \
            >> "$GITHUB_ENV"
      - run: pnpm test:e2e:${{ matrix.product }}
```

The "Read service credentials" step copies `/run/credentials.json` out of the
container and lifts every field into the workflow environment as an
upper-cased variable (e.g. `URL`, `USER`, `PASSWORD`, `TOKEN_ID`, `TOKEN_VALUE`,
`TOKEN_HEADER_VALUE`). Your test code can then pick them up directly.

## Why `--privileged`?

PVE and PMG both mount their config directories via FUSE (`pmxcfs`). Inside
GitHub Actions runners, that mount requires:

- the `SYS_ADMIN` capability (Linux requirement for non-root FUSE)
- a writable `/dev/fuse`
- an unmasked `/sys` (Docker masks parts of `/sys` by default)

The simplest way to get all three is `--privileged`. You can theoretically
unprivilege the container with:

```
--cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor:unconfined
```

…but in practice GitHub-hosted runners enforce enough additional restrictions
that the unprivileged path is unreliable. **Use `--privileged`.**

PBS and PDM don't use pmxcfs, so they don't strictly need privileged mode —
but using it uniformly keeps the workflow matrix simple.

## Network considerations

- The container's self-signed TLS cert won't validate against the system CA.
  Tell your SDK client to skip verification (or trust the cert). For the
  `node-fetch`-style SDKs, set the `NODE_TLS_REJECT_UNAUTHORIZED=0` env var
  for the test process only.
- The container hostname is `pve-test` (resp. `pbs-test`, etc.) by default.
  The cert is issued for that name. If your test code matches hostname, hit
  `https://localhost:<port>` and disable hostname verification, or override
  `PVE_HOSTNAME` at container start.

## Speed budget

| Product | Cold-start | Image size |
|---------|------------|------------|
| PVE     | 25–45 s    | ~600 MB    |
| PBS     | 10–20 s    | ~350 MB    |
| PMG     | 20–35 s    | ~500 MB    |
| PDM     | 8–15 s     | ~250 MB    |

GitHub Actions service containers run in parallel with your `steps:` — by
the time your `pnpm install` finishes, the container is usually already
healthy. The healthcheck blocks the job until the API responds.

## Credentials reference

All four images bake in the same default credentials:

| Field | Value |
|-------|-------|
| Root realm user | `root@pam` |
| Root password   | `proxmox123` |
| API token name  | `root@pam!test` |

The token *value* is regenerated on every container boot — read it from
`/run/credentials.json`:

```bash
docker exec <container> cat /run/credentials.json
```

To override the root password, set the matching env var on container start:

| Image     | Env var               |
|-----------|-----------------------|
| pve-test  | `PVE_ROOT_PASSWORD`   |
| pbs-test  | `PBS_ROOT_PASSWORD`   |
| pmg-test  | `PMG_ROOT_PASSWORD`   |
| pdm-test  | `PDM_ROOT_PASSWORD`   |
