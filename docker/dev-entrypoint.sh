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
: "${RUSTMCP_HARBOR_MCP_TOKEN_FILE:=/config/secrets/mcpx-bearer-token}"
: "${RUSTMCP_HARBOR_LEGACY_MCPX_CONFIG_SHA256:=76674a5f18ebdab8d08c96ca30599375673030126f910a1443f2c2a0cb94de98}"

umask 077
mkdir -p "${MCPX_HOME}" "${TUNNEL_CLIENT_PROFILE_DIR}" "${TUNNEL_CLIENT_STATE_DIR}" /config/secrets
chmod 0700 /config/secrets 2>/dev/null || true

tunnel_requested=0
if [[ -n "${TUNNEL_CLIENT_CONFIG:-}" \
   || -n "${TUNNEL_CLIENT_PROFILE:-}" \
   || -n "${TUNNEL_CLIENT_PROFILE_FILE:-}" \
   || -f /config/tunnel/profile.yaml \
   || ( -n "${CONTROL_PLANE_TUNNEL_ID:-}" && -n "${CONTROL_PLANE_API_KEY:-}" ) ]]; then
    tunnel_requested=1
fi

generate_bearer_token() {
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}

persist_bearer_token() {
    local token="$1"
    printf '%s\n' "${token}" > "${RUSTMCP_HARBOR_MCP_TOKEN_FILE}"
    chmod 0600 "${RUSTMCP_HARBOR_MCP_TOKEN_FILE}" 2>/dev/null || true
}

render_default_mcpx_config() {
    local token="$1"
    local line
    local tmp="${MCPX_HOME}/config.yaml.tmp.$$"

    : > "${tmp}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line//__RUSTMCP_HARBOR_BEARER_TOKEN__/${token}}"
        printf '%s\n' "${line}" >> "${tmp}"
    done < "${RUSTMCP_HARBOR_DEFAULT_MCPX_CONFIG}"
    mv "${tmp}" "${MCPX_HOME}/config.yaml"
    chmod 0600 "${MCPX_HOME}/config.yaml" 2>/dev/null || true
}

read_managed_config_token() {
    local line
    local token=""
    while IFS= read -r line || [[ -n "${line}" ]]; do
        case "${line}" in
            '  token: "'*)
                token="${line#'  token: "'}"
                token="${token%\"}"
                printf '%s' "${token}"
                return 0
                ;;
        esac
    done < "${MCPX_HOME}/config.yaml"
    return 1
}

update_managed_config_token() {
    local token="$1"
    local line
    local replaced=0
    local tmp="${MCPX_HOME}/config.yaml.tmp.$$"

    : > "${tmp}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if (( replaced == 0 )) && [[ "${line}" == '  token: "'* ]]; then
            printf '  token: "%s"\n' "${token}" >> "${tmp}"
            replaced=1
        else
            printf '%s\n' "${line}" >> "${tmp}"
        fi
    done < "${MCPX_HOME}/config.yaml"

    if (( replaced == 0 )); then
        rm -f "${tmp}"
        echo "Harbor-managed MCPX config is missing auth.token; refusing to rewrite it automatically." >&2
        return 1
    fi

    mv "${tmp}" "${MCPX_HOME}/config.yaml"
    chmod 0600 "${MCPX_HOME}/config.yaml" 2>/dev/null || true
}

harbor_managed_config=0
legacy_default_config=0
if [[ -f "${MCPX_HOME}/config.yaml" ]]; then
    if grep -Fq '# rustmcp-harbor-managed-config-v2' "${MCPX_HOME}/config.yaml"; then
        harbor_managed_config=1
    else
        config_sha256="$(sha256sum "${MCPX_HOME}/config.yaml" | cut -d ' ' -f 1)"
        if [[ "${config_sha256}" == "${RUSTMCP_HARBOR_LEGACY_MCPX_CONFIG_SHA256}" ]]; then
            legacy_default_config=1
        fi
    fi
fi

harbor_mcp_bearer_token=""

