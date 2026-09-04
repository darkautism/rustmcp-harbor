# RustMCP Harbor

RustMCP Harbor is a reusable Rust development container that runs **Rust + MCPX + OpenAI Secure MCP Tunnel** beside any project on TrueNAS SCALE or another Docker host.

It contains no project, tunnel ID, or OpenAI credential. Mount your project at `/workspace` and persistent private state at `/config`. For the default path, Harbor automatically generates and persists an internal MCPX Bearer token, configures MCPX to require it, and configures tunnel-client to send it. You do not need to create a separate MCP token.

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

The bundled template registers `/workspace`, is intentionally **allow-all** for MCPX file access and terminal commands, and uses `auth.mode: bearer`. During normal Secure MCP Tunnel startup, if `/config/mcpx/config.yaml` does not exist, Harbor generates a cryptographically random 256-bit token, stores it at `/config/secrets/mcpx-bearer-token`, renders the active MCPX config with that token, and sets tunnel-client MCP runtime/discovery headers to `Authorization: Bearer <token>` automatically. Both the active config and token file are created with private file permissions where the mounted filesystem permits it.

The token is internal to the container-to-MCP hop. tunnel-client's static MCP headers are scoped to the configured MCP server origin and are not sent to the OpenAI control plane. Harbor uses both `MCP_EXTRA_HEADERS` and `MCP_DISCOVERY_EXTRA_HEADERS` so ordinary MCP requests and startup/discovery probes authenticate consistently.

Harbor never overwrites an unrelated custom config. It also migrates the exact legacy Harbor open-auth default to the new bearer-protected default. To override Harbor's managed default, create on the host:

`<harbor-config>/mcpx/config.yaml`

and mount the Harbor config dataset at `/config`. The file then appears as:

`/config/mcpx/config.yaml`

For example, a more restrictive override can require confirmation by default and allow only selected read-only commands:

```yaml
server:
  host: 127.0.0.1
  port: 9090

auth:
  mode: bearer
  token: "replace-with-your-own-private-token"

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

Harbor keeps Rust tooling on the command PATH for MCPX login-shell execution. `/usr/local/cargo/bin` contains the image's bundled `cargo`/`rustup` proxies, while `/config/cargo/bin` holds persistent binaries installed with `cargo install`; both are prepended through the image environment and `/etc/profile.d/rustmcp-harbor-path.sh`. MCPX executes Unix command strings through `bash -lc`, whose login startup can otherwise replace the image PATH.

If your custom config also uses static Bearer auth, set `MCPX_BEARER_TOKEN` to the same token. Harbor will then configure tunnel-client's MCP headers for you without modifying the custom config. If you want full manual control, set `MCP_EXTRA_HEADERS` and `MCP_DISCOVERY_EXTRA_HEADERS` yourself; explicit values are preserved.

## Create the OpenAI tunnel and runtime key

Harbor automatically handles the **internal MCPX Bearer token**. You do not create or copy that token into OpenAI. For a normal deployment, you only provide the two OpenAI-side values that tunnel-client requires:

`CONTROL_PLANE_TUNNEL_ID=tunnel_...`

`CONTROL_PLANE_API_KEY=<restricted runtime API key>`

Harbor already sets `MCP_SERVER_URL=http://127.0.0.1:9090/mcp` and automatically gives tunnel-client the separate internal MCP Authorization header.

### 1. Set the tunnel permissions

Open [Organization roles](https://platform.openai.com/settings/organization/people/roles). The identity whose runtime key will run Harbor needs **Tunnels: Read + Use**.

If the same person will also create or edit tunnel records, give that manager **Tunnels: Read + Manage**, plus **Use** if they will also run Harbor or attach the ChatGPT connector.

For larger organizations, OpenAI recommends assigning these roles through [Organization groups](https://platform.openai.com/settings/organization/people/groups).

### 2. Create the tunnel

Open [OpenAI Platform → Tunnels](https://platform.openai.com/settings/organization/tunnels) and create a tunnel. Attach the correct ChatGPT workspace scope if the tunnel must appear in that workspace's connector picker.

Copy the resulting ID. It looks like:

`CONTROL_PLANE_TUNNEL_ID=tunnel_0123456789abcdef0123456789abcdef`

You can also create/manage tunnels with `tunnel-client admin tunnels ...`, but that path requires a separate `OPENAI_ADMIN_KEY`. Harbor does not need an admin key for normal runtime use.

### 3. Create the runtime API key

Open [OpenAI Platform → Runtime API keys](https://platform.openai.com/settings/organization/api-keys).

Create a **Restricted** key for the identity that will run Harbor. Grant **Tunnels: Read + Use**. Do not use an unrestricted `All` key or an admin API key for the long-lived Harbor runtime.

Save the new key as:

`CONTROL_PLANE_API_KEY=<your runtime key>`

The key's principal must also have permission to use the target tunnel; creating a key alone does not grant tunnel access.

### 4. Configure Harbor

Set only these OpenAI tunnel variables in TrueNAS/Docker:

```text
CONTROL_PLANE_TUNNEL_ID=tunnel_...
CONTROL_PLANE_API_KEY=<restricted runtime API key>
```

On first normal tunnel-enabled startup, Harbor automatically:

1. creates a persistent random MCPX Bearer token;
2. stores it under `/config/secrets/mcpx-bearer-token`;
3. configures MCPX `auth.mode: bearer` with that token;
4. configures tunnel-client's MCP runtime requests with `Authorization: Bearer ...`;
5. configures tunnel-client's MCP discovery/initialize probe with the same header.

You therefore do **not** need a third MCP token setting for the default Harbor configuration.

### 5. Attach ChatGPT to the same tunnel

Open [ChatGPT → Connectors](https://chatgpt.com/#settings/Connectors), add/configure the connector with **Connection: Tunnel**, then select or paste the same tunnel ID used by Harbor.

If the tunnel does not appear, verify its ChatGPT workspace scope and that the connector operator has **Tunnels: Use**.

### Official tunnel-client references

- [Tunnel end-user guide](https://github.com/openai/tunnel-client/blob/master/docs/end-user-guide.md)
- [Permissions, roles, tunnel IDs, and API keys](https://github.com/openai/tunnel-client/blob/master/docs/permissions.md)
- [Tunnel-client configuration reference](https://github.com/openai/tunnel-client/blob/master/docs/configuration.md)
- [Deployment and network requirements](https://github.com/openai/tunnel-client/blob/master/docs/deployment/overview.md)

Use a runtime credential intended to operate the tunnel; do not bake OpenAI secrets into the image or repository. The tunnel uses outbound HTTPS to OpenAI, so normal ChatGPT connectivity does not require an inbound router port.

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
| MCP initialize/probe returns 401 | with Harbor's managed config, verify `/config/secrets/mcpx-bearer-token` and the managed config remain paired; with a custom Bearer config, set matching `MCPX_BEARER_TOKEN` or explicit MCP header env vars |
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
- Keep `/config` private and persistent; it contains the generated MCP Bearer token as well as tunnel/MCPX state. Never commit tunnel/API/MCPX credentials.
- Treat write access to `/workspace` as real developer access: keep source control and backups available for anything important.
- If multiple users share the tunnel, or the mounted project contains sensitive material, replace `/config/mcpx/config.yaml` with a restrictive policy before exposing the connector.

The bundled default is optimized for a dedicated development container where `/workspace` is the deliberate trust boundary. It is not a production sandbox for arbitrary host files.
