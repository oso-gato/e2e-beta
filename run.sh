#!/usr/bin/env bash
#
# e2e-beta — THE single sanctioned way to run this image.
#
# This script is the ONLY place in the repo that knows how the container is run.
# The complete runtime shape — published port, environment, restart policy,
# healthcheck, privilege drops — is declared here and nowhere else. Hand-rolling
# the engine invocation is not supported: when the runtime shape has to change,
# it changes here, and every caller (wizard, unit file, CI, a human) goes
# through this script.
#
# NON-INTERACTIVE by contract: it never prompts and never reads stdin, so
# `./run.sh < /dev/null` behaves identically to a normal run and it is safe to
# call unattended.
#
# SELF-VERIFYING: it does not merely start the container, it waits for the engine
# to report `healthy` and exits non-zero if that never happens inside a bounded
# window. A zero exit therefore means the service answered its own probe — the
# script is the oracle for "it came up and it is healthy", not the caller.
#
# ENV KNOBS (all optional; defaults in the second column)
#
#   IMAGE      ghcr.io/oso-gato/e2e-beta:latest  image to run. Override with
#                                                localhost/e2e-beta:test to
#                                                validate a locally built image.
#   NAME       e2e-beta                          container name.
#   PORT       8080                              port inside the container,
#                                                handed to the service as PORT.
#   HOST_PORT  the value of PORT                 port published on the host.
#
# EXIT STATUS: 0 only when the container is running AND healthy. Every other
# outcome — bad input, missing image, container died, never became healthy — is
# a non-zero exit with a message on stderr.

set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/oso-gato/e2e-beta:latest}"
NAME="${NAME:-e2e-beta}"
PORT="${PORT:-8080}"
HOST_PORT="${HOST_PORT:-$PORT}"

# How long we are willing to wait for the engine to report `healthy`, and how
# often we look. Deliberately constants and not env knobs: the wait is an
# internal implementation detail of "self-verifying", not part of the contract.
READY_TIMEOUT_SECONDS=90
POLL_INTERVAL_SECONDS=2

die() {
    printf 'run.sh: %s\n' "$*" >&2
    exit 1
}

say() {
    printf 'run.sh: %s\n' "$*"
}

# Report the container's health as the engine sees it, or `none` when the
# container is gone or carries no healthcheck.
health_of() {
    podman inspect "$NAME" \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        2>/dev/null || printf 'none\n'
}

# Report the container's lifecycle state, or `gone` when it no longer exists.
state_of() {
    podman inspect "$NAME" --format '{{.State.Status}}' 2>/dev/null || printf 'gone\n'
}

# --- input ------------------------------------------------------------------
# Catch a missing engine or a malformed port here rather than letting either
# become an opaque error half a screen later.
command -v podman >/dev/null || die "podman is not on PATH"

[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT must be a whole number, got '$PORT'"
[[ "$HOST_PORT" =~ ^[0-9]+$ ]] || die "HOST_PORT must be a whole number, got '$HOST_PORT'"

# --- image ------------------------------------------------------------------
# Resolve the image up front so a typo or an unreachable registry fails here,
# loudly, instead of inside `podman run`. A locally built image is used as-is
# and never pulled, which is what makes IMAGE=localhost/e2e-beta:test work.
if ! podman image exists "$IMAGE"; then
    say "image '$IMAGE' is not present locally — pulling"
    podman pull "$IMAGE" ||
        die "cannot obtain image '$IMAGE' — it is neither present locally nor pullable"
fi

# --- run --------------------------------------------------------------------
say "starting '$NAME' from '$IMAGE' (host $HOST_PORT -> container $PORT)"

# Every flag below is part of the runtime contract. Notes on the ones whose
# absence would be a silent defect:
#
#   --replace           re-running this script is an update, not a name
#                       collision, so it is idempotent by construction.
#   --pull=never        the image was resolved above; this makes the run step
#                       incapable of a surprise pull, and so incapable of hanging.
#   --health-*          REQUIRED, not redundant with the Containerfile. The OCI
#                       image spec has no healthcheck field, so a HEALTHCHECK
#                       does not survive a registry round-trip; the runtime has
#                       to re-supply it, and this is the runtime.
#   --restart           survives an engine restart without a human.
#   --cap-drop=ALL      the service runs as uid 1000 and binds a port above
#     + no-new-privs    1024, so it needs no capability whatsoever and can
#                       never gain one.
#   --read-only         verified, not assumed: the service serves and passes its
#                       own probe with the whole rootfs read-only and no writable
#                       tmpfs, so no --tmpfs is needed here.
podman run \
    --detach \
    --name "$NAME" \
    --replace \
    --pull=never \
    --publish "${HOST_PORT}:${PORT}" \
    --env "PORT=${PORT}" \
    --restart=unless-stopped \
    --cap-drop=ALL \
    --security-opt no-new-privileges \
    --read-only \
    --health-cmd /usr/local/bin/status-probe \
    --health-interval 5s \
    --health-timeout 5s \
    --health-retries 3 \
    --health-start-period 5s \
    "$IMAGE" >/dev/null ||
    die "engine refused to start '$NAME' from '$IMAGE'"

# --- wait for healthy -------------------------------------------------------
say "waiting up to ${READY_TIMEOUT_SECONDS}s for '$NAME' to report healthy"

deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
while [[ "$SECONDS" -lt "$deadline" ]]; do
    state="$(state_of)"
    if [[ "$state" != "running" ]]; then
        # The container died rather than became unhealthy. Waiting out the full
        # window would tell us nothing, so stop now and show why. Both of the
        # container's streams are forwarded to ours: a crash lands on its
        # stderr, which is precisely the line worth reading.
        podman logs --tail 20 "$NAME" >&2 || true
        die "container '$NAME' is '$state', not running — see the log above"
    fi

    # Drive the check ourselves instead of waiting on the engine's healthcheck
    # timer. It records exactly what the timer would record, it makes readiness
    # deterministic rather than a race against the next tick, and it keeps this
    # script honest where that timer does not run.
    podman healthcheck run "$NAME" >/dev/null 2>&1 || true

    if [[ "$(health_of)" == "healthy" ]]; then
        say "'$NAME' is healthy"
        say "probe it: http://127.0.0.1:${HOST_PORT}/"
        exit 0
    fi

    sleep "$POLL_INTERVAL_SECONDS"
done

podman logs --tail 20 "$NAME" >&2 || true
die "'$NAME' did not report healthy within ${READY_TIMEOUT_SECONDS}s (last state: $(state_of)/$(health_of)) — see the log above"
