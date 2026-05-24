# Using proxmox-docker in GitHub Actions

This is the integration guide for running the `proxmox-docker` images
as part of a GitHub Actions workflow. The images exist so SDK clients
generated from the Proxmox OpenAPI specs can be tested against a real
Proxmox API surface; everything below assumes that use case.

Sections:

- [Picking an image tag](#picking-an-image-tag)
- [Single-product service container](#single-product-service-container)
- [Matrix across all four products](#matrix-across-all-four-products)
- [Enabling KVM (real VM lifecycle)](#enabling-kvm-real-vm-lifecycle)
- [Enabling LXC (real container lifecycle)](#enabling-lxc-real-container-lifecycle)
- [Reading the credentials JSON](#reading-the-credentials-json)
- [TLS, self-signed certificates](#tls-self-signed-certificates)
- [Tracking the dev channel](#tracking-the-dev-channel)
- [Running with `docker run` instead of a service container](#running-with-docker-run-instead-of-a-service-container)
- [Run-flag reference](#run-flag-reference)
- [Troubleshooting](#troubleshooting)

---

## Picking an image tag

Quick recommendations, in priority order:

| Goal                                          | Tag                                |
|-----------------------------------------------|------------------------------------|
| Reproducible production CI                    | `<version>` (e.g. `9.2.2`)         |
| Patch updates within a minor                  | `<major>.<minor>` (e.g. `9.2`)     |
| Newest stable, accept drift                   | `latest`                           |
| Surface upstream regressions early            | `dev`                              |
| Byte-exact audit                              | `stable-YYYYMMDD` / `sha-<short>`  |

Full policy: [`VERSIONING.md`](../VERSIONING.md).

---

## Single-product service container

The simplest workflow: one Proxmox image as a service container, one
job that talks to it.

```yaml
name: SDK E2E (PVE)

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  e2e:
    runs-on: ubuntu-latest

    services:
      pve:
        image: ghcr.io/client-api/proxmox-docker/pve-test:9.2
        options: >-
          --privileged
          --device /dev/fuse
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

      - name: Wait for PVE container to settle
        run: |
          for i in {1..60}; do
            status=$(docker inspect -f '{{.State.Health.Status}}' \
              "${{ job.services.pve.id }}" 2>/dev/null || echo "unknown")
            if [ "$status" = "healthy" ]; then
              echo "PVE healthy"; exit 0
            fi
            echo "PVE health=$status (attempt $i/60)"
            sleep 2
          done
          echo "::error::PVE did not become healthy within 2 minutes"
          docker logs "${{ job.services.pve.id }}"
          exit 1

      - name: Load credentials into env
        run: |
          docker exec "${{ job.services.pve.id }}" \
            cat /run/credentials.json > pve-creds.json
          {
            echo "PVE_URL=https://localhost:8006"
            echo "PVE_USER=$(jq -r .user pve-creds.json)"
            echo "PVE_PASSWORD=$(jq -r .password pve-creds.json)"
            echo "PVE_TOKEN_HEADER_VALUE=$(jq -r .token_header_value pve-creds.json)"
            echo "NODE_TLS_REJECT_UNAUTHORIZED=0"
          } >> "$GITHUB_ENV"

      - name: Run SDK E2E
        run: pnpm test:e2e:pve
```

What each Docker option does — see the
[run-flag reference](#run-flag-reference) below.

---

## Matrix across all four products

Most SDK suites target every Proxmox product. Run them in parallel:

```yaml
jobs:
  e2e:
    runs-on: ubuntu-latest

    strategy:
      fail-fast: false
      matrix:
        include:
          - product: pve
            image:   pve-test
            port:    8006
            extjs:   false           # PVE uses /api2/json
          - product: pbs
            image:   pbs-test
            port:    8007
            extjs:   false
          - product: pmg
            image:   pmg-test
            port:    8006
            extjs:   false
          - product: pdm
            image:   pdm-test
            port:    8443
            extjs:   true            # PDM uses /api2/extjs

    services:
      proxmox:
        image: ghcr.io/client-api/proxmox-docker/${{ matrix.image }}:9.2
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

      - name: Wait for container
        run: |
          for i in {1..60}; do
            status=$(docker inspect -f '{{.State.Health.Status}}' \
              "${{ job.services.proxmox.id }}" 2>/dev/null || echo "unknown")
            [ "$status" = "healthy" ] && exit 0
            sleep 2
          done
          docker logs "${{ job.services.proxmox.id }}"
          exit 1

      - name: Load credentials
        run: |
          docker exec "${{ job.services.proxmox.id }}" \
            cat /run/credentials.json > creds.json
          {
            echo "PROXMOX_URL=https://localhost:${{ matrix.port }}"
            jq -r '
              to_entries[]
              | "PROXMOX_" + (.key | ascii_upcase) + "=" + (.value | tostring)
            ' creds.json
            echo "NODE_TLS_REJECT_UNAUTHORIZED=0"
          } >> "$GITHUB_ENV"

      - name: Run ${{ matrix.product }} suite
        run: pnpm test:e2e:${{ matrix.product }}
```

The `extjs` flag is exposed so test code can switch the base path
between `/api2/json` (PVE/PBS/PMG) and `/api2/extjs` (PDM) if the SDK
client doesn't infer it.

Note that PMG defaults to port 8006 — the same as PVE. In single-job
matrices that's fine, but if you ever co-host PVE + PMG in the same
job you'll need to remap one of them with `-p 8016:8006`.

---

## Enabling KVM (real VM lifecycle)

The PVE image ships a 1 MiB SeaBIOS-bootable VM at vmid `100`
(`tiny-test`). If the runner has KVM available, the full
`qm start` → `qm shutdown` → `qm stop` cycle works.

`ubuntu-latest` runners have had KVM since GitHub's April 2024
rollout, but `/dev/kvm` defaults to mode `0660` owned by `root:kvm`
and the runner user isn't in that group. Add a small udev step
before the service container starts (this is the
[GitHub-blog-documented pattern](https://github.blog/changelog/2024-04-02-github-actions-hardware-accelerated-android-virtualization-now-available/)):

```yaml
jobs:
  e2e:
    runs-on: ubuntu-latest

    steps:
      - name: Enable KVM device permissions
        run: |
          echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
            | sudo tee /etc/udev/rules.d/99-kvm4all.rules
          sudo udevadm control --reload-rules
          sudo udevadm trigger --name-match=kvm

      - name: Start PVE container with KVM
        run: |
          docker run -d --rm \
            --name pve \
            --privileged \
            --device /dev/fuse \
            --device /dev/kvm \
            --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
            -p 8006:8006 \
            ghcr.io/client-api/proxmox-docker/pve-test:9.2
          for i in {1..60}; do
            [ "$(docker inspect -f '{{.State.Health.Status}}' pve)" = "healthy" ] && break
            sleep 2
          done

      - name: Drive the fixture VM
        run: |
          docker exec pve qm start 100
          sleep 3
          docker exec pve qm status 100 | grep -q running
          docker exec pve qm shutdown 100        # ACPI handler exits cleanly
          docker exec pve qm status 100 | grep -q stopped
```

If you want the lifecycle test to gracefully skip when KVM isn't
present (self-hosted runners, larger-runner SKUs without nested virt,
etc.), gate it on a probe step:

```yaml
- name: Detect /dev/kvm
  id: kvm
  run: |
    if [ -r /dev/kvm ]; then
      echo "available=true" >> "$GITHUB_OUTPUT"
    else
      echo "available=false" >> "$GITHUB_OUTPUT"
    fi

- name: VM lifecycle (only with KVM)
  if: steps.kvm.outputs.available == 'true'
  run: |
    docker exec pve qm start 100
    # …
```

You can also disable the fixture entirely:

```yaml
options: >-
  --env PVE_SEED_FIXTURE_VM=0
```

…in which case `qm list` returns an empty table and the SDK can fall
back to its own VM-create tests.

---

## Enabling LXC (real container lifecycle)

The PVE image also ships an Alpine 3.21 container at vmid `200`
(`tiny-ct`). PVE 9's LXC stack requires the **cgroup v2 unified
hierarchy** on the host kernel. GitHub-hosted `ubuntu-22.04` and
later use cgroup v2 by default, so this works out of the box on
`ubuntu-latest`.

```yaml
- name: Detect cgroup v2
  id: cgroupv2
  run: |
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
      echo "available=true" >> "$GITHUB_OUTPUT"
    else
      echo "available=false" >> "$GITHUB_OUTPUT"
    fi

- name: CT lifecycle (only with cgroupv2)
  if: steps.cgroupv2.outputs.available == 'true'
  run: |
    docker exec pve pct start 200
    sleep 3
    docker exec pve pct status 200 | grep -q running
    docker exec pve pct exec 200 -- sh -c 'echo "alpine $(cat /etc/alpine-release)"'
    docker exec pve pct stop 200
```

The fixture container has `features=nesting=1` and runs with
`lxc.apparmor.profile=unconfined` so it boots inside the privileged
Docker — see [`design.md`](./design.md) for the layered reasoning.

Disable with:

```yaml
options: >-
  --env PVE_SEED_FIXTURE_CT=0
```

---

## Reading the credentials JSON

Every image writes a credentials JSON at `/run/credentials.json`
inside the container on every boot. The shape is product-agnostic:

```json
{
  "host": "pve-test",
  "port": "8006",
  "url": "https://pve-test:8006",
  "user": "root@pam",
  "password": "proxmox123",
  "realm": "pam",
  "token_id": "PVEAPIToken=root@pam!test",
  "token_value": "<regenerated each boot>",
  "token_separator": "=",
  "token_header_value": "PVEAPIToken=root@pam!test=<regenerated each boot>"
}
```

`token_header_value` is the exact string to send as `Authorization:`.
**Always read this — never assemble the header from `token_id` +
`token_value` by hand**: the Perl-family products (PVE, PMG) join
with `=`, the Rust-family products (PBS, PDM) join with `:`. Using
the baked value avoids that branch.

Two ways to consume it:

```yaml
# Option A — lift every field as PROXMOX_<KEY>
- name: Export credentials
  run: |
    docker exec pve cat /run/credentials.json > creds.json
    jq -r '
      to_entries[]
      | "PROXMOX_" + (.key | ascii_upcase) + "=" + (.value | tostring)
    ' creds.json >> "$GITHUB_ENV"

# Option B — pipe into the SDK directly
- name: Test
  run: |
    PROXMOX_CREDS_JSON=$(docker exec pve cat /run/credentials.json) \
      pnpm test:e2e
```

PMG always writes `token_value: "(unsupported-by-pmg)"` because PMG
9.x has no token API. Use ticket auth for that suite.

---

## TLS, self-signed certificates

Every image generates a self-signed cert on first boot. Three options:

**A. Skip verification (easiest):**

```bash
NODE_TLS_REJECT_UNAUTHORIZED=0 pnpm test:e2e
```

```python
client = PveClient(url, verify=False)
```

```go
&http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
```

**B. Pull the cert out and trust it (most realistic):**

```yaml
- name: Trust the PVE cert
  run: |
    docker exec pve cat /etc/pve/local/pve-ssl.pem > pve.pem
    sudo cp pve.pem /usr/local/share/ca-certificates/pve.crt
    sudo update-ca-certificates
```

**C. Mount your own cert in (advanced):**

```yaml
options: >-
  -v ${{ github.workspace }}/my-cert.pem:/etc/pve/local/pve-ssl.pem:ro
  -v ${{ github.workspace }}/my-key.pem:/etc/pve/local/pve-ssl.key:ro
```

---

## Tracking the dev channel

To catch upstream regressions before they land in stable, run a
parallel matrix dimension against the `dev` tag (built from the
upstream `*-test` apt component, rebuilt every nightly):

```yaml
strategy:
  fail-fast: false
  matrix:
    channel: [stable, dev]
    include:
      - channel: stable
        tag: "9.2"
      - channel: dev
        tag: "dev"
        continue-on-error: true   # don't gate merges on the dev probe

services:
  pve:
    image: ghcr.io/client-api/proxmox-docker/pve-test:${{ matrix.tag }}
    # …
```

The `continue-on-error: true` keeps the matrix from blocking merges
when the dev channel breaks — you still see the failure, you just
don't get woken up at 03:00 over upstream churn.

---

## Running with `docker run` instead of a service container

Service containers are the cleanest pattern but have two limits worth
knowing:

1. **They start before `actions/checkout` runs**, so you can't mount
   in files from your repository as cert overrides or seed scripts.
2. **`options:` is a single line** — the syntax doesn't let you set
   environment variables conditionally per step.

For both, drop the `services:` block and use `docker run` in a step:

```yaml
jobs:
  e2e:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Enable KVM device permissions
        run: |
          echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
            | sudo tee /etc/udev/rules.d/99-kvm4all.rules
          sudo udevadm control --reload-rules
          sudo udevadm trigger --name-match=kvm

      - name: Start PVE
        run: |
          docker run -d --rm \
            --name pve \
            --privileged \
            --device /dev/fuse \
            --device /dev/kvm \
            --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
            -p 8006:8006 \
            -v "${{ github.workspace }}/test-fixtures:/seed:ro" \
            -e PVE_ROOT_PASSWORD="${{ secrets.PVE_PASSWORD }}" \
            ghcr.io/client-api/proxmox-docker/pve-test:9.2

      - name: Wait
        run: |
          for i in {1..60}; do
            [ "$(docker inspect -f '{{.State.Health.Status}}' pve)" = "healthy" ] \
              && exit 0
            sleep 2
          done
          docker logs pve
          exit 1

      - name: Run tests
        run: pnpm test:e2e

      - name: Container logs on failure
        if: failure()
        run: docker logs pve

      - name: Stop
        if: always()
        run: docker stop pve
```

---

## Run-flag reference

Why each flag is there, and what happens without it.

| Flag                          | Required? | Why                                                                                                    |
|-------------------------------|-----------|--------------------------------------------------------------------------------------------------------|
| `--privileged`                | yes       | pmxcfs is FUSE; systemd-PID-1 in PVE wants cgroups; PBS expects to mount tmpfs in `/run/proxmox-backup` |
| `--device /dev/fuse`          | yes (PVE/PMG) | pmxcfs needs the device node even with `--privileged`                                              |
| `--device /dev/kvm`           | optional  | enables `qm start` lifecycle in PVE                                                                    |
| `--tmpfs /tmp`                | yes (PVE) | systemd-PID-1 expects writable `/tmp`                                                                  |
| `--tmpfs /run`                | yes (PVE) | systemd unit dependencies                                                                              |
| `--tmpfs /run/lock`           | yes (PVE) | same                                                                                                   |
| `--health-cmd "/usr/local/sbin/healthcheck.sh"` | yes | the in-image healthcheck checks both API + credentials JSON                                            |
| `--health-start-period 60s`   | PVE       | systemd boot + pmxcfs + credential seed takes 15–25 s typically                                        |
| `-p <port>:<port>`            | yes       | exposes the API to other steps                                                                         |
| `--env PVE_ROOT_PASSWORD=…`   | optional  | override the baked-in `proxmox123`                                                                     |
| `--env PVE_SEED_FIXTURE_VM=0` | optional  | skip seeding VM 100 (tiny-test)                                                                        |
| `--env PVE_SEED_FIXTURE_CT=0` | optional  | skip seeding CT 200 (tiny-ct)                                                                          |

Cold-start budget on `ubuntu-latest`:

| Image      | Time to healthy |
|------------|-----------------|
| pve-test   | ~15-25 s        |
| pbs-test   | ~6-12 s         |
| pmg-test   | ~8-14 s         |
| pdm-test   | ~4-8 s          |

---

## Troubleshooting

**Container reports unhealthy after 60 s.** Capture logs immediately:

```yaml
- name: Container logs on failure
  if: failure()
  run: docker logs "${{ job.services.pve.id }}" || docker logs pve
```

Common causes: forgotten `--tmpfs` flags (PVE only), forgotten
`--device /dev/fuse` (PVE/PMG), or a `9.x` tag that drifted further
than the test expected.

**`qm start 100` returns "VM 100 doesn't exist".** The fixture VM
seeding was disabled or failed. Check container logs for the line
starting with `[pve] writing VM 100 …` — if it's missing, look for
the warning preceding it. Re-run with `--env PVE_SEED_FIXTURE_VM=1`
explicit if you've overridden it elsewhere.

**`qm start 100` fails with "could not connect to KVM".** `/dev/kvm`
not passed through. Verify the udev rule landed:

```yaml
- run: ls -la /dev/kvm
```

Should show mode `0666` after the udev step.

**`pct start 200` fails with `Failed to run mount hooks`.** lxcfs
isn't running inside the container — usually means the image is older
than `0fe0b34`. Update to a newer tag.

**`pct start 200` fails with `cpuset.cpus = ` empty.** Host kernel is
cgroup v1. PVE 9 requires cgroup v2. On a GitHub-hosted runner this
shouldn't happen; on a self-hosted runner check
`stat -fc '%T' /sys/fs/cgroup` returns `cgroup2fs`.

**Tests pass against PVE but fail against PBS/PDM with `401`.** You
built the token header by hand with `=` instead of reading
`token_header_value` from the credentials JSON. The Rust-family
products use `:` — see [credentials JSON](#reading-the-credentials-json).

Full inventory of known limitations:
[`docs/troubleshooting.md`](./troubleshooting.md).
