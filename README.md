# RustMCP Harbor

RustMCP Harbor is a reusable Rust development container that runs **Rust + MCPX + OpenAI Secure MCP Tunnel** beside any project on TrueNAS SCALE or another Docker host.

It contains no project, tunnel ID, or credentials. Mount your project at `/workspace` and persistent private state at `/config`. Harbor includes a bundled MCPX allow-all default for normal tunnel-enabled startup; a user-supplied `/config/mcpx/config.yaml` always overrides it.

## Image

`ghcr.io/darkautism/rustmcp-harbor:latest`

GitHub Actions rebuilds the image every Monday and on container changes. Each build pulls current `rust:latest`, current MCPX source, and OpenAI's current stable `ghcr.io/openai/tunnel-client:latest`, then publishes `linux/amd64` and `linux/arm64` and smoke-tests both architectures.

## What you need

Two persistent mounts are enough:

| Host data | Container path | Purpose |
| --- | --- | --- |
| your project | `/workspace` | source code MCPX manages |
| private Harbor data | `/config` | MCPX config/state, Cargo cache, tunnel state and secrets |

The container runs as UID/GID `568:568` by default, which matches the default TrueNAS Apps custom-user IDs. Give that identity read/write permission on both datasets.

Do not enable privileged mode, host networking, `/dev`, or the Docker socket just to use Secure MCP Tunnel.

## MCPX default and override

Harbor bundles this template inside the image:

`/usr/share/rustmcp-harbor/default-mcpx-config.yaml`

The bundled template registers `/workspace` and is intentionally **allow-all** for MCPX file access and terminal commands. During normal Secure MCP Tunnel startup, if `/config/mcpx/config.yaml` does not exist, the entrypoint copies the bundled template there. Because `/config` is persistent, that generated file can then be edited normally.

Harbor never overwrites an existing config. To override the default, create on the host:

`<harbor-config>/mcpx/config.yaml`

and mount the Harbor config dataset at `/config`. The file then appears as:

`/config/mcpx/config.yaml`

For example, a more restrictive override can require confirmation by default and allow only selected read-only commands:

```yaml
server:
  host: 127.0.0.1
  port: 9090

auth:
  mode: open

workspaces:
  - name: workspace
    path: /workspace

security:
  commands:
    default: confirm
    allow:
      - ^git status$
      - ^git diff
    deny: []
  files:
    max_read_bytes: 4194304
    max_patch_files: 20
    max_patch_lines: 2000
    allow:
      - ^src/
      - ^Cargo\.toml$
      - ^Cargo\.lock$
```

`MCPX_HOME=/config/mcpx`, so MCPX state and the active config remain persistent. Project-level `.mcpx.yaml` can further narrow a specific workspace.

## Prepare the OpenAI tunnel

Provide these environment variables to the container:

`CONTROL_PLANE_TUNNEL_ID=tunnel_...`

`CONTROL_PLANE_API_KEY=<runtime API key>`

Harbor already sets:

`MCP_SERVER_URL=http://127.0.0.1:9090/mcp`

Use a runtime credential intended to operate the tunnel; do not bake secrets into the image or repository. The tunnel is outbound from the container, so normal ChatGPT connectivity does not require an inbound router port.

## Deploy on TrueNAS SCALE

In **Apps → Discover Apps → Custom App**, create an app with:

| Setting | Value |
| --- | --- |
| Name | `rustmcp-harbor` |
| Image repository | `ghcr.io/darkautism/rustmcp-harbor` |
| Tag | `latest` |
| Custom User | UID `568`, GID `568` |
| Privileged | Off |
| Host Network | Off |

Add two **Host Path** mounts:

`/mnt/<pool>/<project> -> /workspace`

`/mnt/<pool>/<harbor-config> -> /config`

Add environment variables:

`CONTROL_PLANE_TUNNEL_ID=tunnel_...`

`CONTROL_PLANE_API_KEY=<runtime API key>`

You normally do **not** need to publish container ports 9090 or 8080. UID/GID 568 must be able to read and write both mounted datasets. You may pre-create `<harbor-config>/mcpx/config.yaml`; if you omit it, normal tunnel-enabled startup installs Harbor's bundled allow-all default automatically.

