# e2e-beta — a minimal status-page image. Serves one plain-text endpoint that
# answers "is this box alive, and which build is it running?".
#
# PROVENANCE (F1): every package comes from Fedora's own repositories — one
# `dnf install` of the most specific leaf package (`python3`, not a metapackage
# or group), weak deps off, docs off, cleaned in the SAME layer. No third-party
# or COPR repos, no language package manager, no `curl | sh`, no downloaded
# binaries. The service itself is Python standard library only.
#
# LAYER ORDER: heavy/stable early, churn late — the dnf layer is cached across
# rebuilds while the service and the VERSION arg change on every iteration.
ARG FEDORA_VERSION=44
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION}

RUN dnf -y install --setopt=install_weak_deps=False --nodocs python3 \
    && dnf clean all

# Configurable at runtime (`-e PORT=9090`); the server reads it on start.
ENV PORT=8080

# Documentation only — publishing the port is run.sh's job, not the image's.
EXPOSE 8080

COPY --chmod=755 bin/status-server /usr/local/bin/status-server

# STATUS_VERSION is the SINGLE source of the served version — there is no VERSION
# file and no second env var to drift from it.
ARG VERSION=0.0.0-dev

# Record the version in the build log. This is NOT decoration: buildah computes
# the cache key of `ENV STATUS_VERSION=${VERSION}` from the UNEXPANDED instruction
# text, so on a warm cache a changed --build-arg silently reuses the previous
# layer and the image reports a version it was not built with (observed: building
# --build-arg VERSION=4.5.6 yielded an image serving 9.9.9). A RUN that consumes
# the arg keys on the expanded value, so the version layers below rebuild whenever
# VERSION actually changes.
RUN echo "e2e-beta build version: ${VERSION}"

ENV STATUS_VERSION=${VERSION}

# Unprivileged. 8080 is >1024, so no capability is needed to bind it.
USER 1000

CMD ["/usr/local/bin/status-server"]