if [[ ! -f "${MCPX_HOME}/config.yaml" || ${legacy_default_config} -eq 1 ]]; then
    if (( tunnel_requested == 1 )); then
        if [[ -n "${MCPX_BEARER_TOKEN:-}" ]]; then
            harbor_mcp_bearer_token="${MCPX_BEARER_TOKEN}"
        elif [[ -s "${RUSTMCP_HARBOR_MCP_TOKEN_FILE}" ]]; then
            IFS= read -r harbor_mcp_bearer_token < "${RUSTMCP_HARBOR_MCP_TOKEN_FILE}"
        else
            harbor_mcp_bearer_token="$(generate_bearer_token)"
        fi

        if [[ -z "${harbor_mcp_bearer_token}" ]]; then
            echo "Failed to obtain a non-empty MCPX bearer token." >&2
            exit 65
        fi

        persist_bearer_token "${harbor_mcp_bearer_token}"
        render_default_mcpx_config "${harbor_mcp_bearer_token}"
        harbor_managed_config=1

        if (( legacy_default_config == 1 )); then
            echo "Migrated Harbor's legacy open MCPX default to bearer authentication." >&2
        else
            echo "No custom MCPX config mounted; installed Harbor's bearer-protected allow-all default." >&2
        fi
        echo "MCP bearer token is managed at ${RUSTMCP_HARBOR_MCP_TOKEN_FILE}." >&2
        echo "Override the default by mounting your own /config/mcpx/config.yaml before startup." >&2
    else
        cat >&2 <<EOF_CONFIG
MCPX config is not mounted.
Expected: ${MCPX_HOME}/config.yaml

RustMCP Harbor intentionally ships with no active MCPX configuration in /config.
A bundled bearer-protected allow-all template is available at:
  ${RUSTMCP_HARBOR_DEFAULT_MCPX_CONFIG}

For normal Secure MCP Tunnel startup, provide tunnel settings and Harbor will create
a persistent random MCP bearer token, install the template, and configure tunnel-client
to send that token automatically. Mount your own config to override the default.

RustMCP Harbor intentionally ships with no default MCPX configuration.
EOF_CONFIG
        exit 64
    fi
elif (( harbor_managed_config == 1 )); then
    if [[ -n "${MCPX_BEARER_TOKEN:-}" ]]; then
        harbor_mcp_bearer_token="${MCPX_BEARER_TOKEN}"
        update_managed_config_token "${harbor_mcp_bearer_token}"
        persist_bearer_token "${harbor_mcp_bearer_token}"
    else
        harbor_mcp_bearer_token="$(read_managed_config_token || true)"
        if [[ -z "${harbor_mcp_bearer_token}" ]]; then
            echo "Harbor-managed MCPX config does not contain a bearer token." >&2
            exit 65
        fi
        persist_bearer_token "${harbor_mcp_bearer_token}"
    fi
else
    # A custom MCPX config is authoritative. Only wire static bearer headers when
    # the user explicitly supplies the matching token through the environment.
    if [[ -n "${MCPX_BEARER_TOKEN:-}" ]]; then
        harbor_mcp_bearer_token="${MCPX_BEARER_TOKEN}"
    fi
fi

if [[ -n "${harbor_mcp_bearer_token}" ]]; then
    export RUSTMCP_HARBOR_MCP_AUTHORIZATION="Bearer ${harbor_mcp_bearer_token}"
    if [[ -z "${MCP_EXTRA_HEADERS:-}" ]]; then
        export MCP_EXTRA_HEADERS='Authorization: env:RUSTMCP_HARBOR_MCP_AUTHORIZATION'
    fi
    if [[ -z "${MCP_DISCOVERY_EXTRA_HEADERS:-}" ]]; then
        export MCP_DISCOVERY_EXTRA_HEADERS='Authorization: env:RUSTMCP_HARBOR_MCP_AUTHORIZATION'
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

# Best-effort listener readiness. tunnel-client performs its own authenticated
# discovery/initialize probe using MCP_DISCOVERY_EXTRA_HEADERS.
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
