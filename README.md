# RustMCP Harbor

RustMCP Harbor is a reusable Rust development container that runs **Rust + MCPX + OpenAI Secure MCP Tunnel** beside any project on TrueNAS SCALE or another Docker host.

It contains no project, no MCPX config, no tunnel ID, and no credentials. Mount your project at `/workspace` and persistent private state at `/config`.

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

## Prepare MCPX

Harbor intentionally ships with no default MCPX config. Create on the host:

`<harbor-config>/mcpx/config.yaml`

It appears inside the container as:

`/config/mcpx/config.yaml`

Harbor sets `MCPX_HOME=/config/mcpx`, so MCPX runtime state is persistent. Projects inside the container live at `/workspace`.

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

You normally do **not** need to publish container ports 9090 or 8080. Before starting, verify that the host file `<harbor-config>/mcpx/config.yaml` exists and UID/GID 568 can read and write both mounted datasets.

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
| MCPX config is not mounted | `/config/mcpx/config.yaml` exists and permissions allow UID 568 |
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

## Security

- Runs non-root as 568:568 by default.
- Secure MCP Tunnel uses outbound connectivity; no public MCP port is required.
- Keep `/config` private and persistent.
- Never commit tunnel/API/MCPX credentials.
- MCPX policy still controls what remote ChatGPT/Codex sessions may execute or edit in the mounted workspace.
