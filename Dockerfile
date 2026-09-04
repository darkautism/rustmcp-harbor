# syntax=docker/dockerfile:1.7

ARG GO_IMAGE=golang:latest
ARG RUST_IMAGE=rust:latest

FROM --platform=${BUILDPLATFORM} ${GO_IMAGE} AS tool-builder
ARG TARGETOS
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates git python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN mkdir -p /out

# Intentionally follow upstream default branches. The weekly GitHub workflow
# builds with pull + no-cache so each build resolves current upstream HEADs.
RUN git clone --depth 1 https://github.com/opentokenz/mcpx.git /src/mcpx \
    && cd /src/mcpx \
    && CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
       go build -trimpath -o /out/mcpx ./cmd/mcpx-server

RUN git clone --depth 1 https://github.com/openai/tunnel-client.git /src/tunnel-client \
    && cd /src/tunnel-client \
    && git_sha="$(git rev-parse HEAD)" \
    && go_version="$(go env GOVERSION)" \
    && CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
       go build -mod=readonly -trimpath -buildvcs=false \
       -ldflags "-s -w -X github.com/openai/tunnel-client/pkg/version.GitSHA=${git_sha} -X github.com/openai/tunnel-client/pkg/version.GoVersion=${go_version}" \
       -o /out/tunnel-client ./cmd/client \
    && bash ./scripts/build_cloudflared.sh \
       --goos "${TARGETOS}" \
       --goarch "${TARGETARCH}" \
       --manifest pkg/cloudflared/runtime/manifest.json \
       --output /out/cloudflared \
    && cp pkg/cloudflared/runtime/manifest.json /out/cloudflared-manifest.json

FROM ${RUST_IMAGE} AS runtime

# TrueNAS Custom Apps commonly use 568:568. These remain build args so the
# image can be rebuilt for a different host identity if needed.
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
       /usr/share/tunnel-client

COPY --from=tool-builder /out/mcpx /usr/local/bin/mcpx
COPY --from=tool-builder /out/tunnel-client /usr/local/bin/tunnel-client
COPY --from=tool-builder /out/cloudflared /usr/local/bin/cloudflared
COPY --from=tool-builder /out/cloudflared-manifest.json /usr/share/tunnel-client/cloudflared-manifest.json
COPY docker/dev-entrypoint.sh /usr/local/bin/dev-entrypoint

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

# Metadata only. Normal Secure MCP Tunnel use requires no published inbound port.
EXPOSE 9090 8080
VOLUME ["/workspace", "/config"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/dev-entrypoint"]
