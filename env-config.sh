#!/usr/bin/env bash
#
# env-config.sh — loads a project's devcontainers-config.json and exposes it as
# the shell variables that spawn-workspace.sh and dispose-workspace.sh consume.
#
# Sourced (not executed) by both scripts, after they have resolved which config
# to read:
#     CONFIG_JSON=/path/to/devcontainers-config.json
#     source "${SCRIPT_DIR}/env-config.sh"
#
# devcontainers-config.json is the single source of truth for project
# configuration and is
# shared with the PowerShell ports (spawn-workspace.ps1 / dispose-workspace.ps1,
# which read it via EnvConfig.ps1). It is JSON with full-line "//" comments;
# those lines are stripped here before jq sees the document.
#
# Variables set by this file:
#   PROJECT_NAME PROJECT_SHORT BASE_IMAGE NODE_FEATURE_VERSION
#   DISTRO JAVA_VERSION MAVEN_VERSION
#   GLAB_VERSION GLAB_HOSTNAME GH_VERSION PORT_OFFSET_STEP TERMINAL_SHELL
#   REPOS[]              "<name>:<baseRef>"
#   HOST_PORTS[]         port numbers
#   PORT_LABELS[]        "<port>:<label>"
#   RUN_CONFIGS[]        run-config XML filenames
#   FORWARDED_ENV_VARS[] env var names
#   BUILDS[]             "<repo>:<type>:<value>"  type = mvn|cmd
#   BUILDS_DEFINED       1 if the "builds" key is present in the config, else 0
#
# Each "builds" entry carries exactly one of "mvn-goal" (type=mvn, run as
# `mvn ${MVN_FLAGS} <value>`) or "command" (type=cmd, run verbatim inside the
# repo). The value may itself contain ':' (e.g. a URL), so only the repo and the
# type are split off at use sites. BUILDS_DEFINED lets spawn-workspace.sh tell
# "no builds key" (mono-repo auto-build applies) from "builds": [] (warmup
# builds disabled on purpose).

# The caller normally sets CONFIG_JSON. Falling back to a devcontainers-config.json
# next to this file keeps the loader usable stand-alone (e.g. for debugging).
if [[ -z "${CONFIG_JSON:-}" ]]; then
    _ENV_CONFIG_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CONFIG_JSON="${_ENV_CONFIG_DIR}/devcontainers-config.json"
fi
ENV_JSON="${CONFIG_JSON}"

if [[ ! -f "${ENV_JSON}" ]]; then
    echo "Project config not found: ${ENV_JSON}" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to read ${ENV_JSON} but was not found on PATH." >&2
    echo "Install it with 'brew install jq' (macOS) or 'apt-get install jq' (Debian/Ubuntu)." >&2
    exit 1
fi

# Strip full-line "//" comments. Deliberately anchored to the start of the line
# (leading whitespace allowed) so that "//" inside a string value — a URL, for
# instance — is left untouched.
_env_json_stripped() {
    sed -e 's|^[[:space:]]*//.*$||' "${ENV_JSON}"
}

if ! _env_json_stripped | jq -e . >/dev/null 2>&1; then
    echo "Project config is not valid JSON: ${ENV_JSON}" >&2
    echo "(Note: only full-line '//' comments are supported, no trailing comments.)" >&2
    _env_json_stripped | jq . >/dev/null
    exit 1
fi

# Scalars. jq's // operator supplies the default for both a missing key and an
# explicit null; `// empty` would drop the assignment entirely, so we use "".
_env_scalar() {
    _env_json_stripped | jq -r "(${1}) // \"\" | tostring"
}

# Booleans need their own reader. Neither jq's `//` nor the `// ""` fallback in
# _env_scalar can be used for them: both yield the right-hand operand when the
# left one is null OR FALSE, so an explicit `false` in the config would silently
# come back as the default. Test for null explicitly instead.
#   $1 = jq path expression, $2 = default (true|false)
_env_bool() {
    _env_json_stripped | jq -r "if (${1}) == null then ${2} else ((${1}) | tostring) end"
}

PROJECT_NAME="$(_env_scalar '.projectName')"
PROJECT_SHORT="$(_env_scalar '.projectShort')"
BASE_IMAGE="$(_env_scalar '.baseImage')"
NODE_FEATURE_VERSION="$(_env_scalar '.nodeFeatureVersion')"
GLAB_VERSION="$(_env_scalar '.glabVersion')"
GLAB_HOSTNAME="$(_env_scalar '.glabHostname')"
GH_VERSION="$(_env_scalar '.ghVersion')"
PORT_OFFSET_STEP="$(_env_scalar '.portOffsetStep // 10000')"
TERMINAL_SHELL="$(_env_scalar '.terminalShell')"
WORKSPACES_ROOT_CONFIG="$(_env_scalar '.workspacesRoot')"

