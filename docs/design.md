# Design notes

## Goals

1. Make every Proxmox HTTP API endpoint reachable from a CI runner.
2. Make the container boot in seconds, not minutes — fast enough that a
   service container doesn't dominate the GitHub Actions wall-clock time.
3. Bake credentials into the image so tests don't need a separate bootstrap
   step before they can authenticate.
4. Stay close enough to a real Proxmox install that the SDK's auth flow,
   error envelopes, and pagination behavior match production.

## Non-goals

- Run actual VMs, containers, or backups. The kernel inside an Actions
  runner doesn't have a usable KVM, and even if it did, the storage layer
  isn't pre-seeded with templates. Tests should mock or skip workload
  endpoints.
- Run a multi-node cluster. Each container is single-node.
- Production hardening. The credentials are public, the certs are
  self-signed, and the API is reachable on all interfaces.

## Per-product structure

Each product has its own directory at the repo root:

```
pve/   pbs/   pmg/   pdm/
```

Each contains exactly three files:

- `Dockerfile` — image build recipe
- `entrypoint.sh` — boot orchestration
- `healthcheck.sh` — invoked by `HEALTHCHECK CMD`

Shared logic lives in `scripts/`:

- `setup-proxmox-repo.sh` — adds the no-subscription apt repo + GPG key
- `common-entrypoint.sh` — hostname/IP wiring, credential JSON writer,
  graceful shutdown trap

The split is deliberate. Each product has subtly different daemon names,
config layouts, and bootstrap commands. Forcing them through a shared
entrypoint would create a Christmas-tree `case` statement that's harder
to read than four small scripts.

## Why no `proxmox-ve` meta-package?

The `proxmox-ve` package pulls in:

- the PVE kernel (`proxmox-default-kernel`, ~200 MB)
- `chrony` (NTP — needs a system clock service)
- `postfix` (mail — needs an MTA)
- `open-iscsi`, `lvm2`, `ifupdown2`, … (host-only utilities)

None of these make sense in a container. We install only the API surface
packages directly (`pve-manager`, `pve-cluster`, etc.) and apt-pin the
kernel out so it can't sneak back in via a recommends chain.

The same pattern applies to PBS (skip `proxmox-backup-server` meta in
favor of `proxmox-backup`), PMG (skip `proxmox-mailgateway`), and PDM
(skip `proxmox-datacenter-manager-meta`).

## Why no systemd?

systemd inside a container is possible but expensive: it wants `/sys/fs/cgroup`
mounted writable, dedicated cgroup namespaces, and either privileged mode or
careful capability hand-tuning. It also adds 10–20s to the cold start while
units settle.

We run each product's daemons directly from the entrypoint. Proxmox makes
this easy — every daemon binary either supports a `start` subcommand
(`pvedaemon start`) or runs in the foreground by default (PBS/PDM Rust
binaries).

The trade-off: no service restart on crash. For a test-only image that's
acceptable — if a daemon crashes mid-test, the test should fail loudly
rather than silently re-running against a restarted backend.

## Why FUSE (`pmxcfs`)?

PVE and PMG store their cluster config in a FUSE-mounted filesystem
(`/etc/pve` for PVE, `/etc/pmg` is conventional but PMG uses a SQLite DB
in `/var/lib/pmg` — no FUSE). The PVE daemons refuse to start without
`/etc/pve` mounted by `pmxcfs`.

`pmxcfs -l` runs in standalone (non-cluster) mode — it skips the corosync
dependency and just provides the FUSE mount. This is what we use.

FUSE inside a container needs `SYS_ADMIN` (mount syscall) and either
`/dev/fuse` exposed or `--privileged`. The README and the GHA docs both
state this requirement.

## Credentials: build-time fixed defaults

The decision was between:

1. Bake fixed credentials at build time (chosen).
2. Generate randoms at runtime, expose via stdout / env / shared volume.

We chose (1) because the test fixture should be **reproducible from the
image tag alone**. A test author looking at the image name should know
without ceremony what credentials to use. The image is for testing only —
publishing the credentials in the README is intentional.

The API *token value* is the one exception: we can't bake a token UUID
into the image because the `pveum` / `proxmox-backup-manager` /
`pmgsh` commands generate the value themselves and there's no API to
override it. So the token value is regenerated on every boot and written
to `/run/credentials.json` — tests `docker exec cat` that file.

Password auth works without any of that — username `root@pam`, password
`proxmox123`, hit `/access/ticket`, get a ticket cookie + CSRF token. The
generated SDK clients exercise this flow end-to-end.

## Why Trixie?

Proxmox VE 9 (current stable) is based on Debian 13 Trixie. PBS, PMG, and
PDM all have Trixie no-subscription repos. Using a single base image
across all four products keeps the apt-repo setup script trivial — same
GPG key, same suite, same component pattern.

If a future PVE version drops Trixie, this repo's CI will break loudly
(apt resolution failure) rather than silently building images against
EOL packages.
