# Oxcorder — portable image that runs both the test suite and live rack scans.
#
# Pinned, self-contained: Alpine + bash + jq + the oxide CLI (static musl build)
# + bats-core. Build where GitHub is reachable:
#
#   docker build -t oxcorder .
#
# Run the tests (no rack, no auth needed):
#   docker run --rm oxcorder test
#
# Run a live scan (needs a fleet.viewer token):
#   docker run --rm -e OXIDE_HOST=https://<silo>.sys.<rack>.example.com \
#                   -e OXIDE_TOKEN=oxide-token-... oxcorder -s
#
# Override any pinned version at build time, e.g.:
#   docker build --build-arg OXIDE_VERSION=v0.19.0+... -t oxcorder .

# syntax=docker/dockerfile:1

ARG ALPINE_VERSION=3.20
ARG OXIDE_VERSION=v0.18.0+2026073100.0.0
ARG BATS_VERSION=1.11.1

# --------------------------------------------------------------------------
# builder — fetch and unpack the pinned oxide CLI and bats-core
# --------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS builder
ARG OXIDE_VERSION
ARG BATS_VERSION
# hadolint ignore=DL3018
RUN apk add --no-cache curl tar xz

WORKDIR /build

# oxide CLI: static x86_64 musl binary -> /usr/local/bin/oxide
# hadolint ignore=DL4006
RUN set -eux; \
    url="https://github.com/oxidecomputer/oxide.rs/releases/download/${OXIDE_VERSION}/oxide-cli-x86_64-unknown-linux-musl.tar.xz"; \
    curl -fsSL "$url" -o oxide.tar.xz; \
    mkdir -p oxide && tar -xJf oxide.tar.xz -C oxide; \
    bin="$(find oxide -type f -name oxide | head -1)"; \
    install -m 0755 "$bin" /usr/local/bin/oxide; \
    /usr/local/bin/oxide --version

# bats-core, installed under a single prefix so the final stage copies one dir
RUN set -eux; \
    curl -fsSL "https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz" -o bats.tar.gz; \
    mkdir -p bats && tar -xzf bats.tar.gz -C bats --strip-components=1; \
    bats/install.sh /opt/bats; \
    /opt/bats/bin/bats --version

# --------------------------------------------------------------------------
# final — minimal runtime
# --------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION}

# bash: the script needs it (not busybox ash). jq: the transforms.
# ca-certificates: HTTPS to the rack. util-linux-misc: `column` for tables.
# busybox already provides `timeout`, which ox() prefers.
# hadolint ignore=DL3018
RUN apk add --no-cache bash jq ca-certificates util-linux-misc

COPY --from=builder /usr/local/bin/oxide /usr/local/bin/oxide
COPY --from=builder /opt/bats /opt/bats
ENV PATH="/opt/bats/bin:${PATH}"

WORKDIR /app
COPY . /app
RUN chmod +x oxcorder.sh tests/run.sh tests/fake-oxide docker/entrypoint.sh

# Smoke: the script parses and the tools resolve at build time.
RUN bash -n oxcorder.sh && command -v oxide jq bats timeout column >/dev/null

ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["run"]
