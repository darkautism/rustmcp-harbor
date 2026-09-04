# syntax=docker/dockerfile:1.7

ARG GO_IMAGE=golang:latest
ARG RUST_IMAGE=rust:latest
ARG TUNNEL_IMAGE=ghcr.io/openai/tunnel-client:latest

FROM --platform=${BUILDPLATFORM} ${GO_IMAGE} AS mcpx-builder
ARG TARGETOS
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN mkdir -p /out \
    && git clone --depth 1 https://github.com/opentokenz/mcpx.git /src/mcpx \
    && cd /src/mcpx \
    && CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
       go build -trimpath -o /out/mcpx ./cmd/mcpx-server

# Follow OpenAI's published stable multi-arch image instead of duplicating its
# internal UI/Go/cloudflared build pipeline. Weekly --pull builds refresh it.
FROM --platform=${TARGETPLATFORM} ${TUNNEL_IMAGE} AS tunnel-runtime

FROM ${RUST_IMAGE} AS runtime
ARG DEV_UID=568
ARG DEV_GID=568

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bash \
       build-essential \
       ca-certificates \
       clang \
       cmake \
       curl \
       file \
       git \
       jq \
       libasound2-dev \
       libegl1-mesa-dev \
       libgl1-mesa-dev \
       libssl-dev \
       libudev-dev \
       libwayland-dev \
       libx11-dev \
       libx11-xcb-dev \
       libxcursor-dev \
       libxi-dev \
       libxinerama-dev \
       libxkbcommon-dev \
       libxkbcommon-x11-dev \
       libxrandr-dev \
       lld \
       openssh-client \
       pkg-config \
       tini \
       tmux \
    && rm -rf /var/lib/apt/lists/* \
    && rustup component add clippy rustfmt \
    && groupadd --gid "${DEV_GID}" dev \
    && useradd --uid "${DEV_UID}" --gid "${DEV_GID}" --create-home --shell /bin/bash dev \
    && install -d -o "${DEV_UID}" -g "${DEV_GID}" \
       /workspace /config /config/home /config/cargo /config/mcpx \
       /config/tunnel /config/tunnel/state /config/secrets \
    && install -d /usr/share/rustmcp-harbor

COPY --from=mcpx-builder /out/mcpx /usr/local/bin/mcpx
COPY --from=tunnel-runtime /usr/bin/tunnel-client /usr/local/bin/tunnel-client
COPY --from=tunnel-runtime /usr/bin/cloudflared /usr/local/bin/cloudflared
COPY docker/dev-entrypoint.sh /usr/local/bin/dev-entrypoint
COPY docker/default-mcpx-config.yaml /usr/share/rustmcp-harbor/default-mcpx-config.yaml

RUN chmod 0755 \
    /usr/local/bin/mcpx \
    /usr/local/bin/tunnel-client \
    /usr/local/bin/cloudflared \
    /usr/local/bin/dev-entrypoint

ENV HOME=/config/home \
    CARGO_HOME=/config/cargo \
    MCPX_HOME=/config/mcpx \
    TUNNEL_CLIENT_PROFILE_DIR=/config/tunnel \
    TUNNEL_CLIENT_STATE_DIR=/config/tunnel/state \
    MCP_SERVER_URL=http://127.0.0.1:9090/mcp \
    RUSTUP_TOOLCHAIN=stable \
    RUST_BACKTRACE=1

WORKDIR /workspace
USER dev:dev

EXPOSE 9090 8080
VOLUME ["/workspace", "/config"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/dev-entrypoint"]
