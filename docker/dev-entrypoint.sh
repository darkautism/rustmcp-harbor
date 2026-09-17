#!/usr/bin/env bash
set -Eeuo pipefail

print_versions() {
    mcpx -version
    git --version
    gh --version | head -n 1
    rg --version | head -n 1
    jq --version
}

if [[ "${1:-}" == "versions" ]]; then
    print_versions
    exit 0
fi

# Explicit commands turn the image into an ordinary development shell/job.
if (( $# > 0 )); then
    exec "$@"
fi

: "${MCPX_HOME:=/root/.mcpx}"
: "${MCPX_HARBOR_DEFAULT_CONFIG:=/usr/share/mcpx-harbor/default-mcpx-config.yaml}"

umask 077
mkdir -p "${MCPX_HOME}"

# Escape a value that is substituted inside a YAML double-quoted scalar.
yaml_double_quote_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "${value}"
}

render_default_mcpx_config() {
    local bind_host="${MCPX_BIND_HOST:-0.0.0.0}"
    local oauth_password="${MCPX_OAUTH_PASSWORD:-}"
    local server_url="${MCPX_SERVER_URL:-}"
    local escaped_bind_host
    local escaped_oauth_password
    local escaped_server_url
    local line
    local tmp="${MCPX_HOME}/config.yaml.tmp.$$"

    if grep -Fq '__OAUTH__' "${MCPX_HARBOR_DEFAULT_CONFIG}" \
       && [[ -z "${oauth_password}" ]]; then
        echo "MCPX_OAUTH_PASSWORD is required by the bundled MCPX config template." >&2
        return 64
    fi
    if grep -Fq '__HOSTNAME__' "${MCPX_HARBOR_DEFAULT_CONFIG}" \
       && [[ -z "${server_url}" ]]; then
        echo "MCPX_SERVER_URL is required by the bundled MCPX config template (for example https://kpc.myvnc.com)." >&2
        return 64
    fi

    escaped_bind_host="$(yaml_double_quote_escape "${bind_host}")"
    escaped_oauth_password="$(yaml_double_quote_escape "${oauth_password}")"
    escaped_server_url="$(yaml_double_quote_escape "${server_url}")"

    : > "${tmp}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line//__HOST_IP__/${escaped_bind_host}}"
        line="${line//__OAUTH__/${escaped_oauth_password}}"
        line="${line//__HOSTNAME__/${escaped_server_url}}"
        printf '%s\n' "${line}" >> "${tmp}"
    done < "${MCPX_HARBOR_DEFAULT_CONFIG}"

    mv "${tmp}" "${MCPX_HOME}/config.yaml"
    chmod 0600 "${MCPX_HOME}/config.yaml" 2>/dev/null || true
}

write_literal_mcpx_config() {
    local tmp="${MCPX_HOME}/config.yaml.tmp.$$"
    printf '%s\n' "${MCPX_CONFIG}" > "${tmp}"
    mv "${tmp}" "${MCPX_HOME}/config.yaml"
    chmod 0600 "${MCPX_HOME}/config.yaml" 2>/dev/null || true
}

# MCPX_CONFIG is authoritative when supplied. Otherwise the three template
# environment variables re-render the bundled config on each container start.
# With no environment override, an existing /root/.mcpx/config.yaml is kept.
if [[ -n "${MCPX_CONFIG:-}" ]]; then
    write_literal_mcpx_config
elif [[ -n "${MCPX_BIND_HOST:-}" \
     || -n "${MCPX_OAUTH_PASSWORD:-}" \
     || -n "${MCPX_SERVER_URL:-}" ]]; then
    render_default_mcpx_config
elif [[ ! -f "${MCPX_HOME}/config.yaml" ]]; then
    render_default_mcpx_config
fi

if [[ ! -s "${MCPX_HOME}/config.yaml" ]]; then
    echo "MCPX config is missing or empty: ${MCPX_HOME}/config.yaml" >&2
    exit 64
fi

cd /workspace
exec mcpx
