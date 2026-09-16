#!/usr/bin/env bash
#
# dispose-workspace.sh — remove a story workspace and clean up its git worktrees.
#
# Usage:
#   dispose-workspace.sh [--config <path>] [--workspaces-root <path>] [--force] [--delete-branch] [--keep-container] [--keep-image] [--yes] <target>
#
# <target> accepts any of:
#   feature/FLOW-4711_example-story   full branch name
#   FLOW-4711_example-story           branch leaf
#   <PROJECT_NAME>-FLOW-4711_foo      workspace directory name
#   <PROJECT_SHORT>-FLOW-4711_foo     Docker container name
#   a3f2b1c4d5e6                      Docker container ID (hex, ≥12 chars)
#
# When a container name or ID is given the script resolves the workspace from
# the container name (which embeds the branch leaf) without needing the branch.
#
# Examples:
#   dispose-workspace.sh feature/FLOW-4711_example-story
#   dispose-workspace.sh <PROJECT_SHORT>-FLOW-4711_example-story
#   dispose-workspace.sh a3f2b1c4d5e6
#   dispose-workspace.sh --force --delete-branch feature/FLOW-4711_example-story
#   dispose-workspace.sh --config ~/work/myproject/dev-containers/devcontainers-config.json feature/FLOW-4711_example
#   dispose-workspace.sh --workspaces-root /opt/dev feature/FLOW-4711_example
#   VANILLABP_WORKSPACES_ROOT=/opt/dev dispose-workspace.sh feature/FLOW-4711_example
#
# INSTALLATION
#   Clone this directory ONCE and put it on your PATH (see spawn-workspace.sh's
#   header). Per-project settings live in that project's own devcontainers-config.json.
#
# The devcontainers-config.json is located in this order:
#   1. --config <path>   file, or a directory containing devcontainers-config.json
#   2. ./dev-containers/devcontainers-config.json, relative to the CURRENT WORKING DIRECTORY
#   3. ./devcontainers-config.json,                relative to the CURRENT WORKING DIRECTORY
#
# The <workspaces-root> directory is resolved in this order:
#   1. --workspaces-root <path>     CLI flag (highest priority)
#   2. $<PROJECT_SHORT>_WORKSPACES_ROOT env var (e.g. VANILLABP_WORKSPACES_ROOT)
#   3. "workspacesRoot" in devcontainers-config.json (relative to the config's directory)
#   4. auto-detect: walk up from the config's directory to the directory named
#      <PROJECT_NAME> and take its parent; falling back to two levels up
# The script prints the resolved target directory and asks for confirmation
# before removing anything; pass --yes to skip the prompt.
#
# Project-specific values (projectName, projectShort, repos, ...) come from
# devcontainers-config.json. Point the scripts at another project's devcontainers-config.json to retarget.
#
# By default this:
#   - refuses to remove worktrees with uncommitted changes (use --force to override)
#   - keeps the branch (use --delete-branch to remove the local branch from each source repo)
#   - removes the Docker container '<PROJECT_SHORT>-<leaf>', all its named volumes, and
#     the devcontainer image (use --keep-container to skip all Docker cleanup, or
#     --keep-image to remove the container and volumes but keep the image layer cache)
#
set -euo pipefail

