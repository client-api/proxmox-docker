# Troubleshooting

For step-by-step CI integration recipes, see
[`github-actions.md`](./github-actions.md). This file is a flat catalogue
of things that have broken in practice + how each was diagnosed.

## Container exits immediately with "pmxcfs failed to mount /etc/pve"

`pmxcfs` is a FUSE filesystem. It needs:

- `SYS_ADMIN` capability
- Access to `/dev/fuse`
- An unmasked `/sys`

The simplest fix is to run the container with `--privileged`. For
GitHub Actions service containers:

```yaml
services:
  pve:
    image: ghcr.io/client-api/proxmox-docker/pve-test:9.2
    options: >-
      --privileged
      --device /dev/fuse
      --tmpfs /tmp
      --tmpfs /run
      --tmpfs /run/lock
```

The three `--tmpfs` mounts are for systemd-as-PID-1 inside the PVE
image; without them PVE's units fail to start and the container goes
unhealthy after the 60 s start period.

If you really need to avoid `--privileged`, the minimum is:

```
--cap-add SYS_ADMIN \
--device /dev/fuse \
--security-opt apparmor:unconfined
```

…but you also lose KVM, LXC, and the systemd cgroup hierarchy, so
none of the lifecycle endpoints will work.

On Docker Desktop (macOS/Windows) the FUSE device sometimes isn't
exposed to the VM. Use the `--privileged` flag and verify with
`docker exec <ct> ls /dev/fuse`.

## "Container reported unhealthy" in CI

Look at the container logs:

```bash
docker logs <container-name>
```

Common causes:

1. **Hostname not resolving** — Proxmox refuses to start if the local
   hostname doesn't resolve to a non-127.0.0.1 IP. The entrypoint sets up
   `/etc/hosts` automatically; if you're overriding the hostname via the
   `<PRODUCT>_HOSTNAME` env var, make sure it's also reachable.

2. **API token creation timed out** — usually a transient symptom of the
   API daemon not being fully ready when the entrypoint tries to seed the
   token. Re-run the workflow; if it persists, increase
   `--health-start-period`.

3. **Trying to run on arm64** — Proxmox does not ship arm64 packages.
   The images are linux/amd64 only.

## Self-signed cert errors in SDK tests

The container generates self-signed certs on first boot. Your SDK client
either needs to skip TLS verification or trust the cert.

For Node-based SDKs:

```bash
NODE_TLS_REJECT_UNAUTHORIZED=0 pnpm test:e2e
```

For Python (`requests`):

```python
client = PveClient("https://localhost:8006", verify=False)
```

For Go (`net/http`):

```go
tr := &http.Transport{
    TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
}
```

To use a real cert, mount your own into `/etc/pve/local/pve-ssl.pem`
(PVE) or the equivalent path for other products. The entrypoint won't
overwrite an existing cert.

## Token auth returns 401 even though /run/credentials.json has a value

The token id/value separator differs between Proxmox products:

| Family | Products  | Separator | Authorization header                    |
|--------|-----------|-----------|------------------------------------------|
| Perl   | PVE, PMG  | `=`       | `PVEAPIToken=root@pam!test=<uuid>`      |
| Rust   | PBS, PDM  | `:`       | `PBSAPIToken=root@pam!test:<uuid>`      |

To avoid getting this wrong by hand, read `token_header_value` from
`/run/credentials.json` — it already includes the correct separator for the
running container's product, so test code stays product-agnostic.

## API token value shows as `(unavailable)` in credentials.json

The image fell back to a placeholder because token creation returned no
value. Password auth still works. To debug:

```bash
docker exec <ct> pveum user token list root@pam
```

If the token list is empty, manually re-create:

```bash
docker exec <ct> pveum user token add root@pam test --privsep 0
```

This commonly happens when the entrypoint races the API: the daemon
accepted connections but hadn't finished initializing its auth store
yet. The healthcheck mitigates this for callers (they only see the
container as healthy after credentials are seeded).

## Why is the PVE image ~600 MB?

Most of it is Perl modules and the PVE management toolchain — they don't
compress well and they're already shared with PMG (which uses the same
underlying packages). The `proxmox-default-kernel` is pinned out, which
saves ~200 MB.

If you need a slimmer image, two paths:

1. Use the PBS or PDM image — they're considerably smaller (~250–350 MB)
   because they're Rust-only.
2. Strip docs and locale files in a custom layer:

```dockerfile
FROM ghcr.io/client-api/proxmox-docker/pve-test:latest
RUN rm -rf /usr/share/doc /usr/share/man /usr/share/locale
```

## `qm start 100` fails with "could not connect to KVM"

