# RustMCP Harbor

RustMCP Harbor is a reusable **Rust + MCPX** development container for TrueNAS SCALE and other Docker hosts. Mount a project at `/workspace`, expose MCPX only to a trusted reverse proxy, and publish it through your own HTTPS endpoint.

## Image

`ghcr.io/darkautism/rustmcp-harbor:latest`

GitHub Actions rebuilds the image weekly and when container files change. The image is published for `linux/amd64` and `linux/arm64`.

## Included tooling

The image includes the Rust toolchain, MCPX, `gh`, Git LFS, common native build dependencies, and Mesa DRI/Vulkan runtime support with `vulkaninfo`.

Rust binaries remain available to MCPX login shells through both `/usr/local/cargo/bin` and the persistent `/config/cargo/bin` path.

For Bevy/wgpu hardware rendering, pass the appropriate GPU render device into the container and grant UID/GID `568:568` access to it. Do not expose the entire host `/dev`.

## Minimal deployment

The only host mount required for normal use is the project:

```text
/mnt/<pool>/<project> -> /workspace
```

The container uses `/config` for Cargo and MCPX state. Mount `/config` only if you want that state to survive replacement of the container; it is not required just to provide an MCPX configuration.

The container runs as UID/GID `568:568` by default.

Publish container TCP `9090` to a LAN port that is reachable by your HTTPS reverse proxy. Do **not** port-forward MCPX `9090` directly from the Internet.

## MCPX configuration

The bundled template is:

```text
/usr/share/rustmcp-harbor/default-mcpx-config.yaml
```

The entrypoint renders the active file to:

```text
/config/mcpx/config.yaml
```

For the bundled OAuth template, set these environment variables:

```text
MCPX_BIND_HOST=0.0.0.0
MCPX_SERVER_URL=https://kpc.myvnc.com
MCPX_OAUTH_PASSWORD=<long-random-password>
```

`MCPX_BIND_HOST` defaults to `0.0.0.0`. In a normal bridged Docker container this is the correct value; the container does not own the TrueNAS host's LAN address.

`MCPX_SERVER_URL` is the public HTTPS origin, without `/mcp`.

When any of those template variables is supplied, the bundled template is rendered again on container startup. This makes TrueNAS environment variables sufficient even when only `/workspace` is mounted.

### Full config override

For complete control, set `MCPX_CONFIG` to the literal YAML configuration. It takes precedence over the bundled template and is written to `/config/mcpx/config.yaml` at startup.

If neither `MCPX_CONFIG` nor template variables are supplied, an existing `/config/mcpx/config.yaml` is kept. If no active config exists, the entrypoint tries to render the bundled template and will fail with a clear error when its required OAuth values are missing.

Project-level `.mcpx.yaml` can still narrow settings for a specific workspace.

## TrueNAS SCALE example

Create a Custom App with approximately these settings:

| Setting | Value |
| --- | --- |
| Image | `ghcr.io/darkautism/rustmcp-harbor:latest` |
| Custom User | UID `568`, GID `568` |
| Privileged | Off |
| Host Network | Off |
| Host Path | project dataset → `/workspace` |
| Port | LAN-only host `9090` → container `9090/TCP` |

Environment variables:

```text
MCPX_BIND_HOST=0.0.0.0
MCPX_SERVER_URL=https://kautism-nas.myvnc.com
MCPX_OAUTH_PASSWORD=<long-random-password>
```

For an MCPX running behind Caddy on another LAN machine, allow TCP `9090` only from the Caddy host in the machine/firewall policy.

## Caddy example

Caddy should be the public HTTPS endpoint. MCPX itself stays on the LAN:

```caddyfile
kautism-nas.myvnc.com {
    reverse_proxy 192.168.50.85:9090
}
```

The router exposes only Caddy's public HTTP/HTTPS ports. It should not forward `9090` to MCPX.

For several MCP servers, give each one its own hostname and reverse-proxy target:

```caddyfile
kautism-nas.myvnc.com {
    reverse_proxy 192.168.50.85:9090
}

opi16g.myvnc.com {
    reverse_proxy 192.168.50.86:9090
}

kpc.myvnc.com {
    reverse_proxy 192.168.50.87:9090
}
```

Each MCPX instance should use its matching public origin as `MCPX_SERVER_URL` and its own OAuth password.

## Docker Compose example

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
```

Keep the OAuth password in host environment/secrets rather than committing it.

## Useful commands

Print bundled versions:

```bash
docker run --rm ghcr.io/darkautism/rustmcp-harbor:latest versions
```

Use the image as a Rust shell/job by supplying an explicit command:

```bash
docker run --rm -it -v /path/project:/workspace ghcr.io/darkautism/rustmcp-harbor:latest bash
```

## Updating

The `latest` tag moves after a successful scheduled/action build. TrueNAS and Docker do not replace an already-running container automatically; pull the new image and redeploy/recreate the app.

Use a dated or SHA tag when you need a reproducible deployment.

## Security model

The bundled MCPX workspace/command policy is intentionally permissive for a dedicated development container. Treat access to MCPX as developer access to the mounted `/workspace`.

Keep the boundary narrow:

- Run as the non-root UID/GID `568:568` user.
- Mount only the intended project and any deliberately persistent configuration/state.
- Keep privileged mode off and do not mount the Docker socket or host root.
- Expose TCP `9090` only to the trusted Caddy/reverse-proxy host; never forward it directly from WAN.
- Terminate public TLS at Caddy and use MCPX OAuth for the public endpoint.
- Use a different strong OAuth password for each MCPX instance.
- Keep `trust_proxy_headers: true` only when direct access to MCPX is restricted to the trusted proxy.
- Treat credentials available inside the container (`gh`, SSH keys, environment variables, etc.) as available to an MCPX operator because the default command policy allows arbitrary commands.
- Use a stricter MCPX command/file policy when the workspace or operator population requires a smaller trust boundary.

The container is a development environment, not a sandbox for arbitrary untrusted users.