# Corporate proxy / TLS interception. All optional; empty means "not behind a
# proxy" and every downstream block is omitted from the generated files.
PROXY_HTTP="$(_env_scalar '.proxy.http')"
PROXY_HTTPS="$(_env_scalar '.proxy.https')"
PROXY_NO="$(_env_scalar '.proxy.noProxy')"
PROXY_DEBIAN_HTTPS="$(_env_bool '.proxy.debianUseHttps' false)"
# Distro-neutral alias, wins when present (apt sources on Debian, dnf repo
# baseurls on the RHEL-family images the PowerShell scripts can build).
PROXY_DEBIAN_HTTPS="$(_env_bool '.proxy.useHttpsRepos' "${PROXY_DEBIAN_HTTPS}")"

# Registry the devcontainer features come from, and the optional image build
# steps. Defaults keep the previous behaviour exactly.
FEATURE_REGISTRY="$(_env_scalar '.featureRegistry // "ghcr.io"')"
IMAGE_APT_PACKAGES="$(_env_bool '.imageBuild.aptPackages' true)"
# Distro-neutral alias for the same switch.
IMAGE_APT_PACKAGES="$(_env_bool '.imageBuild.packages' "${IMAGE_APT_PACKAGES}")"
IMAGE_RECENT_GIT="$(_env_bool '.imageBuild.recentGit' true)"
IMAGE_CHROMIUM="$(_env_bool '.imageBuild.chromium' true)"

for _required in PROJECT_NAME PROJECT_SHORT BASE_IMAGE NODE_FEATURE_VERSION; do
    if [[ -z "${!_required}" ]]; then
        echo "Missing required setting in ${ENV_JSON}: ${_required}" >&2
        exit 1
    fi
done

# Package-manager family of the base image. "rocky" covers every
# RHEL-compatible base (Rocky, Alma, CentOS Stream, RHEL/UBI): they all use dnf
# and share the same paths. It switches the generated Dockerfile from apt-get
# to dnf and installs the toolchain (JDK, Maven, Node, docker) directly,
# because the devcontainer features only support Debian/Ubuntu.
DISTRO="$(_env_scalar '.distro // "debian"')"
DISTRO="$(printf '%s' "${DISTRO}" | tr '[:upper:]' '[:lower:]')"
if [[ "${DISTRO}" != "debian" && "${DISTRO}" != "rocky" ]]; then
    echo "Invalid 'distro' in ${ENV_JSON}: '${DISTRO}' (expected 'debian' or 'rocky')" >&2
    exit 1
fi

# Rocky only: JDK major version (dnf package java-<n>-openjdk-devel) and the
# Apache Maven version installed from the binary tarball. Ignored on Debian,
# where the java:1 feature provides Maven and the base image the JDK.
JAVA_VERSION="$(_env_scalar '.javaVersion // "21"')"
MAVEN_VERSION="$(_env_scalar '.mavenVersion // "3.9.9"')"

# Arrays. Read NUL-separated so values containing spaces (build commands, port
# labels) survive intact, and so an empty list yields an empty array rather
# than a single empty element. bash 3.2 has no namerefs, so each array is
# filled by a read loop in this scope over a NUL-separated jq stream.
_env_records() {
    _env_json_stripped | jq -j "${1}"' | . + "\u0000"'
}

REPOS=()
while IFS= read -r -d '' _rec; do
    REPOS+=("${_rec}")
done < <(_env_records '(.repos // [])[] | "\(.name):\(.baseRef // "")"')

HOST_PORTS=()
while IFS= read -r -d '' _rec; do
    HOST_PORTS+=("${_rec}")
done < <(_env_records '(.hostPorts // [])[] | (.port | tostring)')

PORT_LABELS=()
while IFS= read -r -d '' _rec; do
    PORT_LABELS+=("${_rec}")
done < <(_env_records '(.hostPorts // [])[] | select((.label // "") != "") | "\(.port):\(.label)"')

RUN_CONFIGS=()
while IFS= read -r -d '' _rec; do
    RUN_CONFIGS+=("${_rec}")
done < <(_env_records '(.runConfigs // [])[]')

FORWARDED_ENV_VARS=()
while IFS= read -r -d '' _rec; do
    FORWARDED_ENV_VARS+=("${_rec}")
done < <(_env_records '(.forwardedEnvVars // [])[]')

# CA certificates to install into the image (paths, relative to the config dir).
PROXY_CA_CERTS=()
while IFS= read -r -d '' _rec; do
    PROXY_CA_CERTS+=("${_rec}")
