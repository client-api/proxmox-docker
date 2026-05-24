# Versioning policy

> [!WARNING]
> These images are for **E2E testing only** — not production.
> Public hard-coded credentials, self-signed TLS, no firewall,
> `--privileged` runtime, workload paths intentionally non-functional.
> See [README.md](./README.md) for the full warning.

This document describes what each image tag promises, when it moves,
and how to pick the right one for your use case. The contract lives
here so consumers can pin against something stable without reading the
workflow YAML.

## TL;DR

| Your situation                                | Use this tag        |
|-----------------------------------------------|---------------------|
| Production CI, want reproducible builds       | `<version>` (e.g. `9.2.2`) |
| Production CI, want the current stable        | `latest`            |
| Want to surface upstream breakage early       | `dev`               |
| Auditing an exact past build                  | `stable-YYYYMMDD` or `dev-YYYYMMDD` |
| Pinning to the latest patch of a minor series | `<major>.<minor>` (e.g. `9.2`) |

Default recommendation for downstream SDK E2E pipelines: **`<major>.<minor>`**
(e.g. `pve-test:9.2`). It floats forward on patch updates from the
no-subscription repo but never crosses a minor boundary without a
deliberate choice from you.

## Tag catalogue

Every image is published at `ghcr.io/client-api/proxmox-docker/<product>-test`
with the following tags:

### Stable channel (apt component: `<product>-no-subscription`)

| Tag                | Mutability | What it points to                                  |
|--------------------|------------|----------------------------------------------------|
| `latest`           | Moving     | The most recent successful nightly stable build    |
| `<version>`        | Immutable  | Stamped from `dpkg-query` after the install; e.g. `9.2.2` for PVE, `4.2.0` for PBS |
| `<major>.<minor>`  | Moving     | Latest patch within a minor series; e.g. `9.2` always resolves to the newest `9.2.x` |
| `stable-YYYYMMDD`  | Immutable  | The exact build produced by the nightly that ran on `YYYYMMDD` UTC |
| `sha-<short>`      | Immutable  | Every push-driven build (CI traceability)          |

### Dev channel (apt component: `<product>-test`)

| Tag              | Mutability | What it points to                                  |
|------------------|------------|----------------------------------------------------|
| `dev`            | Moving     | The most recent successful nightly dev build       |
| `dev-<version>`  | Immutable  | Stamped from `dpkg-query` against the test repo    |
| `dev-YYYYMMDD`   | Immutable  | The exact dev build from `YYYYMMDD` UTC nightly    |

The dev channel exists to surface upstream breakage before it lands in
stable. Treat dev tags as preview-only — they may regress.

## Per-product version landscape

Proxmox's four products do NOT move in lockstep. Each has its own
upstream cadence:

| Product | Currently shipping | Upstream cadence                                  |
|---------|--------------------|---------------------------------------------------|
| PVE     | 9.x (Debian 13)    | Major every 2–3 years, minor every few months     |
| PBS     | 4.x                | Major roughly aligned with PVE majors             |
| PMG     | 9.x                | Major roughly aligned with PVE majors             |
| PDM     | 1.0.x              | Fast iteration — minor every few weeks            |

What this means for tag selection:

- `pve-test:9` is fine — PVE has been on `9.x` since 2025-08 and PVE 10
  is at least 18 months away.
- `pdm-test:1` is **too coarse** today. PDM is iterating fast; pin at
  least to `pdm-test:1.0` and probably to `1.0.4` until you're ready to
  validate a new minor.
- Cross-product matrix jobs (e.g. "run my SDK against all 4") should
  pick the tag granularity per product, not share a single literal
  across the matrix.

## Stable vs dev — what's actually different

Both channels build from the same Dockerfile. The only difference is
the apt repo component the image pulls from at build time:

- **Stable** = `<product>-no-subscription`. The repo Proxmox publishes
  for users who run unpaid stable installs. Roughly equivalent to "GA
  release with critical fixes backported."
- **Dev** = `<product>-test`. The upstream testing repo, where Proxmox
  pushes pre-release builds and feature work. May contain regressions.

There is **no enterprise channel** — these images are explicitly for
test/CI use and do not require a subscription.

If your SDK test suite goes red against `dev` but green against `latest`,
that's the early-warning signal you wanted: file a bug upstream, or pin
your CI to a specific stable version until the dev channel settles.

## Deprecation policy

### When `latest` moves