The `/dev/kvm` device wasn't passed through, OR the runner doesn't
have nested virtualization. Two cases:

**`/dev/kvm` exists but isn't readable by the test step.** Default on
`ubuntu-latest` (the device is owned `root:kvm 0660` and the runner
user isn't in `kvm`). Add the udev rule snippet from
[github-actions.md → Enabling KVM](./github-actions.md#enabling-kvm-real-vm-lifecycle).

**`/dev/kvm` is genuinely missing.** Self-hosted runner without nested
virt, or a larger-runner SKU that didn't include the `-kvm` variant.
Skip the lifecycle step:

```yaml
- name: Detect /dev/kvm
  id: kvm
  run: |
    if [ -r /dev/kvm ]; then
      echo "available=true" >> "$GITHUB_OUTPUT"
    else
      echo "available=false" >> "$GITHUB_OUTPUT"
    fi

- name: VM lifecycle
  if: steps.kvm.outputs.available == 'true'
  run: docker exec pve qm start 100
```

The rest of the API still works — only `qm start` hard-fails.

## `pct start 200` fails with "Failed to run mount hooks"

PVE's LXC stack pins `lxc.hook.mount = /usr/share/lxcfs/lxc.mount.hook`
via `/usr/share/lxc/config/common.conf.d/00-lxcfs.conf`. If the
`lxcfs` service isn't running inside the container, the hook fails
and the CT aborts.

Symptoms in the journal:

```
run_buffer: 569 Script exited with status 1
lxc_setup: 3845 Failed to run mount hooks
do_start: 1466 Failed to setup container "200"
```

Images built from commit `0fe0b34` and later ship a systemd drop-in
that overrides `ConditionVirtualization=!container` so `lxcfs` runs
inside the Docker container. Older tags don't have the fix — use a
tag from after 2026-05-24 (`pve-test:9.2.2-1` or `pve-test:latest`).

## `pct start 200` fails with "cpuset.cpus = " empty

Host kernel is on cgroup v1. PVE 9's LXC stack only supports cgroup
v2; on a v1 host it tries to auto-detect CPU pinning via
`/sys/fs/cgroup/cgroup.controllers`, finds nothing, and writes an
unparseable empty `lxc.cgroup.cpuset.cpus = ` line.

GitHub-hosted `ubuntu-22.04+` runners use cgroup v2 by default. If
you hit this:

- On a self-hosted runner: switch to cgroup v2 in the kernel command
  line (`systemd.unified_cgroup_hierarchy=1` on most distros,
  `cgroup_no_v1=all` on WSL2).
- On Docker Desktop / WSL2: add `kernelCommandLine = cgroup_no_v1=all`
  to `[wsl2]` in `~/.wslconfig` (Windows side), then `wsl --shutdown`.

The smoke workflow gates the CT lifecycle step on a cgroupv2 probe,
so a cgroupv1 runner skips the test instead of false-failing.

## `pct start 200` fails with "Failed to load generated AppArmor profile"

LXC tries to load a per-CT AppArmor profile via `apparmor_parser`,
but inside a privileged Docker container the kernel rejects
profile-load syscalls from a non-host namespace. Symptoms:

```
run_apparmor_parser: 954 Failed to run apparmor_parser
apparmor_prepare: 1126 Failed to load generated AppArmor profile
lxc_init: 1069 Failed to initialize LSM
```

Images built from commit `7962baa` and later append
`lxc.apparmor.profile: unconfined` to the seed CT config, which
sidesteps the load entirely. Older tags don't — update.

## I need an SDK feature that needs real VM operations

The PVE image ships a working KVM lifecycle out of the box if you
pass `--device /dev/kvm`. The fixture VM at vmid 100 is enough for:

- `qm start` / `qm stop` / `qm shutdown` / `qm reset`
- `qm snapshot create/delete/rollback`
- `qm clone` (template-mode optional)
- `qm migrate` dry-run (single-node, so no real migrate)

What still doesn't work:

- Live migration (single node)
- VM operations that need a real OS in the guest (cloud-init, qemu
  guest-agent, snapshot RAM)
- Workloads that need real disk I/O at scale

For those: mock the endpoints, run against a real cluster, or
skip-tag the tests.

## PMG returns `(unsupported-by-pmg)` for token_value

PMG 9.x does not expose `/access/users/{userid}/token` endpoints —
its `/access` subtree is `ticket`, `auth-realm`, `oidc`, `password`,
`users`, `vncticket`. API tokens are a Proxmox-VE/PBS/PDM feature.

If your SDK has a PMG token-auth code path, it's currently untestable
against a real PMG instance — exercise it against PVE or PBS instead,
or skip-tag the PMG E2E case until upstream adds the endpoint.
