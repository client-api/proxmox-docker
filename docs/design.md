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

- Run a multi-node cluster. Each container is single-node.
- Production hardening. The credentials are public, the certs are
  self-signed, and the API is reachable on all interfaces.
- Live migration, real cluster operations, real backups against
  long-lived datastores, mail filtering against a real MTA.
- Real-OS guests. The fixture VM is a 256-byte boot sector and the
  fixture CT is an Alpine minirootfs — enough for the lifecycle
  endpoints to be testable end-to-end, not enough for cloud-init,
  guest agents, or workload simulation.

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

## Systemd in PVE; bash entrypoints elsewhere

The PVE image runs systemd as PID 1 (`/lib/systemd/systemd`). PBS, PMG,
and PDM use the older minimal-bash entrypoint pattern.

The split exists because **`qm start` reaches systemd1 over dbus to
place the QEMU process in a transient cgroup scope** (see
`PVE::Systemd::enter_systemd_scope`). Without an actual systemd
running, that call returns `Spawn.ChildExited` and the VM never
launches. PBS/PMG/PDM don't have an equivalent path — their daemons
are happy to run as plain forked children.

Why not standardise on systemd everywhere:

- PBS and PDM only need two Rust daemons launched; bringing up the
  full sysinit/multi-user target chain just for that costs 5–10 s of
  boot time and adds masking work to keep `systemd-networkd-wait-
  online` etc. quiet.
- PMG's daemons are Perl scripts that run cleanly in the foreground
  via `pmgdaemon start`; same calculation as PBS/PDM.
- The minimal-bash entrypoint is easier to read and to reason about
  when something breaks at boot.

The PVE entrypoint script (`pve/entrypoint.sh`) survives — but as the
ExecStart of `proxmox-docker-boot.service`, not as PID 1. It runs once
after `pve-cluster.service` is up, seeds credentials and the fixture
VM, and exits. Hostname setup happens in a separate `proxmox-docker-
hostname.service` ordered `Before=pve-cluster.service` so pmxcfs has a
valid FQDN to bind to.

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

## Fixture VMs and containers

The PVE image ships two pre-seeded workloads so SDK tests can exercise
the lifecycle endpoints (`start`, `stop`, `shutdown`, `exec`) against
real running guests, not just configuration CRUD.

| vmid | Kind | Source                                                    | Host needs        |
|------|------|-----------------------------------------------------------|-------------------|
| 100  | VM   | [256-byte-vm](https://github.com/client-api/256-byte-vm) v1.0.0 (1 MiB SeaBIOS-bootable qcow2) | `/dev/kvm`        |
| 200  | CT   | Alpine 3.21 minirootfs                                    | cgroup v2 host    |

Both are downloaded at image-build time from upstream releases and
SHA-256-verified against pinned hashes. The boot script (`pve/
entrypoint.sh`) seeds the PVE config files for each on every boot —
re-using existing disk images if they already exist, so restart
cycles preserve guest state.

### Why systemd in PVE, why not in PBS/PMG/PDM

The PVE image runs systemd as PID 1 because `qm start` and `pct start`
both reach `systemd1` over dbus (`PVE::Systemd::enter_systemd_scope`)
to place the QEMU / lxc-start process in a transient cgroup scope.
Without a real systemd, that dbus call fails with `Spawn.ChildExited`
and the workload never launches.

PBS, PMG, and PDM have no equivalent path — their daemons are
content to run as plain forked children. Adding systemd to those
images would cost 5-10 s of boot time and force us to mask the
container-hostile units (`systemd-networkd-wait-online`, `chrony`,
`watchdog-mux`, etc.) without buying anything testable.

### Why lxcfs needs an override

`/usr/share/lxc/config/common.conf.d/00-lxcfs.conf` wires lxcfs into
the LXC config chain as `lxc.hook.mount = /usr/share/lxcfs/lxc.mount.
hook`. Every `pct start` runs that hook, which expects lxcfs's FUSE
pseudo-fs mounted at `/var/lib/lxcfs`.

But upstream's `lxcfs.service` has `ConditionVirtualization=!container`
— a sensible default on a real PVE host (you don't run a virtualising
pseudo-fs inside a container that has nothing to virtualise), but it
means our test image never starts lxcfs unless we override the
condition. The drop-in at `/etc/systemd/system/lxcfs.service.d/
override.conf` clears it.

### Why CT 200 gets AppArmor disabled

PVE auto-generates an AppArmor profile per container and tries to
load it via `apparmor_parser` at every start. Inside a privileged
Docker container the kernel rejects profile-load syscalls from a
non-host namespace — there's no Docker-in-Docker AppArmor namespace
path.

We append `lxc.apparmor.profile: unconfined` to the seed CT config
so LXC skips the profile load entirely. The remaining isolation
(cgroups, seccomp, capabilities) is unchanged; the outer Docker
`--privileged` is the actual security boundary anyway.
