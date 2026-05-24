# proxmox-docker

Test-only Docker images for the four Proxmox products — built so SDK
clients generated from the Proxmox OpenAPI specs can be E2E-tested
against a real Proxmox API surface inside GitHub Actions.

> [!WARNING]
> **These images are for E2E testing only. Do not run them in production.**
>
> They ship with **public, hard-coded credentials** (`root@pam` / `proxmox123`),
> a **self-signed TLS cert**, **no firewall**, and the daemons run inside a
> `--privileged` container. Workload paths (VM, LXC, real backups, mail
> filtering, clustering across nodes) are deliberately broken or absent.
>
> The goal is to give SDK test suites a real Proxmox HTTP API to talk to.
> If you need a real Proxmox install, use the upstream ISO at
> <https://www.proxmox.com/en/downloads>.

| Product | Image | API port | Default base path |
|---------|--------------------------------------------------|----------|-------------------|
| Proxmox VE                  | `ghcr.io/client-api/proxmox-docker/pve-test` | 8006 | `/api2/json` |
| Proxmox Backup Server       | `ghcr.io/client-api/proxmox-docker/pbs-test` | 8007 | `/api2/json` |
| Proxmox Mail Gateway        | `ghcr.io/client-api/proxmox-docker/pmg-test` | 8006 | `/api2/json` |
| Proxmox Datacenter Manager  | `ghcr.io/client-api/proxmox-docker/pdm-test` | 8443 | `/api2/extjs` |

## Status

These images run **real** Proxmox daemons (`pveproxy`, `pmxcfs`, `proxmox-backup-proxy`, …),
not mocks. The full HTTP API surface is reachable — authentication, ticket+CSRF flow,
API tokens, cluster endpoints, storage endpoints, all of it.

### Verified auth flows

| Image     | Installed version | Ticket auth | API-token auth          | Time to healthy |
|-----------|-------------------|-------------|-------------------------|-----------------|
| pve-test  | pve-manager 9.2.2 | ✅          | ✅ `…=<uuid>`           | ~12 s           |
| pbs-test  | proxmox-backup 4.2| ✅          | ✅ `…:<uuid>`           | ~9 s            |
| pmg-test  | pmg-api 9.x       | ✅          | ❌ (PMG has no token API) | ~10 s          |
| pdm-test  | proxmox-datacenter-manager 1.0.4 | ✅ | ✅ `…:<uuid>`     | ~6 s            |

The Rust-family products (PBS, PDM) use a **colon** between token id and value
(`PBSAPIToken=root@pam!test:<uuid>`) — the Perl-family ones (PVE, PMG) use an
equals sign (`PVEAPIToken=root@pam!test=<uuid>`). The credentials JSON we write
into each container records the correct separator alongside the value, so SDK
test code can read `token_header_value` directly without branching on product.

### What does NOT work in these images

- Real backups against a backing datastore (PBS spins up but datastore
  I/O is limited)
- Mail filtering (PMG; no real Postfix backend)
- Cross-node cluster operations (single-node only)
- API-token auth against PMG (the API surface itself doesn't expose
  tokens)

### Working KVM and LXC lifecycle in PVE

The PVE image runs systemd as PID 1 and ships two fixtures so SDK
tests can drive real start/stop/exec lifecycles, not just config-
level CRUD:

