# e2e-beta

A minimal status page. It serves one plain-text endpoint that answers, over the
network, a single question: **is this box alive, and which build is it running?**
There is no UI, no database, and no state — just an HTTP `GET /` that returns
`200` with four `key: value` lines. Nothing here does more than that.

## Run it

`./run.sh` is the **one sanctioned way** to run the image. It is the only place
that knows how the container is run (published port, environment, restart policy,
healthcheck, dropped privileges), and it is *self-verifying*: it waits for the
engine to report `healthy` and exits non-zero if that never happens, so exit `0`
means the service answered its own probe.

```sh
./run.sh
```

It takes four optional environment knobs — the defaults are copied here verbatim
from `run.sh`:

| Env var     | Default                             | Meaning                                        |
| ----------- | ----------------------------------- | ---------------------------------------------- |
| `IMAGE`     | `ghcr.io/oso-gato/e2e-beta:latest`  | image to run                                   |
| `NAME`      | `e2e-beta`                          | container name                                 |
| `PORT`      | `8080`                              | port inside the container, passed as `PORT`    |
| `HOST_PORT` | the value of `PORT`                 | port published on the host                     |

**Hand-rolling the container-engine run is not supported.** When the runtime
shape has to change it changes in `run.sh`, and every other entry point derives
from it:

- **`./spin-up.sh`** is an interactive wrapper. It asks for the four knobs above,
  puts the answers in the environment, and `exec`s `run.sh` — a blank answer means
  "`run.sh`'s default". It declares no engine flags of its own.
- **`e2e-beta.container`** is the systemd **Quadlet** (managed) equivalent: each
  key is a transcription of a `run.sh` flag. This repo *ships* the unit; the host
  installs it into `containers/systemd/`. It is not an alternative run path — it
  is `run.sh` as systemd would say it.

## The port

The service binds **`8080`** by default. Override it with `PORT` (the port inside
the container, handed to the service) and `HOST_PORT` (the port published on the
host, defaulting to the same as `PORT`).

## Probe it

Once `run.sh` reports healthy, ask the endpoint over the network with `curl`:

```sh
curl -s http://127.0.0.1:8080/
```

It returns `200` with exactly these four fields:

```
status: ok
host: <the container's hostname>
utc: <current UTC time, e.g. 2026-07-27T15:46:51Z>
version: <the build version, e.g. 1.2.3>
```

- `status:` — always `ok` on `GET /`.
- `host:` — the container's hostname.
- `utc:` — the current time, ISO-8601, generated live on each request.
- `version:` — the build version baked at image-build time (see **Build**).

Any path other than `/` is a real `404`.

To probe **from inside the container**, the image ships `status-probe`:

```sh
podman exec e2e-beta /usr/local/bin/status-probe          # exit 0 iff GET / answers 200 with host/utc/version
podman exec e2e-beta /usr/local/bin/status-probe --strict # the above, plus utc: within ±120s and version: non-empty
```

`--strict` proves the body is generated live (its `utc:` must parse as a UTC
timestamp within 120s of the probe's own clock) rather than served from a static
file or a cached response.

## Health

The container is **healthy only when `status-probe` gets a `200` from the
endpoint** — a live process is not enough. That single command is
`/usr/local/bin/status-probe`.

An OCI image drops the Containerfile's `HEALTHCHECK` (buildah says so at build
time: *"HEALTHCHECK is not supported for OCI image format and will be ignored"*),
so the healthcheck cannot survive a registry round-trip. Every runner therefore
**re-supplies the same one command**: `run.sh` (`--health-cmd`), the Quadlet
(`HealthCmd=`), and `.live-gate` (`HEALTH_status`) all point at
`/usr/local/bin/status-probe`, so the declarations cannot drift apart.

## Build

```sh
podman build --build-arg VERSION=1.2.3 -t localhost/e2e-beta:test -f Containerfile .
IMAGE=localhost/e2e-beta:test ./run.sh
```

`VERSION` is the single source of the served `version:` field; it is baked into
the image at build time.

On merge to `main`, CI (`.github/workflows/build.yml`) builds and publishes to
**`ghcr.io/oso-gato/e2e-beta`** with three tags:

- `:latest` — the deploy-contract default `IMAGE` in `run.sh`
- `:<YYYYMMDD>` — the build date
- `:<sha7>` — the exact source commit

The baked `VERSION` is `<YYYYMMDD>-<sha7>`, so a running container's `version:`
identifies the commit it was built from. Images are **unsigned** by design. PR
builds validate only (they never push); the monthly cron rebuild is `--no-cache`
so it picks up fresh Fedora security updates.

## Provenance & minimalism

- **Fedora repositories only** — the `registry.fedoraproject.org/fedora` base
  plus one `dnf install` of the leaf package `python3` (not a metapackage or
  group), with weak dependencies off (`--setopt=install_weak_deps=False`), docs
  off (`--nodocs`), cleaned in the same layer.
- **No third-party or COPR repos, no language package manager, no `curl | sh`,
  no downloaded binaries.** The service itself is Python **standard library only**.

## Live-gate

`.live-gate` is the host live-gate (Gate B) contract. It declares one target,
`status`, and for it: build from `Containerfile` (`CFILE_status`), the health
command `/usr/local/bin/status-probe` (`HEALTH_status`), and the functional probe
`/usr/local/bin/status-probe --strict` (`PROBE_status`). It sets no fence, so the
host runs the candidate under its hardest default: `--network=none --cap-drop=ALL`.

The host (oso-gato/fedora-bootstrap) reads this contract, **builds the image
disposably, and runs the functional loopback probe inside the candidate** — it
returns **GREEN only if the probe genuinely passes** (a build that merely compiles
is not a pass), otherwise **RED**.
