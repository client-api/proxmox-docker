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
          --device /dev/kvm
          --tmpfs /tmp
          --tmpfs /run
          --tmpfs /run/lock
          --health-cmd "/usr/local/sbin/healthcheck.sh"
          --health-interval 5s
          --health-retries 30
          --health-timeout 5s
          --health-start-period 60s
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
          --tmpfs /tmp
          --tmpfs /run
          --tmpfs /run/lock
          --health-cmd "/usr/local/sbin/healthcheck.sh"
          --health-interval 5s
          --health-retries 30
          --health-start-period 60s
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

The PVE and PMG images need it for two reasons:

- pmxcfs is a FUSE mount — needs `SYS_ADMIN` capability and a writable
  `/dev/fuse`
- The PVE image runs systemd as PID 1 (so `qm start` can place QEMU in
  a transient systemd scope), and systemd needs writable cgroup
  hierarchies inside the container.

The simplest way to get both is `--privileged`. PBS and PDM don't use
pmxcfs or systemd; they only need privileged mode for symmetry with
PVE/PMG in matrix jobs.

## VM lifecycle in PVE (`--device /dev/kvm`)

The PVE image ships a 1 MiB SeaBIOS-bootable fixture VM at vmid 100
(`tiny-test`, sourced from the
[256-byte-vm](https://github.com/client-api/256-byte-vm) release).
If the runner has `/dev/kvm` and you pass it through with
`--device /dev/kvm`, the full `qm start` / `qm shutdown` / `qm stop`
cycle works against this VM.

`ubuntu-latest` runners have had nested KVM since 2024-06; older
self-hosted runners or non-Azure providers may not. Detect at runtime:

```yaml
- name: Detect /dev/kvm
  id: kvm
  run: |
    if [ -e /dev/kvm ]; then
      echo "device_arg=--device /dev/kvm" >> "$GITHUB_OUTPUT"
    else
      echo "device_arg=" >> "$GITHUB_OUTPUT"
    fi
```

Without `/dev/kvm`, every config-level VM endpoint still works
(create, list, get, snapshot config, clone config, …). Only the
`start` operation hard-fails.

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
