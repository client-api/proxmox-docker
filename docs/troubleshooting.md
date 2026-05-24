# Troubleshooting

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
    image: ghcr.io/client-api/proxmox-docker/pve-test:latest
    options: --privileged --device /dev/fuse
```

If you really need to avoid `--privileged`, the minimum is:

```
--cap-add SYS_ADMIN \
--device /dev/fuse \
--security-opt apparmor:unconfined
```

On Docker Desktop (macOS/Windows) the FUSE device sometimes isn't exposed
to the VM. Use the `--privileged` flag and verify with
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

## I need an SDK feature that needs real VM operations

You can't test that against these images. Options:

1. Mock the VM endpoints in your test fixtures.
2. Run the test against a real Proxmox cluster (out of scope for this
   repo).
3. Skip-tag the tests and exclude them from CI.

The images are for API-surface testing — request shape, response
parsing, auth flow, error envelopes, pagination. Workload operations
deliberately fail.

## PMG returns `(unsupported-by-pmg)` for token_value

PMG 9.x does not expose `/access/users/{userid}/token` endpoints —
its `/access` subtree is `ticket`, `auth-realm`, `oidc`, `password`,
`users`, `vncticket`. API tokens are a Proxmox-VE/PBS/PDM feature.

If your SDK has a PMG token-auth code path, it's currently untestable
against a real PMG instance — exercise it against PVE or PBS instead,
or skip-tag the PMG E2E case until upstream adds the endpoint.
