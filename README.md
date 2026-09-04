# RustMCP Harbor

A project-independent, TrueNAS-friendly Rust development container with:

- current Rust stable (`rust:latest`)
- current `opentokenz/mcpx` default branch
- current `openai/tunnel-client` default branch
- the tunnel-client Cloudflare companion
- Git, Clang/LLD, CMake, pkg-config, tmux, jq, SSH client, and common Linux libraries used by Rust/Bevy development

It is designed to let ChatGPT/Codex reach an MCPX-managed project through OpenAI Secure MCP Tunnel while keeping the project itself on a NAS or other Linux container host.

The image contains **no project**, **no MCPX configuration**, and **no credentials**.

## Image

The included GitHub Actions workflow publishes:

```text
ghcr.io/<github-owner>/rustmcp-harbor:latest
ghcr.io/<github-owner>/rustmcp-harbor:weekly-YYYYMMDD
ghcr.io/<github-owner>/rustmcp-harbor:sha-...
```

The workflow runs every Monday and can be started manually. Each scheduled build uses `--pull` and `--no-cache`, reclones MCPX and tunnel-client, builds `linux/amd64` + `linux/arm64`, publishes the image to GHCR, then smoke-tests both architectures under QEMU.

## Runtime layout

Only two persistent mounts are needed:

| Host data | Container | Purpose |
| --- | --- | --- |
| project checkout | `/workspace` | project being developed |
| private Harbor state/config | `/config` | MCPX, tunnel-client, Cargo cache, secrets |

RustMCP Harbor defaults to non-root UID/GID `568:568` for TrueNAS-oriented deployments.

Do **not** enable privileged mode. Do **not** mount `/dev`, the Docker socket, or host networking just for Secure MCP Tunnel.

## Configuration

No default configuration is generated or baked into the image.

MCPX expects your mounted global config at:

```text
/config/mcpx/config.yaml
```

Point the MCPX workspace in that config at `/workspace`.

For tunnel-client, the simplest mounted-file convention is:

```text
/config/tunnel/profile.yaml
```

The entrypoint detects that file automatically. Native tunnel-client environment variables and named profiles also continue to work.

Persistent native tunnel-client runtime state is stored under:

```text
/config/tunnel/state
```

For secrets, prefer environment references or file references. A convenient private location is:

```text
/config/secrets/
```

Do not commit `/config`.

## TrueNAS SCALE

Create a Custom App using:

```text
ghcr.io/<github-owner>/rustmcp-harbor:latest
```

Configure two Host Path mounts:

```text
<project dataset>       -> /workspace
<private config dataset> -> /config
```

Give the app identity read/write access to those datasets. The image defaults to UID/GID `568:568`.

Normal Secure MCP Tunnel operation is outbound-only, so no host port needs to be published. The image declares 9090 (MCPX) and 8080 (tunnel health/UI) only as metadata for deployments that intentionally expose them.

After a new weekly image is published, TrueNAS still needs to pull/redeploy `latest` (or switch to the new dated tag) before an already-running app uses the new build.

## Rust version behavior

The image sets:

```text
RUSTUP_TOOLCHAIN=stable
```

so mounted projects use the current stable toolchain shipped in that week's image, even if a project contains a `rust-toolchain.toml` pin.

If a particular project must honor its own pinned toolchain, unset `RUSTUP_TOOLCHAIN` for that deployment.

## Use as a development shell/job

Any explicit command bypasses MCPX/tunnel orchestration:

```bash
docker run --rm -it \
  -v /path/to/project:/workspace \
  -v /path/to/harbor-config:/config \
  ghcr.io/<github-owner>/rustmcp-harbor:latest \
  bash
```

Print bundled tool versions:

```bash
docker run --rm ghcr.io/<github-owner>/rustmcp-harbor:latest versions
```

## Repository bootstrap

This directory is intended to be its own Git repository:

```bash
git init
git add .
git commit -m "Initial RustMCP Harbor"
git branch -M main
git remote add origin <your-github-repo-url>
git push -u origin main
```