`latest` advances every successful nightly stable build (`17:03 UTC`
schedule, see `.github/workflows/nightly.yml`). It will move:

- Within minutes of an upstream `no-subscription` package update
- Without prior notice in the changelog
- Even if the image surface changes (port, env vars, paths)

If that's too aggressive for your CI: pin a `<major>.<minor>` or
`<version>` tag.

### When old `<version>` tags are removed

Immutable tags (`<version>`, `stable-YYYYMMDD`, `dev-<version>`,
`dev-YYYYMMDD`, `sha-<short>`) are **never deleted**. They form an
audit trail. Storage cost on GHCR is negligible compared to the
debugging cost of "the tag we pinned three months ago is gone."

### When `<major>.<minor>` tags stop advancing

A floating `<major>.<minor>` tag stops moving when Proxmox stops
shipping packages for that line in `no-subscription`. The tag itself
stays pullable forever, but it freezes to whatever the last build was.

When this happens, the `CHANGELOG.md` `Deprecated` section gets a note
6 months before the freeze, and a `Removed` note when no more updates
land.

### Image breaking changes (entrypoint, env vars, paths)

Any change that breaks documented behavior (port number, env var name,
credentials JSON shape, healthcheck contract) requires:

1. A major-version bump of THIS repo (separate from upstream Proxmox
   versions — see "Repo version vs Proxmox version" below).
2. An entry in `CHANGELOG.md` under `## [Unreleased]` → `### Changed`
   or `### Removed`.
3. At least one stable nightly running both old and new behavior so
   downstream CI can pin during the migration.

## Repo version vs Proxmox version

This repo (`proxmox-docker`) has its own semver, independent of
upstream Proxmox versions. The repo version describes the **image
contract** (entrypoint behavior, env vars, credentials JSON shape,
healthcheck signature), not the Proxmox payload inside.

Repo version is reflected only in git tags (e.g. `v1.4.0`) and the
GitHub Releases page. The published image tags do NOT carry the repo
version — they carry the upstream Proxmox package version. This is
deliberate: if you `docker pull pve-test:9.2.2`, you should know
exactly what's inside without checking which `proxmox-docker` release
built it.

| Change type                                | Repo version bump |
|--------------------------------------------|-------------------|
| Upstream Proxmox patch update              | None              |
| New supporting feature in entrypoint       | Minor (`v1.4` → `v1.5`) |
| Breaking change to image contract          | Major (`v1.x` → `v2.0`) |
| Bug fix in entrypoint or healthcheck       | Patch (`v1.4.0` → `v1.4.1`) |

## Cadence

| Event                                      | Frequency / Trigger                         |
|--------------------------------------------|----------------------------------------------|
| Push-driven build (stable, all products)   | On every push to `main`                      |
| Nightly stable + dev rebuild               | Daily, 03:17 UTC                             |
| Repo release (semver tag)                  | As needed, when contract changes             |
| Deprecation notice                         | 6 months before a `<major>.<minor>` freezes  |

## Pinning examples

Picking a tag is a tradeoff between **freshness** and **stability**.
Some concrete recipes:

**SDK E2E in a hobby project, OK with the occasional break:**
```yaml
services:
  pve:
    image: ghcr.io/client-api/proxmox-docker/pve-test:latest
```

**SDK E2E in a production CI, want patches without minor jumps:**
```yaml
services:
  pve:
    image: ghcr.io/client-api/proxmox-docker/pve-test:9.2
```

**Reproducible benchmark or release-gate run:**
```yaml
services:
  pve:
    image: ghcr.io/client-api/proxmox-docker/pve-test:9.2.2
    # …or use the immutable sha-XXXX tag for byte-exact reproducibility
```

**Catch upstream regressions early (run in parallel with stable):**
```yaml
strategy:
  matrix:
    channel: [stable, dev]
services:
  pve:
    image: |-
      ${{ matrix.channel == 'stable'
          && 'ghcr.io/client-api/proxmox-docker/pve-test:latest'
          ||  'ghcr.io/client-api/proxmox-docker/pve-test:dev' }}
```

## Why not lockstep all four products to one tag?

A single "proxmox-docker:9" tag spanning PVE/PBS/PMG/PDM was considered
and rejected. The four products release independently — Proxmox itself
doesn't synchronise them. Forcing a unified tag would either:

- block PDM patch updates because PVE hasn't moved
- block PVE security updates because PDM is in flux

Each image is published independently with its own version. If you
need cross-product coordination, do it in your downstream workflow's
matrix definition.