# Resolve the script's own directory, following symlinks -- a PATH install
# normally symlinks the script into /usr/local/bin, and the sibling loader
# (env-config.sh) has to be found next to the REAL file.
SCRIPT_SOURCE="$0"
while [[ -L "${SCRIPT_SOURCE}" ]]; do
    _link_dir="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
    SCRIPT_SOURCE="$(readlink "${SCRIPT_SOURCE}")"
    [[ "${SCRIPT_SOURCE}" != /* ]] && SCRIPT_SOURCE="${_link_dir}/${SCRIPT_SOURCE}"
done
SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"

FORCE=0
DELETE_BRANCH=0
KEEP_CONTAINER=0
KEEP_IMAGE=0
WORKSPACES_ROOT_CLI=""
CONFIG_CLI=""
ASSUME_YES=0
ARG=""

# Argument parsing runs BEFORE the project config is loaded, because --config
# decides which config to load in the first place.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)          FORCE=1; shift ;;
        --delete-branch)  DELETE_BRANCH=1; shift ;;
        --keep-container) KEEP_CONTAINER=1; shift ;;
        --keep-image)     KEEP_IMAGE=1; shift ;;
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
        -y|--yes)         ASSUME_YES=1; shift ;;
        -h|--help)        sed -n '2,51p' "$0"; exit 0 ;;
        --)               shift; ARG="${1:-}"; break ;;
        -*)               echo "unknown option: $1" >&2; exit 2 ;;
        *)                [[ -n "${ARG}" ]] && { echo "unexpected argument: $1" >&2; exit 2; }
                          ARG="$1"; shift ;;
    esac
done

if [[ -z "${ARG}" ]]; then
    echo "usage: $0 [--config <path>] [--workspaces-root <path>] [--force] [--delete-branch] [--keep-container] [--keep-image] [--yes] <target>" >&2
    exit 2
fi

# Locate the project config: --config (a file or a directory containing
# devcontainers-config.json), otherwise, relative to the CURRENT WORKING DIRECTORY,
# ./dev-containers/devcontainers-config.json and then ./devcontainers-config.json -- which is what makes one
# PATH-installed clone usable from every project.
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

# Load the project config (PROJECT_NAME, PROJECT_SHORT, REPOS, ...) through the
# shared env-config.sh loader, which lives next to this script.
ENV_CONFIG="${SCRIPT_DIR}/env-config.sh"
if [[ ! -f "${ENV_CONFIG}" ]]; then
    echo "Config loader not found: ${ENV_CONFIG}" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${ENV_CONFIG}"

ENV_VAR_WORKSPACES_ROOT="$(echo "${PROJECT_SHORT}" | tr '[:lower:]' '[:upper:]')_WORKSPACES_ROOT"

# Resolve the workspaces root. Priority (see resolve_workspaces_root in
# env-config.sh): --workspaces-root flag, ${ENV_VAR_WORKSPACES_ROOT} env var,
# "workspacesRoot" in devcontainers-config.json, then auto-detect from the config location.
WORKSPACES_ROOT="$(resolve_workspaces_root "${WORKSPACES_ROOT_CLI}")" || exit 1

SOURCE_WS="${WORKSPACES_ROOT}/${PROJECT_NAME}"

# If ARG is a Docker container ID (hex string ≥12 chars), resolve it to the
# container name so the leaf extraction below works the same as for a name.
if [[ "${ARG}" =~ ^[0-9a-f]{12,}$ ]] && command -v docker >/dev/null 2>&1; then
    _resolved="$(docker inspect --format '{{.Name}}' "${ARG}" 2>/dev/null || true)"
    _resolved="${_resolved#/}"   # docker prepends a leading /
    if [[ -n "${_resolved}" ]]; then
        echo "resolved container ID '${ARG}' → '${_resolved}'"
        ARG="${_resolved}"
    fi
fi

# Accept "feature/FLOW-1234_foo", "FLOW-1234_foo", "<PROJECT_NAME>-FLOW-1234_foo",
# or "<PROJECT_SHORT>-FLOW-1234_foo" (Docker container name).
#
# The prefixes must NOT be stripped unconditionally: a branch leaf legitimately
# starts with the project name whenever branches are named after the project's
# issue key (project "FLOW", branch "feature/FLOW-4711" -> leaf "FLOW-4711", whose
# workspace is "FLOW-FLOW-4711"). Blind stripping turned that into "4711" and the
# workspace was never found. So we build the candidates in order of specificity
# and pick the first one that actually exists on disk; if none does, the
# unstripped form drives the error message.
_RAW_LEAF="${ARG##*/}"                  # strip optional branch prefix like feature/
LEAF_CANDIDATES=("${_RAW_LEAF}")
[[ "${_RAW_LEAF}" != "${_RAW_LEAF#"${PROJECT_NAME}"-}" ]] && LEAF_CANDIDATES+=("${_RAW_LEAF#"${PROJECT_NAME}"-}")
[[ "${_RAW_LEAF}" != "${_RAW_LEAF#"${PROJECT_SHORT}"-}" ]] && LEAF_CANDIDATES+=("${_RAW_LEAF#"${PROJECT_SHORT}"-}")

LEAF="${_RAW_LEAF}"
for _cand in "${LEAF_CANDIDATES[@]}"; do
    if [[ -d "${WORKSPACES_ROOT}/${PROJECT_NAME}-${_cand}" ]]; then
        LEAF="${_cand}"
        break
    fi
done
WS_NAME="${PROJECT_NAME}-${LEAF}"
WS_DIR="${WORKSPACES_ROOT}/${WS_NAME}"

if [[ ! -d "${WS_DIR}" ]]; then
    echo "Workspace not found: ${WS_DIR}" >&2
    if (( ${#LEAF_CANDIDATES[@]} > 1 )); then
        echo "(also tried: ${LEAF_CANDIDATES[*]:1})" >&2
    fi
    echo "If your workspaces live elsewhere, pass --workspaces-root <path>" >&2
    echo "or set \$${ENV_VAR_WORKSPACES_ROOT}." >&2
    exit 1
fi

# Refuse to dispose the source workspace by accident.
if [[ "${WS_DIR}" == "${SOURCE_WS}" ]]; then
    echo "Refusing to dispose the source workspace: ${SOURCE_WS}" >&2
    exit 1
fi

# Confirmation prompt. Default Y, so a quick Enter accepts; --yes / -y
# skips entirely for scripted use.
echo "About to dispose story workspace:"
echo "  target:        ${WS_DIR}"
echo "  delete-branch: $((DELETE_BRANCH))"
echo "  force:         $((FORCE))"
echo "  keep-container:$((KEEP_CONTAINER))"
echo "  keep-image:    $((KEEP_IMAGE))"
if (( ASSUME_YES == 0 )); then
    read -r -p "Proceed? [Y/n] " reply
    case "${reply}" in
        [Nn]*)
            echo "aborted. Pass --workspaces-root <path> or set \$${ENV_VAR_WORKSPACES_ROOT}" >&2
            echo "to point the script at a different workspaces directory." >&2
            exit 0
            ;;
    esac
fi

# REPOS in devcontainers-config.json is a "<name>:<base-ref>" map. Dispose only needs the
# names; pull them out once for the loops below.
# Length-guard: bash 3.2 + set -u fail on empty array expansion.
REPO_NAMES=()
if (( ${#REPOS[@]} > 0 )); then
    for entry in "${REPOS[@]}"; do
        REPO_NAMES+=("${entry%%:*}")
    done
fi

# Mono-repo mode: REPOS=() in devcontainers-config.json signals that the source workspace IS the
# git repo. Synthesise a single virtual entry so all downstream loops work
# without special-casing each one (mirrors the logic in spawn-workspace.sh).
MONO_REPO=0
if (( ${#REPOS[@]} == 0 )); then
    MONO_REPO=1
    REPO_NAMES=("${PROJECT_NAME}")
fi

# 1. Dirty-check up front, so we either remove everything or nothing.
# We always run the check; --force only changes whether dirtiness aborts or
# just warns. Warning loudly when forcing keeps the user from silently
# discarding work they didn't realize was there.
DIRTY=()
for repo in "${REPO_NAMES[@]}"; do
    wt="${WS_DIR}/${repo}"
    [[ -d "${wt}/.git" || -f "${wt}/.git" ]] || continue
    if [[ -n "$(git -C "${wt}" status --porcelain 2>/dev/null || true)" ]]; then
        DIRTY+=("${repo}")
    fi
done
if [[ ${#DIRTY[@]} -gt 0 ]]; then
    if [[ ${FORCE} -eq 0 ]]; then
        echo "Worktrees with uncommitted changes:" >&2
        printf '  %s\n' "${DIRTY[@]}" >&2
        echo "Commit/stash them first, or rerun with --force to discard." >&2
        exit 1
    else
        echo "WARNING: --force will discard uncommitted changes in:" >&2
        printf '  %s\n' "${DIRTY[@]}" >&2
        echo "         continuing in 3s, Ctrl-C to abort..." >&2
        sleep 3
    fi
fi

# Remove a directory that may briefly stay "busy" after Docker Desktop releases
# its volume/bind mounts. `docker rm -f` and `docker volume rm` return before
# the host file-sharing layer (virtiofs/gRPC-FUSE) has actually unmounted the
# per-module node_modules named volumes bound INTO the workspace, so an
# immediate rm -rf can fail with "Permission denied" / "Directory not empty" on
# every .../node_modules for a few seconds -- even though the container and
# volumes are already gone. Retry a bounded number of times (max ~12s),
# stripping macOS 'deny delete' ACLs first. Returns 0 once the path is gone,
# non-zero if it still exists after all attempts (caller reports, never aborts).
remove_dir_resilient() {
    local path="$1" attempt
    [[ -e "${path}" ]] || return 0
    for attempt in 1 2 3 4 5 6; do
        chmod -RN "${path}" 2>/dev/null || true
        rm -rf "${path}" 2>/dev/null || true
        [[ -e "${path}" ]] || return 0
        sleep 2
    done
    [[ ! -e "${path}" ]]
}

# IntelliJ IDEA's Dev Containers integration keys every connection to a
# container by its `com.intellij.devcontainer.id` label (a 12-hex prefix, NOT
# the docker container id). It persists per-container state under the IDE config
# dir and never cleans it up when the container is disposed. Left behind, the
# dead ids make the IDE's Eel VFS throw "Cannot find container with id" on every
# file access -- thousands per second -- which starves the IO threads that would
# otherwise (re)connect a live devcontainer. So on dispose we remove that state
# for the id we are tearing down. `id` is the 12-hex label prefix.
prune_intellij_devcontainer() {
    local id="$1" ide_running=0 root prod
    local roots=()
    [[ -n "${id}" ]] || return 0
    if [[ -d "${HOME}/Library/Application Support/JetBrains" ]]; then
        roots+=("${HOME}/Library/Application Support/JetBrains")
    fi
    if [[ -d "${HOME}/.config/JetBrains" ]]; then
        roots+=("${HOME}/.config/JetBrains")
    fi
    (( ${#roots[@]} > 0 )) || return 0

    # The self-contained artifacts (per-container options dir, workspace xml) are
    # safe to delete anytime. The shared *.xml indexes below are rewritten by a
    # running IDE on exit, so we only prune them when IntelliJ is not running.
    if pgrep -f 'IntelliJ IDEA.app/Contents/MacOS/idea' >/dev/null 2>&1 \
       || pgrep -f 'Contents/bin/idea' >/dev/null 2>&1; then
        ide_running=1
    fi

    echo "removing IntelliJ devcontainer config for id ${id}"
    for root in "${roots[@]}"; do
        for prod in "${root}"/IntelliJIdea* "${root}"/IdeaIC*; do
            [[ -d "${prod}" ]] || continue
            rm -rf "${prod}/options/Devcontainer-${id}@" 2>/dev/null || true
            rm -f "${prod}"/workspace/Devcontainer__"${id}".*.xml 2>/dev/null || true
            if [[ ${ide_running} -eq 0 ]]; then
                prune_ij_xml_entries "${prod}/options/recentProjects.xml" "${id}"
                prune_ij_xml_entries "${prod}/options/trusted-paths.xml" "${id}"
                prune_ij_xml_entries "${prod}/options/nonLocalTargets.xml" "${id}"
            fi
        done
    done
    if [[ ${ide_running} -eq 1 ]]; then
        echo "  note: IntelliJ is running -- left recentProjects/trusted-paths/"
        echo "        nonLocalTargets entries for ${id} in place (an open IDE would"
        echo "        rewrite them on exit). Quit IntelliJ once to clear them."
    fi
    return 0
}

# Delete every "<entry key=\"...<id>...\"> ... </entry>" block (and the
# self-closing "<entry ... />" variant) from an IntelliJ options XML, in place.
# These entries never nest another <entry>, so the sed range is unambiguous.
prune_ij_xml_entries() {
    local file="$1" id="$2" tmp
    [[ -f "${file}" ]] || return 0
    grep -q "${id}" "${file}" 2>/dev/null || return 0
    tmp="${file}.dispose-tmp.$$"
    if sed -E \
        -e "/<entry key=\"[^\"]*${id}[^\"]*\"[^>]*\/>/d" \
        -e "/<entry key=\"[^\"]*${id}[^\"]*\">/,/<\/entry>/d" \
        "${file}" > "${tmp}" 2>/dev/null; then
        mv "${tmp}" "${file}"
    else
        rm -f "${tmp}" 2>/dev/null || true
    fi
    return 0
}

# 2. Remove the Docker container, its named volumes, and (by default) its
# devcontainer image FIRST -- before any filesystem removal below.
#
# The per-module node_modules are Docker named volumes mounted INTO the
# bind-mounted workspace (see spawn-workspace.sh, NPM_NM_VOLUME_MOUNTS). While
# the container runs, those mount-points are live and the host cannot delete
# them: `rm -rf` fails with "Permission denied" / "Directory not empty" on
# every .../node_modules, and under `set -e` that aborts the whole dispose
# before the container is ever removed -- leaving a running container AND a
# half-deleted workspace. Removing the container releases the mounts, turning
# those node_modules back into ordinary empty dirs the rm below can clear.
#
# spawn-workspace.sh names the container '<PROJECT_SHORT>-<leaf>' via runArgs.
# Named volumes (including the per-story Claude project volume whose name embeds
# a JetBrains devcontainerId hash) are discovered from the container at runtime.
if [[ ${KEEP_CONTAINER} -eq 0 ]]; then
    CONTAINER="${PROJECT_SHORT}-${LEAF}"
    if command -v docker >/dev/null 2>&1; then
        if docker inspect "${CONTAINER}" >/dev/null 2>&1; then
            echo
            echo "removing docker container '${CONTAINER}'"
            # Collect the image ID, attached named volumes and the IntelliJ
            # devcontainer id (label) before removal -- all are gone after rm.
            image_id="$(docker inspect --format '{{.Image}}' "${CONTAINER}" 2>/dev/null || true)"
            volumes="$(docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "${CONTAINER}" 2>/dev/null || true)"
            ij_devcontainer_id="$(docker inspect --format '{{index .Config.Labels "com.intellij.devcontainer.id"}}' "${CONTAINER}" 2>/dev/null || true)"
            [[ "${ij_devcontainer_id}" == "<no value>" ]] && ij_devcontainer_id=""
            docker rm -f "${CONTAINER}" >/dev/null
            for v in ${volumes}; do
                echo "removing docker volume '${v}'"
                docker volume rm "${v}" >/dev/null 2>&1 || echo "  (volume ${v}: already gone or in use)"
            done
            if [[ ${KEEP_IMAGE} -eq 0 && -n "${image_id}" ]]; then
                echo "removing devcontainer image ${image_id}"
                docker rmi "${image_id}" >/dev/null 2>&1 \
                    || echo "  (image not removed: still referenced by another container)"
            fi
            if [[ -n "${ij_devcontainer_id}" ]]; then
                prune_intellij_devcontainer "${ij_devcontainer_id:0:12}"
            fi
        fi
    else
        echo "docker not on PATH, skipping container cleanup" >&2
    fi
fi

# 3. Remove worktrees from each source repo.
#
# We look up the *actual* registered path via `git worktree list` rather than
# only checking the expected path $wt. A previous mis-pathed spawn (e.g. with
# a relative --workspaces-root) may have registered the worktree at a
# completely different location; checking only $wt would silently skip it,
# leaving stale git metadata that makes the next spawn fail with
# "already used by worktree".
BRANCH=""   # remember branch name once we read it from a worktree (all repos share the same name)

for repo in "${REPO_NAMES[@]}"; do
    # Mono-repo: the git repo lives at SOURCE_WS itself, not in a sub-directory.
    if (( MONO_REPO == 1 )); then
        src="${SOURCE_WS}"
    else
        src="${SOURCE_WS}/${repo}"
    fi
    wt="${WS_DIR}/${repo}"
    # -e (not -d): submodules carry a .git *file* pointer, not a directory.
    [[ -e "${src}/.git" ]] || continue

    # Capture the branch name from the expected worktree path (for optional
    # branch deletion later). Falls back gracefully if wt doesn't exist.
    if [[ -z "${BRANCH}" && -e "${wt}" ]]; then
        BRANCH="$(git -C "${wt}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    fi

    # Find any worktree whose path contains WS_NAME — matches both the correct
    # path ($wt) and mis-pathed registrations from earlier broken spawns.
    actual_wt="$(git -C "${src}" worktree list --porcelain 2>/dev/null \
        | awk -v ws="${WS_NAME}" '/^worktree / && index($2, ws) > 0 { print $2 }')"

    if [[ -n "${actual_wt}" ]]; then
        echo "remove worktree: ${repo} (at ${actual_wt})"
        # git's own removal rm's the whole tree, so it hits the same mount-release
        # race; fall back to the resilient remover. Neither may abort the loop
        # (set -e) -- a stubborn repo must not strand the remaining ones as
        # dangling worktree registrations.
        if ! git -C "${src}" worktree remove --force "${actual_wt}" 2>/dev/null; then
            remove_dir_resilient "${actual_wt}" \
                || echo "  (warning: could not fully remove ${actual_wt}; remove it manually and rerun dispose)" >&2
        fi
    fi
    # Prune any remaining stale entries (e.g. directory already deleted on disk).
    git -C "${src}" worktree prune
    # Belt-and-suspenders: remove $wt if it still exists but wasn't registered.
    if [[ -e "${wt}" ]]; then
        remove_dir_resilient "${wt}" \
            || echo "  (warning: could not fully remove ${wt}; remove it manually and rerun dispose)" >&2
    fi
done

# 4. Remove the workspace directory itself (devcontainer config, .idea, claude copy, …)
#
# Guard: if the container still exists, its per-module node_modules named volumes
# are still mounted into WS_DIR (see step 2). The host cannot delete a live
# mount-point, so rm -rf would fail with a confusing "Permission denied" /
# "Directory not empty" on every .../node_modules. This happens when
# --keep-container was passed, or when step 2 couldn't reach Docker. Detect it
# and print an actionable message instead of letting rm spew per-path errors.
if [[ -d "${WS_DIR}" ]]; then
    CONTAINER="${PROJECT_SHORT}-${LEAF}"
    if command -v docker >/dev/null 2>&1 && docker inspect "${CONTAINER}" >/dev/null 2>&1; then
        echo >&2
        echo "Container '${CONTAINER}' still exists and holds node_modules volume mounts" >&2
        echo "inside ${WS_DIR}; the workspace directory cannot be removed while those" >&2
        echo "mounts are live." >&2
        if [[ ${KEEP_CONTAINER} -eq 1 ]]; then
            echo "You passed --keep-container. Close it in IntelliJ/Gateway, then rerun" >&2
            echo "without --keep-container to also remove the workspace directory." >&2
        else
            echo "Remove it manually with 'docker rm -f ${CONTAINER}' and rerun dispose." >&2
        fi
        echo "Left ${WS_DIR} in place." >&2
    else
        # macOS sometimes sets a 'deny delete' ACL on directories created through
        # Docker Desktop or IntelliJ, and the node_modules mount-points may still
        # be settling (see remove_dir_resilient) -- strip ACLs + retry.
        if remove_dir_resilient "${WS_DIR}"; then
            echo "removed: ${WS_DIR}"
        else
            echo "Left ${WS_DIR} in place: some entries could not be removed" >&2
            echo "(mounts may still be releasing). Rerun dispose in a moment." >&2
        fi
    fi
fi

# 5. Optional: delete the local branch in each source repo.
#
# Only worktree mode creates the story branch IN the source repos; clone mode
# keeps its branch inside the clone and container mode inside the container's
# volume, both already removed above. We decide what to do by DETECTING whether
# the branch is actually present in a source repo, NOT by trusting a repoMode
# value -- dispose only sees the config's current default, which may differ from
# the mode this workspace was spawned with (a --repo-mode override leaves no
# trace in the config). BRANCH is empty when the workspace had no host checkout
# to read HEAD from (container mode).
if [[ ${DELETE_BRANCH} -eq 1 ]]; then
    echo
    if [[ -z "${BRANCH}" ]]; then
        echo "--delete-branch: the workspace had no host-side git checkout to read a branch"
        echo "  from (container mode), so there is no source-repo branch to delete."
    else
        _found_branch=0
        for repo in "${REPO_NAMES[@]}"; do
            # Mono-repo: the git repo lives at SOURCE_WS itself, not in a sub-directory.
            if (( MONO_REPO == 1 )); then
                src="${SOURCE_WS}"
            else
                src="${SOURCE_WS}/${repo}"
            fi
            # -e (not -d): submodules carry a .git *file* pointer, not a directory.
            [[ -e "${src}/.git" ]] || continue
            git -C "${src}" show-ref --verify --quiet "refs/heads/${BRANCH}" || continue
            _found_branch=1
            echo "deleting local branch '${BRANCH}' in ${repo}"
            if [[ ${FORCE} -eq 1 ]]; then
                git -C "${src}" branch -D "${BRANCH}" || true
            else
                git -C "${src}" branch -d "${BRANCH}" || \
                    echo "  ${repo}: branch not fully merged, keep or rerun with --force" >&2
            fi
        done
        if (( _found_branch == 0 )); then
            echo "--delete-branch: branch '${BRANCH}' is not present in any source repo -- clone /"
            echo "  container mode keeps it inside the removed clone/container, so nothing to delete."
        fi
    fi
fi

echo
echo "done."