Save/install the Custom App, then inspect its logs. MCPX should start first; tunnel-client starts after MCPX becomes reachable.

## Docker Compose

```yaml
services:
  rustmcp-harbor:
    image: ghcr.io/darkautism/rustmcp-harbor:latest
    restart: unless-stopped
    environment:
      CONTROL_PLANE_TUNNEL_ID: tunnel_0123456789abcdef0123456789abcdef
      CONTROL_PLANE_API_KEY: ${CONTROL_PLANE_API_KEY}
    volumes:
      - /path/to/project:/workspace
      - /path/to/harbor-config:/config
```

Keep the real key in the host environment or another secret store rather than committing it.

## Optional tunnel profile

For advanced tunnel-client settings, mount a profile at:

`/config/tunnel/profile.yaml`

The Harbor entrypoint detects it automatically. Native tunnel-client profile/config environment variables remain available.

## Connect ChatGPT

Keep Harbor running, then add/configure the Secure MCP Tunnel connector in ChatGPT using the same tunnel. Complete connector discovery while the container is healthy and ready. MCPX then exposes the workspaces you configured under `/workspace`.

If the tunnel exists but ChatGPT cannot discover tools, check the Harbor logs, MCPX startup, tunnel credentials, and tunnel workspace/permission assignment.

## Health and troubleshooting

Typical failures:

| Message/symptom | Check |
| --- | --- |
| MCPX config is not mounted | supply tunnel settings so Harbor can install its bundled default, or mount your own `/config/mcpx/config.yaml`; verify UID 568 can write `/config` |
| API key required | `CONTROL_PLANE_API_KEY` is set |
| tunnel ID required | `CONTROL_PLANE_TUNNEL_ID` is set correctly |
| tunnel alive but not ready | inspect MCPX startup and tunnel readiness/logs |
| ChatGPT sees no tools | verify tunnel readiness and MCPX workspace registration |

Print bundled versions:

`docker run --rm ghcr.io/darkautism/rustmcp-harbor:latest versions`

Use Harbor only as a Rust shell/job by supplying an explicit command:

`docker run --rm -it -v /path/project:/workspace -v /path/config:/config ghcr.io/darkautism/rustmcp-harbor:latest bash`

## Updating

The `latest` tag moves after a successful weekly/action build. TrueNAS and Docker do not replace an already-running container automatically just because that tag changed. Pull/update the image and redeploy/recreate the app.

Use the dated `weekly-YYYYMMDD` or `sha-...` tag when you want a reproducible deployment instead of the moving `latest` tag.

## Rust toolchain

Harbor sets `RUSTUP_TOOLCHAIN=stable`, so projects use the stable toolchain contained in that week's image. Unset it if a project must honor its own `rust-toolchain.toml`.

## Security model

The bundled MCPX config is intentionally permissive. Its safety boundary is the **container**, not a restrictive MCPX allowlist. With the default config, a connected owner/editor can read and modify files in the registered `/workspace` and run commands as the container user.

Use the default safely by keeping the container boundary narrow:

- Runs non-root as UID/GID `568:568` by default.
- Mount only the intended project at `/workspace` and Harbor state at `/config`; do not mount the host root, unrelated datasets, SSH key directories, or other sensitive paths.
- Keep privileged mode off and do not mount the Docker socket or host `/dev`.
- Keep host networking off for normal use. MCPX listens on `127.0.0.1` inside the container and Secure MCP Tunnel uses outbound connectivity, so no public MCP port is required.
- Keep `/config` private and persistent; never commit tunnel/API/MCPX credentials.
- Treat write access to `/workspace` as real developer access: keep source control and backups available for anything important.
- If multiple users share the tunnel, or the mounted project contains sensitive material, replace `/config/mcpx/config.yaml` with a restrictive policy before exposing the connector.

The bundled default is optimized for a dedicated development container where `/workspace` is the deliberate trust boundary. It is not a production sandbox for arbitrary host files.
