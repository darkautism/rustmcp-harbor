#!/usr/bin/env bash
set -Eeuo pipefail

print_versions() {
    rustc --version
    cargo --version
    mcpx -version
    tunnel-client --version
    cloudflared --version
}

if [[ "${1:-}" == "versions" ]]; then
    print_versions
    exit 0
fi

# Explicit commands turn the image into an ordinary Rust development shell/job.
if (( $# > 0 )); then
    exec "$@"
fi

: "${MCPX_HOME:=/config/mcpx}"
: "${TUNNEL_CLIENT_PROFILE_DIR:=/config/tunnel}"
: "${TUNNEL_CLIENT_STATE_DIR:=/config/tunnel/state}"
: "${MCP_SERVER_URL:=http://127.0.0.1:9090/mcp}"
: "${RUSTMCP_HARBOR_DEFAULT_MCPX_CONFIG:=/usr/share/rustmcp-harbor/default-mcpx-config.yaml}"

mkdir -p "${MCPX_HOME}" "${TUNNEL_CLIENT_PROFILE_DIR}" "${TUNNEL_CLIENT_STATE_DIR}"

tunnel_requested=0
if [[ -n "${TUNNEL_CLIENT_CONFIG:-}" \
   || -n "${TUNNEL_CLIENT_PROFILE:-}" \
   || -n "${TUNNEL_CLIENT_PROFILE_FILE:-}" \
   || -f /config/tunnel/profile.yaml \
   || ( -n "${CONTROL_PLANE_TUNNEL_ID:-}" && -n "${CONTROL_PLANE_API_KEY:-}" ) ]]; then
    tunnel_requested=1
fi

if [[ ! -f "${MCPX_HOME}/config.yaml" ]]; then
    if (( tunnel_requested == 1 )); then
        install -m 0644 "${RUSTMCP_HARBOR_DEFAULT_MCPX_CONFIG}" "${MCPX_HOME}/config.yaml"
        echo "No custom MCPX config mounted; installed Harbor's allow-all default at ${MCPX_HOME}/config.yaml." >&2
        echo "Override it by mounting your own /config/mcpx/config.yaml before startup." >&2
    else
        cat >&2 <<EOF_CONFIG
MCPX config is not mounted.
Expected: ${MCPX_HOME}/config.yaml

RustMCP Harbor intentionally ships with no default MCPX configuration.
No active config exists in /config for this no-tunnel startup. A bundled allow-all
template is available at:
  ${RUSTMCP_HARBOR_DEFAULT_MCPX_CONFIG}

For normal Secure MCP Tunnel startup, provide tunnel settings and Harbor will copy
that template to /config/mcpx/config.yaml automatically. Mount your own config there
to override the default.
EOF_CONFIG
        exit 64
    fi
fi

cd /workspace

children=()
cleanup() {
    local pid
    trap - EXIT INT TERM
    for pid in "${children[@]:-}"; do
        if kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
    done
    for pid in "${children[@]:-}"; do
        wait "${pid}" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

mcpx &
mcpx_pid=$!
children+=("${mcpx_pid}")

# Best-effort MCPX readiness. 401/405 still prove that the HTTP listener exists.
ready=0
for _ in $(seq 1 30); do
    if ! kill -0 "${mcpx_pid}" 2>/dev/null; then
        wait "${mcpx_pid}"
        exit $?
    fi
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 1 \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"rustmcp-harbor","version":"1"}}}' \
        "${MCP_SERVER_URL}" 2>/dev/null || true)"
    if [[ -n "${http_code}" && "${http_code}" != "000" ]]; then
        ready=1
        break
    fi
    sleep 1
done
if (( ready == 0 )); then
    echo "warning: MCPX readiness probe did not receive HTTP from ${MCP_SERVER_URL}; continuing" >&2
fi

# Simplest mounted-config convention. Native tunnel-client env/profile controls
# continue to work for users who need a different layout.
if [[ -z "${TUNNEL_CLIENT_CONFIG:-}" \
   && -z "${TUNNEL_CLIENT_PROFILE:-}" \
   && -z "${TUNNEL_CLIENT_PROFILE_FILE:-}" \
   && -f /config/tunnel/profile.yaml ]]; then
    export TUNNEL_CLIENT_PROFILE_FILE=/config/tunnel/profile.yaml
fi

if [[ -n "${TUNNEL_CLIENT_CONFIG:-}" \
   || -n "${TUNNEL_CLIENT_PROFILE:-}" \
   || -n "${TUNNEL_CLIENT_PROFILE_FILE:-}" \
   || ( -n "${CONTROL_PLANE_TUNNEL_ID:-}" && -n "${CONTROL_PLANE_API_KEY:-}" ) ]]; then
    tunnel-client run &
    tunnel_pid=$!
    children+=("${tunnel_pid}")

    set +e
    wait -n "${mcpx_pid}" "${tunnel_pid}"
    status=$?
    set -e
    exit "${status}"
fi

echo "MCPX started without Secure MCP Tunnel." >&2
echo "Mount /config/tunnel/profile.yaml or provide tunnel-client environment settings to enable it." >&2

set +e
wait "${mcpx_pid}"
status=$?
set -e
exit "${status}"
