# syntax=docker/dockerfile:1.7

ARG GO_IMAGE=golang:latest
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

FROM ${RUST_IMAGE} AS runtime
ARG TARGETARCH
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
    && install -d /workspace /root/.cargo /root/.mcpx /usr/share/rustmcp-harbor \
    && printf '%s\n' 'export PATH="/root/.cargo/bin:/usr/local/cargo/bin:$PATH"' > /etc/profile.d/rustmcp-harbor-path.sh \
    && chmod 0644 /etc/profile.d/rustmcp-harbor-path.sh

COPY --from=mcpx-builder /out/mcpx /usr/local/bin/mcpx
COPY docker/dev-entrypoint.sh /usr/local/bin/dev-entrypoint
COPY docker/default-mcpx-config.yaml /usr/share/rustmcp-harbor/default-mcpx-config.yaml

RUN chmod 0755 \
    /usr/local/bin/mcpx \
    /usr/local/bin/dev-entrypoint

ENV PATH=/root/.cargo/bin:/usr/local/cargo/bin:${PATH} \
    RUST_BACKTRACE=1

WORKDIR /workspace

EXPOSE 9090
VOLUME ["/workspace", "/root"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/dev-entrypoint"]
