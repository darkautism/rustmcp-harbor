# RustMCP Harbor

A small MCPX container for TrueNAS SCALE and other Docker hosts.

The image builds MCPX from upstream, starts it on TCP `9090`, keeps its state under `/root/.mcpx`, and includes a practical set of command-line and GPU/runtime packages for agent work. There is no Rust toolchain or Cargo setup in the Dockerfile.

## Image

```text
ghcr.io/darkautism/rustmcp-harbor:latest
```

The image is published for `linux/amd64` and `linux/arm64`.

## Included tools

MCPX is the only application managed by the container entrypoint.

The runtime also keeps the existing apt-installed tools that are useful for agent work, including:

```text
bash
build-essential
clang
cmake
curl
file
gh
git
git-lfs
jq
lld
openssh-client
pkg-config
ripgrep
tmux
```

GPU and desktop/runtime support is also retained, including Mesa, Vulkan, EGL, X11, Wayland, udev, ALSA, and related development libraries. `vulkaninfo` is available through `vulkan-tools`.

## Mounts

Recommended mounts:

```text
/mnt/<pool>/<project>     -> /workspace
/mnt/<pool>/<harbor-root> -> /root
```

`/workspace` is the MCPX project workspace.

`/root` is the persistent home/state mount. MCPX stores its active config at:

```text
/root/.mcpx/config.yaml
```

Anything an agent installs or configures under `/root` survives container replacement when the same dataset is mounted again. Files written elsewhere in the container filesystem, such as `/usr`, `/usr/local`, or `/etc`, are not made persistent by the `/root` mount.

## MCPX configuration

The bundled template is stored at:

```text
/usr/share/mcpx-harbor/default-mcpx-config.yaml
```

On startup the entrypoint writes or reuses:

```text
/root/.mcpx/config.yaml
```

For the bundled OAuth template, set:

```text
MCPX_BIND_HOST=0.0.0.0
MCPX_SERVER_URL=https://kpc.myvnc.com
MCPX_OAUTH_PASSWORD=<password>
```

`MCPX_BIND_HOST` defaults to `0.0.0.0`.

`MCPX_SERVER_URL` is the public HTTPS origin, without `/mcp`.

If any template variable is supplied, the template is rendered again on container startup. If no template variables are supplied, an existing `/root/.mcpx/config.yaml` is kept.

### Full config override

Set `MCPX_CONFIG` to literal YAML to replace the bundled template completely. It is written to `/root/.mcpx/config.yaml` at startup.

## Ports

MCPX listens on container TCP `9090`.

```text
host/LAN port -> 9090/TCP
```

Normally this should be reachable only by the trusted reverse proxy or trusted LAN clients.

## TrueNAS SCALE

Typical Custom App settings:

| Setting | Value |
| --- | --- |
| Image | `ghcr.io/darkautism/rustmcp-harbor:latest` |
| User | root / UID `0` |
| Privileged | Off |
| Host Network | Off |
| Workspace mount | project dataset → `/workspace` |
| Persistent home | state dataset → `/root` |
| Port | LAN host port → container `9090/TCP` |

Environment example:

```text
MCPX_BIND_HOST=0.0.0.0
MCPX_SERVER_URL=https://kautism-nas.myvnc.com
MCPX_OAUTH_PASSWORD=<password>
```

## Docker Compose

```yaml
services:
  rustmcp-harbor:
    image: ghcr.io/darkautism/rustmcp-harbor:latest
    restart: unless-stopped
    environment:
      MCPX_BIND_HOST: 0.0.0.0
      MCPX_SERVER_URL: https://kpc.myvnc.com
      MCPX_OAUTH_PASSWORD: ${MCPX_OAUTH_PASSWORD}
    ports:
      - "9090:9090"
    volumes:
      - /path/to/project:/workspace
      - /path/to/harbor-root:/root
```

## Useful commands

Print the bundled application/tool versions:

```bash
docker run --rm ghcr.io/darkautism/rustmcp-harbor:latest versions
```

Open a shell instead of starting MCPX:

```bash
docker run --rm -it \
  -v /path/project:/workspace \
  -v /path/harbor-root:/root \
  ghcr.io/darkautism/rustmcp-harbor:latest bash
```

## GPU access

The image keeps Mesa/Vulkan userspace support. If a workload needs hardware acceleration, pass only the required GPU/render devices into the container and configure the host permissions needed for those devices.

The image does not require privileged mode just to provide MCPX.

## Updating

Pull the new image and recreate/redeploy the container when a new tag is published. Data under the mounted `/workspace` and `/root` paths remains outside the image lifecycle.