done < <(_env_records '(.proxy.caCertificates // [])[]')

# Build list: a single "builds" array whose entries each carry exactly one of
# "mvn-goal" or "command". Normalise every entry to "<repo>:<type>:<value>"
# (type = mvn|cmd) and fail loudly on any entry that sets both or neither.
# BUILDS_DEFINED records whether the key was present at all -- an explicit
# "builds": [] disables warmup builds without triggering the mono-repo auto-build.
BUILDS=()
BUILDS_DEFINED=0
if _env_json_stripped | jq -e 'has("builds")' >/dev/null; then
    BUILDS_DEFINED=1
    _bad="$(_env_json_stripped | jq -r '
        (.builds // []) | to_entries[]
        | select(((.value | has("mvn-goal")) and (.value | has("command")))
                 or ((.value | has("mvn-goal") | not) and (.value | has("command") | not)))
        | "  entry #\(.key) (repo=\(.value.repo // "?")): set exactly one of \"mvn-goal\" / \"command\""')"
    if [[ -n "${_bad}" ]]; then
        echo "ERROR: invalid \"builds\" entries in ${CONFIG_JSON}:" >&2
        printf '%s\n' "${_bad}" >&2
        exit 1
    fi
    while IFS= read -r -d '' _rec; do
        BUILDS+=("${_rec}")
    done < <(_env_records '(.builds // [])[] | if has("mvn-goal") then "\(.repo):mvn:\(.["mvn-goal"])" else "\(.repo):cmd:\(.command)" end')
fi

unset _rec _required

# ---------------------------------------------------------------------------
# Workspaces-root resolution, shared by spawn and dispose so both always agree.
#
# Priority:
#   1. $1                          --workspaces-root CLI flag
#   2. ${ENV_VAR_WORKSPACES_ROOT}  environment variable
#   3. "workspacesRoot"            in devcontainers-config.json (relative paths
#                                  resolve against the config's own directory)
#   4. auto-detect from the config location (see below)
#
# Auto-detect walks up from CONFIG_DIR looking for the directory named
# PROJECT_NAME -- that is the source workspace, so its parent is the workspaces
# root. This makes both supported layouts work without any configuration:
#     <root>/<PROJECT_NAME>/dev-containers/devcontainers-config.json   (config in a subdir)
#     <root>/<PROJECT_NAME>/devcontainers-config.json                  (config in the project root)
# If no such directory is found (the project directory has a different name),
# it falls back to two levels above CONFIG_DIR, the historical behaviour.
#
# Echoes the resolved absolute path; the caller assigns it.
# ---------------------------------------------------------------------------
resolve_workspaces_root() {
    local cli="${1:-}"
    local from_env="${!ENV_VAR_WORKSPACES_ROOT:-}"
    local candidate=""

    if [[ -n "${cli}" ]]; then
        candidate="${cli}"
    elif [[ -n "${from_env}" ]]; then
        candidate="${from_env}"
    elif [[ -n "${WORKSPACES_ROOT_CONFIG}" ]]; then
        candidate="${WORKSPACES_ROOT_CONFIG}"
        # A relative path in devcontainers-config.json is relative to the config itself, so a
        # project can commit e.g. "workspacesRoot": ".." and stay portable.
        [[ "${candidate}" != /* ]] && candidate="${CONFIG_DIR}/${candidate}"
    else
        local dir="${CONFIG_DIR}"
        local i
        for i in 1 2 3; do
            if [[ "$(basename "${dir}")" == "${PROJECT_NAME}" ]]; then
                candidate="${dir}/.."
                break
            fi
            dir="$(dirname "${dir}")"
            [[ "${dir}" == "/" ]] && break
        done
        # Fallback: the historical "two levels above the config" rule.
        [[ -z "${candidate}" ]] && candidate="${CONFIG_DIR}/../.."
    fi

    if [[ ! -d "${candidate}" ]]; then
        echo "Workspaces root does not exist: ${candidate}" >&2
        echo "Set \"workspacesRoot\" in ${ENV_JSON}, pass --workspaces-root <path>," >&2
        echo "or set \$${ENV_VAR_WORKSPACES_ROOT}." >&2
        # `return`, not `exit`: this function runs inside a command
        # substitution, where exit would only end the subshell and leave the
        # caller running with an empty value. Callers append `|| exit 1`.
        return 1
    fi
    # Canonicalise: bind-mount paths in devcontainer.json must be absolute, and
    # path comparisons must not depend on how the user spelled the argument.
    ( cd "${candidate}" && pwd )
}