| Fixture | vmid | Source | Host requirement |
|---------|------|--------|------------------|
| **VM** `tiny-test` (`qm`) | 100 | [256-byte-vm](https://github.com/client-api/256-byte-vm) v1.0.0 — 1 MiB SeaBIOS-bootable | `--device /dev/kvm` |
| **CT** `tiny-ct` (`pct`) | 200 | Alpine 3.21 minirootfs                                                   | cgroup v2 on the host |

```bash
# VMs — needs /dev/kvm
docker exec pve-test qm start 100         # boots in <1 s
docker exec pve-test qm shutdown 100      # ACPI handler exits cleanly
docker exec pve-test qm stop 100          # hard kill

# Containers — needs cgroupv2 host
docker exec pve-test pct start 200
docker exec pve-test pct exec 200 -- sh -c 'echo "alpine $(cat /etc/alpine-release)"'
docker exec pve-test pct stop 200
```

Without `/dev/kvm` or cgroupv2, the matching config endpoints still
work (`qm list`, `pct config`, snapshot/clone config). Only the
`start` operation hard-fails. WSL2 hosts default to cgroupv1 (LXC
won't start); ubuntu-22.04+ GitHub-hosted runners default to cgroupv2
(everything works).

Disable either fixture at runtime:

```bash
docker run … -e PVE_SEED_FIXTURE_VM=0 -e PVE_SEED_FIXTURE_CT=0 …
```

This is intentional. The images exist to let SDK client tests exercise the API
layer — request shape, response parsing, auth, pagination, error envelopes —
not to actually run workloads.

## Quick start (local)

Each product directory ships a self-contained `docker-compose.yml` —
the easiest way to spin up one product locally:

```bash
docker compose -f pve/docker-compose.yml up -d   # PVE on :8006
docker compose -f pbs/docker-compose.yml up -d   # PBS on :8007
docker compose -f pmg/docker-compose.yml up -d   # PMG on :8016 (remapped from :8006 to avoid PVE clash)
docker compose -f pdm/docker-compose.yml up -d   # PDM on :8443
```

Override the image tag without editing the file:

```bash
PVE_IMAGE=ghcr.io/client-api/proxmox-docker/pve-test:9.2.2 \
    docker compose -f pve/docker-compose.yml up -d
```

The plain `docker run` equivalent:

```bash
docker run -d --rm \
    --name pve-test \
    --privileged \
    --device /dev/fuse \
    --device /dev/kvm \
    --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
    -p 8006:8006 \
    ghcr.io/client-api/proxmox-docker/pve-test:latest

# Wait for readiness
until curl -ks https://localhost:8006/api2/json/version | grep -q version; do sleep 1; done

# Use baked-in credentials
curl -k -d 'username=root@pam&password=proxmox123' \
    https://localhost:8006/api2/json/access/ticket
```

`--privileged` is required for two reasons:
- Proxmox's cluster filesystem (`pmxcfs`) is a FUSE mount.
- The PVE image runs systemd as PID 1, which needs cgroup access.

`--device /dev/kvm` enables real VM lifecycle (see "Bonus" below).
Omit it if the host lacks KVM — the rest of the API still works.
The three `--tmpfs` mounts are systemd's normal expectations for
`/tmp`, `/run`, `/run/lock` inside a container.

## Baked-in credentials

All four images ship with the same fixed default credentials. This is intentional
— these images are for testing, not for production. **Do not expose them on a
public network.**

| Field | Value |
|-------|-------|
| Root realm user | `root@pam` |
| Root password   | `proxmox123` |
| API token name  | `root@pam!test` (PMG: no token API) |
| API token value | regenerated on every container boot, written to `/run/credentials.json` inside the container |

The credentials JSON looks like this (PBS example):

```json
{
  "host": "pbs-test",
  "port": "8007",
  "url": "https://pbs-test:8007",
  "user": "root@pam",
  "password": "proxmox123",
  "realm": "pam",
  "token_id": "PBSAPIToken=root@pam!test",
  "token_value": "c8d10ad4-d4a9-43d5-9df1-5e51cbccc637",
  "token_separator": ":",
  "token_header_value": "PBSAPIToken=root@pam!test:c8d10ad4-d4a9-43d5-9df1-5e51cbccc637"
}
```

`token_header_value` is the exact string to send as `Authorization:` —
test code can read it directly, no per-product branching needed.

To read the token from outside the container:

```bash
docker exec pve-test cat /run/credentials.json
```

Override the password by setting `PVE_ROOT_PASSWORD`, `PBS_ROOT_PASSWORD`,
`PMG_ROOT_PASSWORD`, or `PDM_ROOT_PASSWORD` at container start.

## GitHub Actions

Drop-in service-container snippet for SDK E2E tests:

```yaml
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
      - name: Run SDK E2E
        env:
          PVE_HOST: https://localhost:8006
          PVE_USER: root@pam
          PVE_PASSWORD: proxmox123
        run: pnpm test:e2e
```

See [`docs/github-actions.md`](./docs/github-actions.md) for the full
integration guide including a matrix workflow that exercises all four
products in parallel.

## Repository layout

```
proxmox-docker/
├── pve/                Dockerfile, entrypoint, systemd units, docker-compose.yml for Proxmox VE
├── pbs/                Dockerfile, entrypoint, docker-compose.yml for Proxmox Backup Server
├── pmg/                Dockerfile, entrypoint, docker-compose.yml for Proxmox Mail Gateway
├── pdm/                Dockerfile, entrypoint, docker-compose.yml for Proxmox Datacenter Manager
├── scripts/            Shared helper scripts (repo setup, credential seeding)
├── docs/               Design notes, GHA integration guide, troubleshooting
└── .github/workflows/  Build/publish + smoke-test pipelines
```

## Versioning

Tag policy, deprecation rules, and recipes for picking a tag in your
CI live in [`VERSIONING.md`](./VERSIONING.md). The short version:

- `latest` — most recent stable nightly. Floats freely.
- `<major>.<minor>` (e.g. `9.2`) — floats forward within a series.
  **Recommended for production CI.**
- `<version>` (e.g. `9.2.2`) — immutable, exact upstream package.
- `dev` — built from the upstream `*-test` apt component for early warning.

## License

Apache 2.0 — see [LICENSE](./LICENSE).
