# syntax=docker/dockerfile:1.7

ARG GO_IMAGE=golang:latest
ARG NODE_IMAGE=node:24-bookworm-slim
ARG RUST_IMAGE=rust:latest

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

FROM --platform=${TARGETPLATFORM} ${NODE_IMAGE} AS node-tools
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@latest \
    && npm install -g @agegr/pi-web@latest

FROM ${RUST_IMAGE} AS runtime
ARG TARGETARCH
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
       gh \
       git \
       git-lfs \
       jq \
       libasound2-dev \
       libegl1-mesa-dev \
       libgl1-mesa-dev \
       libgl1-mesa-dri \
       libssl-dev \
       libvulkan1 \
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
       mesa-vulkan-drivers \
       openssh-client \
       pkg-config \
       ripgrep \
       tini \
       tmux \
       vulkan-tools \
    && rm -rf /var/lib/apt/lists/* \
    && rustup component add clippy rustfmt \
    && cargo install --locked cargo-expand \
    && cargo install --locked cargo-bloat \
    && case "${TARGETARCH}" in \
         amd64) NEXTEST_URL="https://get.nexte.st/latest/linux" ;; \
         arm64) NEXTEST_URL="https://get.nexte.st/latest/linux-arm" ;; \
         *) echo "unsupported TARGETARCH for cargo-nextest: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && curl -LsSf "${NEXTEST_URL}" | tar zxf - -C /usr/local/cargo/bin \
    && groupadd --gid "${DEV_GID}" dev \
    && useradd --uid "${DEV_UID}" --gid "${DEV_GID}" --create-home --shell /bin/bash dev \
    && install -d -o "${DEV_UID}" -g "${DEV_GID}" \
       /workspace /config /config/home /config/cargo /config/mcpx \
    && install -d /usr/share/rustmcp-harbor \
    && printf '%s\n' 'export PATH="/config/cargo/bin:/usr/local/cargo/bin:$PATH"' > /etc/profile.d/rustmcp-harbor-path.sh \
    && chmod 0644 /etc/profile.d/rustmcp-harbor-path.sh

COPY --from=mcpx-builder /out/mcpx /usr/local/bin/mcpx
COPY --from=node-tools /usr/local/bin/node /usr/local/bin/node
COPY --from=node-tools /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY docker/dev-entrypoint.sh /usr/local/bin/dev-entrypoint
COPY docker/default-mcpx-config.yaml /usr/share/rustmcp-harbor/default-mcpx-config.yaml

RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && ln -s ../lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js /usr/local/bin/pi \
    && ln -s ../lib/node_modules/@agegr/pi-web/bin/pi-web.js /usr/local/bin/pi-web \
    && chmod 0755 \
       /usr/local/bin/mcpx \
       /usr/local/bin/dev-entrypoint

ENV HOME=/config/home \
    CARGO_HOME=/config/cargo \
    PATH=/config/cargo/bin:/usr/local/cargo/bin:${PATH} \
    MCPX_HOME=/config/mcpx \
    PI_WEB_HOSTNAME=0.0.0.0 \
    PI_WEB_PORT=8080 \
    PI_WEB_NO_OPEN=1 \
    PI_WEB_IDLE_TIMEOUT_MS=0 \
    RUST_BACKTRACE=1

WORKDIR /workspace
USER dev:dev

EXPOSE 8080 9090
VOLUME ["/workspace", "/config"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/dev-entrypoint"]
