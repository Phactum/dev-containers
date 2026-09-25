#!/usr/bin/env bash
#
# prune-base-images.sh â€” remove locally cached 'devcontainer-base:*' images
# that no existing workspace references anymore.
#
# spawn-workspace.sh/.ps1 pre-build a reusable base image per devcontainers-config.json
# (tag: devcontainer-base:<distro>-<hash>) and collapse each workspace's own
# Dockerfile down to "FROM <tag>". A tag becomes orphaned once every workspace
# that used it has been disposed, or once devcontainers-config.json changed and every
# remaining workspace now points at a newer tag. Those orphaned images just
# take up disk space (a few GB each) with no way to reach them from a running
# workspace, so this script finds and removes them.
#
# An image is considered STILL IN USE if any workspace under
# <workspaces-root>/<PROJECT_NAME>-* has a ".devcontainer/Dockerfile" whose
# "FROM" line names it. Everything else tagged "devcontainer-base:*" locally
# is offered for removal.
#
# Usage:
#   prune-base-images.sh [--config <path>] [--workspaces-root <path>] [--yes]
#
set -euo pipefail

SCRIPT_SOURCE="$0"
while [[ -L "${SCRIPT_SOURCE}" ]]; do
    _link_dir="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
    SCRIPT_SOURCE="$(readlink "${SCRIPT_SOURCE}")"
    [[ "${SCRIPT_SOURCE}" != /* ]] && SCRIPT_SOURCE="${_link_dir}/${SCRIPT_SOURCE}"
done
SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"

WORKSPACES_ROOT_CLI=""
CONFIG_CLI=""
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            [[ $# -lt 2 ]] && { echo "--config needs an argument" >&2; exit 2; }
            CONFIG_CLI="${2-}"
            shift 2
            ;;
        --config=*)
            CONFIG_CLI="${1#--config=}"
            shift
            ;;
        --workspaces-root)
            WORKSPACES_ROOT_CLI="${2-}"
            [[ $# -lt 2 ]] && { echo "--workspaces-root needs an argument" >&2; exit 2; }
            shift 2
            ;;
        --workspaces-root=*)
            WORKSPACES_ROOT_CLI="${1#--workspaces-root=}"
            shift
            ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) echo "unexpected argument: $1" >&2; exit 2 ;;
    esac
done

if ! command -v docker >/dev/null 2>&1; then
    echo "docker not on PATH" >&2
    exit 1
fi

DEFAULT_CONFIG_RELS=("dev-containers/devcontainers-config.json" "devcontainers-config.json")
if [[ -n "${CONFIG_CLI}" ]]; then
    if [[ -d "${CONFIG_CLI}" ]]; then
        CONFIG_JSON="${CONFIG_CLI%/}/devcontainers-config.json"
    else
        CONFIG_JSON="${CONFIG_CLI}"
    fi
    if [[ ! -f "${CONFIG_JSON}" ]]; then
        echo "Project config not found: ${CONFIG_JSON}" >&2
        exit 1
    fi
else
    CONFIG_JSON=""
    for _rel in "${DEFAULT_CONFIG_RELS[@]}"; do
        if [[ -f "${PWD}/${_rel}" ]]; then
            CONFIG_JSON="${PWD}/${_rel}"
            break
        fi
    done
    if [[ -z "${CONFIG_JSON}" ]]; then
        echo "Project config not found. Looked for:" >&2
        for _rel in "${DEFAULT_CONFIG_RELS[@]}"; do
            echo "  ${PWD}/${_rel}" >&2
        done
        echo "Run the command from the project directory, or point at a config" >&2
        echo "with --config <path-to-devcontainers-config.json|dir>." >&2
        exit 1
    fi
fi
CONFIG_DIR="$(cd -P "$(dirname "${CONFIG_JSON}")" && pwd)"
CONFIG_JSON="${CONFIG_DIR}/$(basename "${CONFIG_JSON}")"

ENV_CONFIG="${SCRIPT_DIR}/env-config.sh"
if [[ ! -f "${ENV_CONFIG}" ]]; then
    echo "Config loader not found: ${ENV_CONFIG}" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${ENV_CONFIG}"

ENV_VAR_WORKSPACES_ROOT="$(echo "${PROJECT_SHORT}" | tr '[:lower:]' '[:upper:]')_WORKSPACES_ROOT"
WORKSPACES_ROOT="$(resolve_workspaces_root "${WORKSPACES_ROOT_CLI}")" || exit 1

# Every workspace directory's own Dockerfile still names the tag it was built
# from ("FROM devcontainer-base:..."), even after the heavy install steps were
# collapsed away -- so scanning those FROM lines is a complete and exact
# in-use set, no guessing needed.
declare -A REFERENCED=()
if [[ -d "${WORKSPACES_ROOT}" ]]; then
    for ws in "${WORKSPACES_ROOT}/${PROJECT_NAME}"-*; do
        [[ -d "${ws}" ]] || continue
        dockerfile="${ws}/.devcontainer/Dockerfile"
        [[ -f "${dockerfile}" ]] || continue
        tag="$(grep -m1 -oE '^\s*FROM\s+devcontainer-base:\S+' "${dockerfile}" | awk '{print $2}')"
        [[ -n "${tag}" ]] && REFERENCED["${tag}"]=1
    done
fi

mapfile -t ALL_LINES < <(docker images --filter 'reference=devcontainer-base' --format '{{.Repository}}:{{.Tag}}|{{.Size}}|{{.ID}}')

echo "workspaces root:  ${WORKSPACES_ROOT}"
if (( ${#REFERENCED[@]} > 0 )); then
    echo "in-use tags:      ${!REFERENCED[*]}"
else
    echo "in-use tags:      <none>"
fi
echo ""

if (( ${#ALL_LINES[@]} == 0 )); then
    echo "no devcontainer-base images found locally -- nothing to prune"
    exit 0
fi

ORPHANED_TAGS=()
ORPHANED_IDS=()
ORPHANED_SIZES=()
for line in "${ALL_LINES[@]}"; do
    IFS='|' read -r tag size id <<< "${line}"
    if [[ -z "${REFERENCED[${tag}]+x}" ]]; then
        ORPHANED_TAGS+=("${tag}")
        ORPHANED_IDS+=("${id}")
        ORPHANED_SIZES+=("${size}")
    fi
done

if (( ${#ORPHANED_TAGS[@]} == 0 )); then
    echo "no orphaned devcontainer-base images -- nothing to prune"
    exit 0
fi

echo "orphaned (no workspace references these anymore):"
for i in "${!ORPHANED_TAGS[@]}"; do
    echo "  ${ORPHANED_TAGS[$i]}  (${ORPHANED_SIZES[$i]})"
done
echo ""

if (( ASSUME_YES == 0 )); then
    read -r -p "remove ${#ORPHANED_TAGS[@]} image(s)? [y/N] " reply
    if [[ ! "${reply}" =~ ^[Yy] ]]; then
        echo "aborted"
        exit 0
    fi
fi

for i in "${!ORPHANED_TAGS[@]}"; do
    echo "removing ${ORPHANED_TAGS[$i]}..."
    if ! docker rmi "${ORPHANED_IDS[$i]}" 2>&1; then
        echo "  not removed (still in use by a container, or another tag points at the same layers)"
    fi
done
