#!/usr/bin/env bash
#
# spawn-workspace.sh — create an isolated, devcontainer-ready workspace for one story.
#
# ============================================================================
# FEATURE OVERVIEW
# ============================================================================
#
# 1. Branch-driven workspace layout
#    Input branch "feature/FLOW-4711_example" yields workspace
#    <workspaces-root>/<PROJECT_NAME>-FLOW-4711_example/. The branch-path
#    prefix (feature/, bugfix/, ...) is stripped; the leaf becomes the suffix.
#
# 2. Git worktrees instead of fresh clones
#    For each source repo under <workspaces-root>/<PROJECT_NAME>/<repo> (REPOS
#    array in .env.sh) a worktree is created in the new workspace. The script
#    picks one of three strategies per repo:
#      - local branch exists      -> reuse it (and fast-forward to --base if
#                                    the branch has no story-specific commits,
#                                    so a stale leftover from an earlier spawn
#                                    doesn't drag in obsolete content)
#      - only remote branch       -> track origin/<branch>
#      - branch is new            -> fork from --base, otherwise origin/HEAD
#    Worktrees keep the source repo as the single source of truth and avoid
#    duplicating the .git history on disk.
#    Exception -- host-mount entries: a REPOS entry with an EMPTY value (e.g.
#    "hal-npm-packages:") is not a git repo; no worktree is created. Instead the
#    host directory is bind-mounted into the workspace at the same path (mount
#    JSON built alongside NPM_NM_VOLUME_MOUNTS, injected into devcontainer.json).
#    For pre-built artifacts / non-versioned folders. Mono-repo's synthetic
#    "${PROJECT_NAME}:" entry also has an empty value but is a real git repo, so
#    it is excluded via MONO_REPO.
#
# 3. Per-repo base ref for new branches
#    Each entry in REPOS (.env.sh) is "<repo>:<base-ref>". When the branch
#    passed to spawn is brand new, that repo's base ref decides where to
#    fork from: origin/<ref> preferred, falls back to local <ref>; if the
#    repo doesn't know the requested ref at all, falls back to origin/HEAD
#    with a console note. Different repos can use different base refs
#    (e.g. a docs repo on 'main' while the rest forks from 'development').
#
# 4. NO aggregator pom.xml at the workspace root
#    Subprojects' parents (commons-web etc.) don't carry an explicit
#    <relativePath>, so an aggregator would be falsely picked up as parent
#    by Maven, producing "parent.relativePath ... points at <agg>" errors on
#    every sync. We list each subproject's pom in MavenProjectsManager.original
#    Files (.idea/misc.xml) so IntelliJ imports each as a top-level project.
#    post-create.sh builds each repo in dependency order (BUILDS / MAVEN_BUILDS
#    in .env.sh).
#
# 4a. Optional initialization hook (initialize.sh)
#    If dev-containers/initialize.sh exists, spawn-workspace.sh copies it to
#    <workspace>/.devcontainer/initialize.sh and post-create.sh runs it with
#    the workspace root as CWD, right before the Maven warmup builds.
#    Use it for one-time setup that must happen before Maven resolves
#    dependencies (e.g. starting a Docker service that hosts a Maven proxy,
#    seeding a local registry, or pulling DinD images while the network is
#    still available). The file is not created automatically; simply add
#    initialize.sh next to spawn-workspace.sh to activate the hook.
#
# 5. CLAUDE.md, .claude/ and README.md placed at the workspace root
#    Claude Code in the new workspace inherits the same project-level
#    instructions, agents, and skills as the source workspace. A README.md is
#    written at the workspace root (with story-specific port info, first-time
#    setup steps, and the run-config order); IntelliJ's auto-README opener
#    finds it before descending into Maven modules and surfaces it as the
#    opening tab without any FileEditorManager hacks. .idea/ is pre-populated
#    with: .name ("<PROJECT_SHORT> <branch-leaf>") for a distinctive project label,
#    misc.xml pointing the project SDK at JDK 21 (so opening a Java file
#    doesn't prompt "Project JDK is not defined"), compiler.xml enabling
#    annotation processing globally (no Lombok prompt), and run
#    configurations for the projects.
#
# 6. Dev Container with Java 21 + Maven + Node 24 + Git + Docker-in-Docker
#    Built from a tiny local Dockerfile that patches the MS base image
#    (mcr.microsoft.com/devcontainers/java:1-21-bookworm) by removing its
#    expired Yarn apt source -- otherwise every feature's apt-get update
#    fails with exit code 100. Features add Maven (via SDKMAN, the java:1
#    feature with version=none + installMaven=true so we keep the base image's
#    Java but get the SDKMAN-managed mvn), Node 24, Git, and a per-container
#    Docker daemon (DinD) so each story's testcontainers/compose stacks are
#    isolated and never collide on container names or host ports. The DinD
#    feature relies on its own entrypoint to start dockerd, but JetBrains
#    Gateway overrides the entrypoint -- so post-start.sh kicks dockerd on
#    every container start (idempotent, with a TCP listener on 127.0.0.1:2375
#    as a fallback to the unix socket, mirroring the GitLab CI dind setup).
#    JetBrains backend is preselected via customizations.jetbrains.backend.
#
# 6a. Per-module node_modules on Docker named volumes
#    Every npm module (each package.json outside node_modules/.git) gets its
#    node_modules mounted as a Docker named volume instead of living in the
#    bind-mounted workspace (NPM_NM_VOLUME_MOUNTS, injected into
#    devcontainer.json). Rationale: on macOS Docker Desktop the
#    Virtualization.framework bridges every file of a bind mount between the
#    Linux VM and the host; for node_modules with tens of thousands of files
#    npm becomes 10-100x slower. Named volumes live on the VM's own ext4 fs,
#    so npm writes at Linux-native speed. dispose-workspace.sh removes these
#    volumes automatically via `docker inspect` on the container. Caveat: a
#    freshly created named volume is owned by root:root, but the warmup build
#    (and the IDE) run as vscode -- so post-create.sh (feature 12) chowns each
#    node_modules mount-point to vscode before any npm/Maven step touches it,
#    otherwise npm dies with "EACCES: permission denied, mkdir .../@types".
#
# 7. Constant in-container workspace path: /workspaces/<PROJECT_NAME>
#    Every story container mounts the workspace at the same path. Claude Code
#    encodes the project key from the cwd, so this gives every container the
#    SAME memory key (-workspaces-<PROJECT_NAME>), which is what makes the
#    shared memory bind below actually align across containers. The story workspace
#    is ALSO bind-mounted at its host path, plus the source workspace, so git
#    worktree references resolve inside the container (without those binds,
#    git in the container can't read worktree metadata and reports every
#    repo as "not a git repository").
#
# 8. Layered Claude state: shared memory, isolated history
#    Three mounts stack on /home/vscode/.claude (deeper paths win):
#      a. bind   ~/.claude                                                  -> share login, user agents, slash commands
#      b. volume <PROJECT_SHORT>-claude-project-${devcontainerId} on .../projects/<key> -> isolate per-project state (history, todos, sessions)
#      c. bind   ~/.claude/projects/<key>/memory                            -> bring memory/ back to a single shared host folder
#    Effect: persistent memory across container rebuilds AND shared between
#    parallel story containers, but conversation history stays per-story.
#    ~/.claude.json is bind-mounted as a sibling so the API/auth config is
#    shared too.
#
# 9. Host integration mounts (read-only where appropriate)
#    ~/.ssh is mounted readonly so git finds keys out of the box. ~/.m2 is
#    mounted writable so the Maven cache survives container rebuilds and is
#    shared across stories. The host's glab config directory is mounted
#    writable onto the container's ~/.config/glab-cli; spawn-workspace.sh
#    resolves the host path per OS (macOS: ~/Library/Application Support/
#    glab-cli, Linux: ~/.config/glab-cli) so the GitLab CLI login flows
#    between host and container regardless of platform. ~/.npmrc is NOT
#    bind-mounted: spawn-workspace.sh
#    resolves the host file at spawn time (strips /Users/... paths, substitutes
#    ${TOKEN_NAME}-style placeholders for every var in FORWARDED_ENV_VARS with
#    the spawn shell's value) and writes .devcontainer/host-npmrc.resolved
#    into the workspace, which post-create copies to /home/vscode/.npmrc.
#    We tried bind-mounting before but JetBrains' devcontainer setup didn't
#    surface the mount under /tmp on this user's Docker, leaving npm without
#    auth. Going through the workspace bind is reliable. ~/.gitconfig is NOT
#    bind-mounted: JetBrains writes user.name/user.email into the container's
#    gitconfig itself, and a bind mount on a single file breaks git's atomic
#    rename ("Device or resource busy"). FORWARDED_ENV_VARS entries are also
#    forwarded via remoteEnv as a fallback for tools that re-read env at runtime.
#
# 10. runArgs: --name <PROJECT_SHORT>-<leaf>
#    Names the underlying Docker container after the branch leaf so it is
#    visible as e.g. "<PROJECT_SHORT>-FLOW-4711_example" in `docker ps` and Docker Desktop.
#    JetBrains' devcontainer-id label in its UI still shows a hash, but Docker
#    tooling now identifies stories by their branch name.
#
#    Port offset (multiple of 10000): spawn-workspace.sh probes the host for
#    free ports and picks the lowest offset where 4200/5173/8079/8080/9080 are
#    all free. The probe checks BOTH currently-bound listeners AND host ports
#    statically reserved by other story workspaces' devcontainer.json files,
#    so a stopped (but not disposed) workspace can't be unstuck-into-conflict
#    when its container is later restarted. Default offset is 0 (same numbers
#    on host and container). forwardPorts uses host:container syntax so the
#    container itself stays on its native ports (no Spring server.port
#    override needed). OAuth callback / issuer URIs that *do* depend on the
#    host-visible port (cockpit's redirect-uri, auth server's registered
#    redirect-uris, issuer-uri) are passed as JVM system properties in the
#    run configs so that browser-side OAuth flows still match.
#
# 11. initializeCommand prepares host-side bind targets
#     Creates ~/.m2, ~/.ssh, ~/.claude, the shared memory directory, and
#     touches ~/.claude.json so Docker doesn't create them as root-owned
#     dirs on first mount.
#
# 12. postCreateCommand warms the build (and waitFor blocks the IDE on it)
#     Installs Claude Code globally, fixes ownership on the per-story Claude
#     project volume, exposes 'mvn' and 'claude' as symlinks under
#     /usr/local/bin so non-login IDE terminals find them, drops a 'branches'
#     helper script that prints each worktree's current branch, chowns the
#     per-module node_modules named volumes to vscode (fresh named volumes are
#     root:root, so npm running as vscode would otherwise die with EACCES on
#     'mkdir node_modules/@types' -- see the node_modules volume mounts in
#     feature 6a / NPM_NM_VOLUME_MOUNTS), then resolves the Maven reactor in
#     dependency order (BUILDS / MAVEN_BUILDS). Tests (unit/integration/E2E)
#       are not part of the warmup -- run them on demand from the IDE.
#     "waitFor": "postCreateCommand" makes IntelliJ block on this completing
#     before opening the project window, so the IDE's first index pass sees
#     a fully resolved reactor instead of an empty workspace.
#
# Companion script: bin/dispose-workspace.sh removes a workspace and prunes
# its worktrees.
#
# ============================================================================
#
# Layout:
#   <workspaces-root>/<PROJECT_NAME>/                   (source workspace, read by this script)
#   <workspaces-root>/<PROJECT_NAME>-<branch-leaf>/     (created by this script)
#
# The <workspaces-root> directory is resolved in this order:
#   1. --workspaces-root <path>            CLI flag (highest priority)
#   2. $<PROJECT_SHORT>_WORKSPACES_ROOT    environment variable (e.g. VANILLABP_WORKSPACES_ROOT)
#   3. auto-detect: parent of the directory holding this script, i.e. the
#                   source workspace's parent
# Regardless of source, the script prints the resolved target workspace
# directory and asks for confirmation before creating anything; pass --yes
# to skip the prompt for scripted use.
#
# Usage:
#   dev-containers/spawn-workspace.sh [--workspaces-root <path>] [--yes] <branch-name>
#
# Examples:
#   dev-containers/spawn-workspace.sh feature/FLOW-4711_example-story
#   dev-containers/spawn-workspace.sh --workspaces-root /opt/dev feature/FLOW-4711_example
#   VANILLABP_WORKSPACES_ROOT=/opt/dev dev-containers/spawn-workspace.sh feature/FLOW-4711_example
#
# Base refs for new branches are configured per repo in REPOS (.env.sh).
# If the branch already exists locally or on origin, the existing tip is
# reused and the base ref is ignored.
#
set -euo pipefail

# Resolve the script's own directory first; everything else hangs off it
# (the project config, the workspaces-root auto-detect).
SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd)"

# Source project-specific config (PROJECT_NAME, PROJECT_SHORT, REPOS, ports,
# base image, glab hostname, ...). Forking this script tree to a new project
# means editing .env.sh; the script body is project-agnostic for the bits
# .env.sh covers ("Mittel" scope).
ENV_FILE="${SCRIPT_DIR}/.env.sh"
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Project config not found: ${ENV_FILE}" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${ENV_FILE}"

# Derived from PROJECT_NAME for use in both shell logic and as sed-substituted
# placeholders in the heredoc'd templates below.
WORKSPACE_PATH="/workspaces/${PROJECT_NAME}"
MEMORY_KEY="-workspaces-${PROJECT_NAME}"
# Env var name for the workspaces-root override. Derived from PROJECT_SHORT
# (uppercased) so different projects don't fight for the same name.
ENV_VAR_WORKSPACES_ROOT="$(echo "${PROJECT_SHORT}" | tr '[:lower:]' '[:upper:]')_WORKSPACES_ROOT"

# GitLab integration is optional. It only kicks in when BOTH GLAB_HOSTNAME
# (the GitLab host the project lives on) and GLAB_VERSION (the glab CLI
# release to install in the container) are set in .env.sh. Empty either
# one and the project gets a container without glab installed, without
# the bind-mounted glab config, and without the git credential helper
# for that host. The conditional blocks in the generated files are
# stripped via __GLAB_BLOCK_START__/__GLAB_BLOCK_END__ markers below.
if [[ -n "${GLAB_HOSTNAME:-}" && -n "${GLAB_VERSION:-}" ]]; then
    GLAB_ENABLED=1
else
    GLAB_ENABLED=0
fi

BRANCH=""
WORKSPACES_ROOT_CLI=""
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspaces-root)
            WORKSPACES_ROOT_CLI="${2-}"
            [[ $# -lt 2 ]] && { echo "--workspaces-root needs an argument" >&2; exit 2; }
            shift 2
            ;;
        --workspaces-root=*)
            WORKSPACES_ROOT_CLI="${1#--workspaces-root=}"
            shift
            ;;
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            sed -n '2,180p' "$0"
            exit 0
            ;;
        --)
            shift
            BRANCH="${1:-}"
            break
            ;;
        -*)
            echo "unknown option: $1" >&2
            exit 2
            ;;
        *)
            [[ -n "${BRANCH}" ]] && { echo "unexpected argument: $1" >&2; exit 2; }
            BRANCH="$1"
            shift
            ;;
    esac
done

if [[ -z "${BRANCH}" ]]; then
    echo "usage: $0 [--workspaces-root <path>] [--yes] <branch-name>" >&2
    exit 2
fi

# Derive name-only list from REPOS (which is a "<name>:<base-ref>" map).
# Most loops below only need names; the base-ref is consulted only when
# creating worktrees for a brand-new branch.
# Length-guard: bash 3.2 + set -u fail on empty array expansion.
REPO_NAMES=()
if (( ${#REPOS[@]} > 0 )); then
    for entry in "${REPOS[@]}"; do
        REPO_NAMES+=("${entry%%:*}")
    done
fi

# Mono-repo mode: REPOS=() in .env.sh signals that the source workspace IS
# the git repo (project directory == repo directory). We synthesise a single
# virtual entry so all downstream loops work without special-casing each one.
MONO_REPO=0
if (( ${#REPOS[@]} == 0 )); then
    MONO_REPO=1
    REPOS=("${PROJECT_NAME}:")
    REPO_NAMES=("${PROJECT_NAME}")
fi

# Build-command config -- two mutually exclusive styles are accepted; the first
# one that is *defined* wins (checked with `declare -p`, so an explicit empty
# array still selects its style):
#   MAVEN_BUILDS (legacy) : "<repo>:<mvn-goal>" -- value is an mvn goal, run as
#                           `mvn ${MVN_FLAGS} <goal>`. A value starting with '$'
#                           is instead a raw bash command (everything after '$').
#                           This is the original MAVEN_REPOS behaviour; the old
#                           MAVEN_REPOS name is still honoured as an alias.
#   BUILDS       (raw)    : "<repo>:<command>" -- value is ALWAYS a raw bash
#                           command run verbatim inside <repo>. No mvn/MVN_FLAGS
#                           injection and no '$' prefix; Maven users spell out
#                           "mvn ..." themselves.
# Everything downstream iterates the normalised BUILD_ENTRIES using BUILD_MODE
# ("maven" or "raw") to pick the per-entry interpretation. Length-guard every
# array read: bash 3.2 + set -u choke on empty-array expansion.
BUILD_ENTRIES=()
BUILD_MODE=""
if declare -p MAVEN_BUILDS >/dev/null 2>&1; then
    BUILD_MODE="maven"
    (( ${#MAVEN_BUILDS[@]} > 0 )) && BUILD_ENTRIES=("${MAVEN_BUILDS[@]}")
elif declare -p MAVEN_REPOS >/dev/null 2>&1; then
    BUILD_MODE="maven"
    (( ${#MAVEN_REPOS[@]} > 0 )) && BUILD_ENTRIES=("${MAVEN_REPOS[@]}")
elif declare -p BUILDS >/dev/null 2>&1; then
    BUILD_MODE="raw"
    (( ${#BUILDS[@]} > 0 )) && BUILD_ENTRIES=("${BUILDS[@]}")
fi

# Mono-repo default: when no build list is configured and a pom.xml exists at
# the repo root, build the project as a single Maven reactor.
if (( MONO_REPO == 1 )) && (( ${#BUILD_ENTRIES[@]} == 0 )); then
    if [[ -f "${SOURCE_WS}/pom.xml" ]]; then
        BUILD_ENTRIES=("${PROJECT_NAME}:install")
        BUILD_MODE="maven"
    fi
fi

# Resolve the workspaces root directory in priority order:
#   1. --workspaces-root CLI flag
#   2. ${ENV_VAR_WORKSPACES_ROOT} env var (e.g. VANILLABP_WORKSPACES_ROOT)
#   3. auto-detect via the script's own location: the script lives at
#      <root>/<PROJECT_NAME>/dev-containers/spawn-workspace.sh, so two dirs
#      up from SCRIPT_DIR is the root.
DEFAULT_WORKSPACES_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKSPACES_ROOT="${WORKSPACES_ROOT_CLI:-${!ENV_VAR_WORKSPACES_ROOT:-${DEFAULT_WORKSPACES_ROOT}}}"

if [[ ! -d "${WORKSPACES_ROOT}" ]]; then
    echo "Workspaces root does not exist: ${WORKSPACES_ROOT}" >&2
    echo "Override with --workspaces-root <path> or set \$${ENV_VAR_WORKSPACES_ROOT}." >&2
    exit 1
fi
# Canonicalise to an absolute path so bind-mount paths in devcontainer.json
# are never relative (Docker requires absolute paths in mount source/target).
WORKSPACES_ROOT="$(cd "${WORKSPACES_ROOT}" && pwd)"

SOURCE_WS="${WORKSPACES_ROOT}/${PROJECT_NAME}"

LEAF="${BRANCH##*/}"
WS_NAME="${PROJECT_NAME}-${LEAF}"
WS_DIR="${WORKSPACES_ROOT}/${WS_NAME}"

# Existence check up-front: a leftover workspace from an earlier spawn would
# cause partial overwrites if we charged ahead. Dispose it first or rename
# it out of the way.
if [[ -e "${WS_DIR}" ]]; then
    echo "Workspace already exists: ${WS_DIR}" >&2
    echo "Dispose it first: dev-containers/dispose-workspace.sh ${BRANCH}" >&2
    exit 1
fi

# Confirmation prompt. Default is Yes (Enter accepts), so the prompt mostly
# costs one keystroke per spawn. --yes / -y skips it for batch use.
echo "About to create story workspace:"
echo "  target:  ${WS_DIR}"
echo "  branch:  ${BRANCH}"
echo "  source:  ${SOURCE_WS}"
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

# Pick a port offset (multiple of 10000) where ALL forwarded ports are free
# on the host. This lets multiple stories run their containers in parallel
# without colliding on the standard ports. Offset 0 means original ports.
# OAuth callback / issuer URIs that hard-code a port get overridden via JVM
# system properties in the run configs (built below).
# HOST_PORTS comes from .env.sh.

# Collect host ports already reserved by OTHER story workspaces' devcontainer.json
# files. Even if their containers are stopped right now, starting them later
# would clash with our offset choice -- so we treat statically-mapped host
# ports as taken alongside currently-bound ones. The grep-based extraction
# matches "<num>:<num>" inside any of the workspace's devcontainer.json files
# (only port mappings appear in that quoted-pair shape; mounts use
# source=...,target=... and other JSON values don't have the colon-between-
# digits pattern).
RESERVED_HOST_PORTS=()
for dc in "${WORKSPACES_ROOT}"/${PROJECT_NAME}-*/.devcontainer/devcontainer.json; do
    [[ -f "${dc}" ]] || continue
    [[ "${dc}" == "${WS_DIR}/.devcontainer/devcontainer.json" ]] && continue
    while IFS= read -r host_port; do
        RESERVED_HOST_PORTS+=("${host_port}")
    done < <(grep -oE '"[0-9]+:[0-9]+"' "${dc}" | tr -d '"' | cut -d: -f1)
done
if (( ${#RESERVED_HOST_PORTS[@]} > 0 )); then
    echo "ports reserved by other workspaces: ${RESERVED_HOST_PORTS[*]}"
fi

is_port_in_use() {
    local p=$1
    # reserved by another workspace's static port mapping. Length guard
    # avoids bash 3.2's "${arr[@]}: unbound variable" trap under set -u
    # when no other workspaces exist (empty array).
    if (( ${#RESERVED_HOST_PORTS[@]} > 0 )); then
        local r
        for r in "${RESERVED_HOST_PORTS[@]}"; do
            [[ "${r}" == "${p}" ]] && return 0
        done
    fi
    # currently bound on host (live listener)
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"${p}" -sTCP:LISTEN 2>/dev/null | grep -q .
    else
        nc -z 127.0.0.1 "${p}" 2>/dev/null
    fi
}

PORT_OFFSET=0
while (( PORT_OFFSET <= 90000 )); do
    free_range=1
    # Length-guard avoids bash 3.2's "${arr[@]}: unbound variable" under set -u
    # when HOST_PORTS is empty (project has no forwarded ports).
    if (( ${#HOST_PORTS[@]} > 0 )); then
        for p in "${HOST_PORTS[@]}"; do
            if is_port_in_use "$((p + PORT_OFFSET))"; then
                free_range=0
                break
            fi
        done
    fi
    (( free_range == 1 )) && break
    PORT_OFFSET=$((PORT_OFFSET + 10000))
done
if (( PORT_OFFSET > 90000 )); then
    echo "ERROR: no free port range found (tried offset 0..90000 in 10000 steps)" >&2
    exit 1
fi
echo "port offset: ${PORT_OFFSET}"

# Build everything that depends on the per-port host numbers from HOST_PORTS
# (which lives in .env.sh) so adding a new forwarded port only takes editing
# the .env.sh entry, never this file. Four derived artifacts:
#   PORT_SED_ARGS    -e args list for substitute_placeholders: replaces every
#                    __PORT_<container>__ token with the offset host port
#   PORT_RUNARGS     JSON snippet injected into devcontainer.json runArgs as
#                    the literal "-p", "<host>:<container>" pairs
#   PORT_TABLE_ROWS  markdown table rows for the workspace README's "Browser
#                    access" section
#   PORT_OUTPUT_LINES plain-text port summary printed at the end of spawn
# PORT_LABELS ("container_port:label") is the single source of label text,
# used in both the README table and the JetBrains portsAttributes panel.
PORT_SED_ARGS=()
PORT_RUNARGS=""
PORT_TABLE_ROWS=""
PORT_OUTPUT_LINES=""
# Length-guard PORT_LABELS so bash 3.2 + set -u tolerate the array being empty.
port_labels_count=0
[[ "${PORT_LABELS+x}" == "x" ]] && port_labels_count=${#PORT_LABELS[@]}
# Same guard for HOST_PORTS: bash 3.2 + set -u fail on empty array expansion.
if (( ${#HOST_PORTS[@]} > 0 )); then
for p in "${HOST_PORTS[@]}"; do
    host_port=$((p + PORT_OFFSET))
    label=""
    if (( port_labels_count > 0 )); then
        for entry in "${PORT_LABELS[@]}"; do
            if [[ "${entry%%:*}" == "${p}" ]]; then
                label="${entry#*:}"
                break
            fi
        done
    fi
    PORT_SED_ARGS+=(-e "s/__PORT_${p}__/${host_port}/g")
    [[ -n "${PORT_RUNARGS}" ]] && PORT_RUNARGS="${PORT_RUNARGS}, "
    PORT_RUNARGS="${PORT_RUNARGS}\"-p\", \"${host_port}:${p}\""
    PORT_TABLE_ROWS+="| ${host_port} | ${p} | ${label} |"$'\n'
    PORT_OUTPUT_LINES+="  ${host_port}  ${label}"$'\n'
done
fi
# Strip trailing newline so the bash/heredoc interpolations don't pick up a blank line.
PORT_TABLE_ROWS="${PORT_TABLE_ROWS%$'\n'}"
PORT_OUTPUT_LINES="${PORT_OUTPUT_LINES%$'\n'}"

# Pre-compute README template values that substitute_placeholders needs.
# SSH_HOST_PORT: host-side port for the container's sshd (port 2222 + offset).
# FIRST_REPO: first repo name, used as an example in the tab-completion docs.
SSH_HOST_PORT=$((2222 + PORT_OFFSET))
_repos_1="${REPOS[1]:-}"
FIRST_REPO="${_repos_1%%:*}"
FIRST_REPO="${FIRST_REPO:-some-repo}"

# Warn only if the host actually USES env-var placeholders for private-package
# auth (some setups put literal tokens in ~/.npmrc / ~/.m2/settings.xml, in
# which case these env vars don't matter locally and the warning is noise).
HOST_NPMRC_CHECK="${HOME}/.npmrc"
HOST_M2_SETTINGS_CHECK="${HOME}/.m2/settings.xml"
if [[ ${#FORWARDED_ENV_VARS[@]} -gt 0 ]]; then
    for var in "${FORWARDED_ENV_VARS[@]}"; do
        references_var=0
        [[ -f "${HOST_NPMRC_CHECK}" ]]       && grep -qF "\${${var}}"             "${HOST_NPMRC_CHECK}"       && references_var=1
        [[ -f "${HOST_M2_SETTINGS_CHECK}" ]] && grep -qE "\\\$\{(env\.)?${var}\}" "${HOST_M2_SETTINGS_CHECK}" && references_var=1
        if [[ ${references_var} -eq 1 && -z "${!var:-}" ]]; then
            echo "WARN: \$${var} is referenced as a placeholder in your host npmrc/settings.xml" >&2
            echo "      but not set in this shell -- npm/Maven will fail with 401 on private packages." >&2
            echo "      Run 'direnv allow' in ${SOURCE_WS} (or 'source .envrc') and re-run." >&2
        fi
    done
fi

mkdir -p "${WS_DIR}"

# Resolve a base ref against the *current* repo: prefer origin/<ref>, fall back to <ref>.
resolve_base() {
    local ref="$1"
    if git rev-parse --verify --quiet "refs/remotes/origin/${ref}" >/dev/null; then
        echo "origin/${ref}"
    elif git rev-parse --verify --quiet "${ref}" >/dev/null; then
        echo "${ref}"
    else
        return 1
    fi
}

create_worktree() {
    local repo="$1"
    local base_ref="$2"
    # Mono-repo: the source workspace IS the git repo; no sub-directory.
    local src
    if (( MONO_REPO == 1 )); then
        src="${SOURCE_WS}"
    else
        src="${SOURCE_WS}/${repo}"
    fi
    local dst="${WS_DIR}/${repo}"

    if [[ ! -d "${src}/.git" ]]; then
        echo "skip ${repo}: no git repo at ${src}"
        return
    fi

    echo "worktree: ${repo} (base ${base_ref:-<origin/HEAD>})"
    pushd "${src}" >/dev/null

    # Prune stale worktree entries before adding. Without this, a failed or
    # mis-pathed previous spawn leaves git metadata pointing at a deleted
    # directory, causing "already used by worktree" on the next attempt.
    git worktree prune

    git fetch --quiet origin 2>/dev/null || true

    if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
        # Local branch exists. Fast-forward it before checking out so the new
        # worktree reflects the latest state rather than a potentially stale
        # local snapshot.  Two cases, tested in order:
        #
        # (i) origin/<branch> also exists: fast-forward the local branch to
        #     the remote tip if (and only if) the local is a strict ancestor —
        #     i.e. the local has no divergent commits.  This picks up commits
        #     pushed by collaborators.  Divergent locals are left as-is.
        #
        # (ii) No remote counterpart (purely local branch): if the local has
        #     no story-specific commits yet (its tip is an ancestor of the
        #     configured base), fast-forward to that base.  This handles
        #     re-spawn-after-dispose-without-delete-branch: without it the
        #     branch stays frozen at the old base even when development moved on.
        if git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}" 2>/dev/null; then
            local _local_tip _remote_tip
            _local_tip="$(git rev-parse "refs/heads/${BRANCH}")"
            _remote_tip="$(git rev-parse "refs/remotes/origin/${BRANCH}")"
            if [[ "${_local_tip}" != "${_remote_tip}" ]] \
                && git merge-base --is-ancestor "${_local_tip}" "${_remote_tip}"; then
                echo "  fast-forwarding '${BRANCH}' to origin/${BRANCH}"
                git update-ref "refs/heads/${BRANCH}" "${_remote_tip}"
            fi
        elif [[ -n "${base_ref}" ]] && base_resolved="$(resolve_base "${base_ref}")"; then
            local _branch_tip _base_tip
            _branch_tip="$(git rev-parse "refs/heads/${BRANCH}")"
            _base_tip="$(git rev-parse "${base_resolved}")"
            if [[ "${_branch_tip}" != "${_base_tip}" ]] \
                && git merge-base --is-ancestor "${_branch_tip}" "${_base_tip}"; then
                echo "  branch '${BRANCH}' has no commits beyond ${base_resolved}, fast-forwarding"
                git update-ref "refs/heads/${BRANCH}" "${_base_tip}"
            fi
        fi
        git worktree add "${dst}" "${BRANCH}"
    elif git ls-remote --exit-code --heads origin "${BRANCH}" >/dev/null 2>&1; then
        # remote branch exists, no local copy -> track it
        git worktree add --track -b "${BRANCH}" "${dst}" "origin/${BRANCH}"
    else
        # Branch is new -> base it on this repo's configured base-ref if
        # present, otherwise (or when the repo doesn't know that ref, e.g. a
        # docs-only repo has no 'development' branch) fall back to the repo's
        # own origin/HEAD.
        local base
        if [[ -n "${base_ref}" ]] && base="$(resolve_base "${base_ref}")"; then
            :
        else
            if [[ -n "${base_ref}" ]]; then
                echo "  note: base '${base_ref}' not found in ${repo}, using origin/HEAD instead"
            fi
            base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
        fi
        echo "  new branch from ${base}"
        # --no-track: don't inherit ${base} as upstream. Otherwise the new local
        # branch (feature/FLOW-...) would get upstream=origin/development (the
        # base we fork from is a remote-tracking ref, and git's default
        # autoSetupMerge wires that as upstream). push.default=simple then
        # refuses 'git push' because local and upstream names don't match.
        # With --no-track, the first 'git push -u origin HEAD' sets the matching
        # upstream cleanly and plain 'git push' works from then on.
        git worktree add --no-track -b "${BRANCH}" "${dst}" "${base}"
    fi

    popd >/dev/null
}

# Host-mount repos: a REPOS entry with an EMPTY value (e.g. "hal-npm-packages:")
# is not a git repo -- no worktree is created. Instead the host directory
# ${SOURCE_WS}/<repo> is bind-mounted straight into the workspace at the same
# path a worktree would occupy (mount JSON built below, injected into
# devcontainer.json). Use this for pre-built artifacts / non-versioned dirs that
# should still be visible and buildable inside the container.
# (Mono-repo's synthetic "${PROJECT_NAME}:" entry also has an empty value but is
# a real git repo, so it is excluded via MONO_REPO.)
HOST_MOUNT_REPOS=()
for entry in "${REPOS[@]}"; do
    repo="${entry%%:*}"
    base_ref="${entry#*:}"
    if (( MONO_REPO == 0 )) && [[ -z "${base_ref}" ]]; then
        echo "host-mount: ${repo} (bind ${SOURCE_WS}/${repo}, no worktree)"
        HOST_MOUNT_REPOS+=("${repo}")
        continue
    fi
    create_worktree "${repo}" "${base_ref}"
done

# Each source repo has its own .git/config which can ship with stale settings
# from a long-ago first-clone on a Linux machine: core.filemode=true (Linux
# default), no core.autocrlf, etc. Worktrees inherit those because they all
# share the main repo's config. The post-create.sh-level git --global defaults
# we set inside the container DON'T win because local repo config trumps
# global. Set both keys locally per source repo so the macOS-friendly values
# stick everywhere. Side effect (intentional): host-side git operations in
# these repos now also see core.filemode=false / autocrlf=input -- both
# correct for macOS-mounted worktrees.
for repo in "${REPO_NAMES[@]}"; do
    # Mono-repo: git config lives at SOURCE_WS itself, not in a sub-directory.
    if (( MONO_REPO == 1 )); then
        src_repo="${SOURCE_WS}"
    else
        src_repo="${SOURCE_WS}/${repo}"
    fi
    [[ -d "${src_repo}/.git" ]] || continue
    git -C "${src_repo}" config core.fileMode false
    git -C "${src_repo}" config core.autocrlf input
    # Belt-and-suspenders: same as the --global settings in post-create.sh,
    # but written locally so they survive even if a future global gets
    # cleared. checkStat/trustctime work around macOS-bind-mount stat drift
    # that makes rebase steps spuriously abort with "Your local changes
    # would be overwritten" -- see the post-create.sh comment for the
    # detailed mechanism.
    git -C "${src_repo}" config core.checkStat minimal
    git -C "${src_repo}" config core.trustctime false
done

# Collect npm module directories for Docker named-volume node_modules mounts.
#
# Root cause of npm slowness on macOS devcontainers: Docker Desktop's
# Virtualization.framework (com.apple.Virtualization.VirtualMachine XPC service)
# bridges every file read/write between the Linux VM and the macOS bind-mount.
# For storybook-scale packages (40 000+ files in node_modules), this XPC bridge
# becomes the bottleneck -- the process holds 40 000+ open file descriptors while
# npm is still writing, making npm 10-100x slower.
#
# Fix: mount each module's node_modules as a Docker named volume instead of
# letting it live in the bind-mounted workspace. Named volumes are backed by the
# Docker VM's own ext4 filesystem; the Virtualization.framework never touches
# individual files inside them. npm writes at Linux-native speed.
#
# Naming: ${PROJECT_SHORT}-${LEAF}-<slug>-nm, where <slug> is the module's
# workspace-relative path with / replaced by -. dispose-workspace.sh removes
# all volumes associated with the container via `docker inspect`, so cleanup
# is automatic on dispose.
NPM_MODULE_DIRS=()
while IFS= read -r pj; do
    pj_dir="$(dirname "${pj}")"
    rel="${pj_dir#${WS_DIR}/}"
    # Guard: skip if WS_DIR was not a prefix (shouldn't happen)
    [[ "${rel}" == "${pj_dir}" ]] && continue
    NPM_MODULE_DIRS+=("${rel}")
done < <(find "${WS_DIR}" -name "package.json" \
    -not -path "*/node_modules/*" \
    -not -path "*/.git/*" \
    2>/dev/null)

# Build the JSON fragment for injection into the devcontainer.json mounts array.
# Each line adds a leading comma so it can be appended after the last fixed mount.
# Length-guard: bash 3.2 + set -u fail on empty array expansion.
NPM_NM_VOLUME_MOUNTS=""
if (( ${#NPM_MODULE_DIRS[@]} > 0 )); then
    for rel_dir in "${NPM_MODULE_DIRS[@]}"; do
        slug="$(printf '%s' "${rel_dir}" | tr '/' '-' | tr '_' '-')"
        vol_name="${PROJECT_SHORT}-${LEAF}-${slug}-nm"
        NPM_NM_VOLUME_MOUNTS+="        ,\"source=${vol_name},target=${WORKSPACE_PATH}/${rel_dir}/node_modules,type=volume\"\n"
    done
fi

# Build the JSON fragment for the host-mount repos collected above: one bind
# mount each, from the host source dir to its workspace path in the container.
# Same leading-comma style as NPM_NM_VOLUME_MOUNTS so it appends cleanly after
# the fixed mounts. An empty placeholder dir is created inside the story
# workspace so the bind has a mountpoint within the workspaceMount; it stays
# empty on the host (the bind overlays the real source at container runtime),
# so disposing the workspace never touches the host source directory.
HOST_MOUNT_BINDS=""
# find(1) prune expression (injected into post-create.sh's node_modules chown)
# that keeps that scan out of the bind-mounted host dirs. Empty when there are
# no host-mount repos.
HOST_MOUNT_PRUNE=""
if (( ${#HOST_MOUNT_REPOS[@]} > 0 )); then
    _prune_paths=""
    for repo in "${HOST_MOUNT_REPOS[@]}"; do
        mkdir -p "${WS_DIR}/${repo}"
        HOST_MOUNT_BINDS+="        ,\"source=${SOURCE_WS}/${repo},target=${WORKSPACE_PATH}/${repo},type=bind,consistency=cached\"\n"
        [[ -n "${_prune_paths}" ]] && _prune_paths+=" -o "
        _prune_paths+="-path ${WORKSPACE_PATH}/${repo}"
    done
    HOST_MOUNT_PRUNE="\\( ${_prune_paths} \\) -prune -o "
fi

# NO aggregator pom.xml at the workspace root.
# Subprojects' parent declarations (e.g. workflow-commons -> commons-web)
# don't carry an explicit <relativePath>, so Maven defaults to '../pom.xml'.
# An aggregator at the workspace root would match that path but be the WRONG
# parent, producing the well-known
#   "[ERROR] Maven model problem: 'parent.relativePath' ... points at <agg>
#    instead of <real-parent>"
# warnings on every Maven sync. We avoid this by listing each subproject's
# pom.xml in IntelliJ's MavenProjectsManager (see misc.xml below) and by
# letting our post-create.sh build each repo separately. No aggregator -> no
# false-parent shadow.

# carry CLAUDE.md and .claude into the new workspace so Claude Code has the same context
[[ -f "${SOURCE_WS}/CLAUDE.md" ]] && cp "${SOURCE_WS}/CLAUDE.md" "${WS_DIR}/"
[[ -d "${SOURCE_WS}/.claude"   ]] && cp -R "${SOURCE_WS}/.claude" "${WS_DIR}/"

# Project-local Claude Code overrides that ONLY apply inside this devcontainer.
# - permissions.defaultMode=bypassPermissions: skip approval prompts. Container
#   is a sandbox, all tool calls go through it; loosening permissions here
#   doesn't loosen anything on the host. settings.local.json is the
#   per-machine override layer that doesn't touch settings.json from the
#   source workspace's .claude/.
mkdir -p "${WS_DIR}/.claude"
cat > "${WS_DIR}/.claude/settings.local.json" <<'JSON'
{
    "permissions": {
        "defaultMode": "bypassPermissions"
    }
}
JSON

# Welcome file at the workspace root. Named README.md (not WELCOME.md) so
# IntelliJ's "open project README on first open" heuristic targets THIS file
# instead of descending into the imported Maven modules and surfacing
# project/README.md. The heuristic prefers a README at project basePath
# over module-level READMEs, so putting our welcome content here is the
# simplest reliable way to make it auto-open. The story workspace root is not
# a git repo (only the sub-directories are), so this README isn't shared and
# never conflicts with the team-facing READMEs inside project folders.
#
# Content lives in README.md.tpl next to this script; edit it there to
# customise the welcome text without touching this script.
# __PORT_TABLE_ROWS__ is multi-line so it is spliced in via bash first;
# substitute_placeholders (sed) handles the remaining __*__ tokens.
cp "${SCRIPT_DIR}/README.md.tpl" "${WS_DIR}/README.md"
_readme_content=$(<"${WS_DIR}/README.md")
_readme_content="${_readme_content/__PORT_TABLE_ROWS__/${PORT_TABLE_ROWS}}"
printf '%s\n' "${_readme_content}" > "${WS_DIR}/README.md"

# Pre-seed IntelliJ workspace state:
#   - TerminalProjectOptionsProvider pins the Terminal's start directory to
#     the workspace root. Without it, IntelliJ picks one of the imported
#     Maven modules as the cwd.
#
# We deliberately do NOT touch the auto-README opener anymore. We *want* it to
# fire now, because we placed README.md at the workspace root (above) -- the
# heuristic prefers a README at project basePath over module-level READMEs, so
# our welcome doc wins. Previous attempts at FileEditorManager pinning broke
# IntelliJ Gateway 2026.1 (it discarded the entire workspace.xml when it
# considered the block malformed), so we lean on IntelliJ's own behavior
# instead of fighting it.
mkdir -p "${WS_DIR}/.idea"
cat > "${WS_DIR}/.idea/workspace.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
    <component name="TerminalProjectOptionsProvider">
        <option name="myStartingDirectory" value="$PROJECT_DIR$" />
    </component>
    <!-- "Actions on Save" toggles (FormatOnSaveOptions, OptimizeOnSaveOptions)
         are intentionally NOT seeded. Spawned workspaces serve developers
         with different formatting preferences; some run Spotless / Eclipse
         Code Formatter via manual mvn invocations, some want automatic
         format-on-save. Forcing either via the template would override the
         user's preference. Each developer enables what they want via
         Settings &gt; Tools &gt; Actions on Save in their freshly opened
         workspace. The README.md at the workspace root documents the
         choices. -->
</project>
XML

# Give IntelliJ a distinctive project name even though every story container mounts
# the workspace at the same ${WORKSPACE_PATH} path (we keep that path constant
# for shared Claude memory). IntelliJ reads .idea/.name and uses it for the window
# title, the workspace selector, and the macOS Cmd-Tab list.
mkdir -p "${WS_DIR}/.idea"
echo "${PROJECT_SHORT} ${LEAF}" > "${WS_DIR}/.idea/.name"

# Pre-set the project SDK so opening a Java file in IntelliJ doesn't trigger a
# "Project JDK is not defined" prompt. JDK 21 lives at
# /usr/lib/jvm/msopenjdk-current in the Microsoft Java base image; IntelliJ's
# auto-detection registers it under the name "21" in jdk.table.xml. If a given
# IntelliJ version picks a different name (e.g. "msopenjdk-21"), this entry
# still won't match and the user has to set it once via Project Structure --
# IntelliJ then rewrites misc.xml itself.
# Build the MavenProjectsManager originalFiles list at spawn time so it
# only contains the poms whose source repos actually got checked out.
# Length-guard: bash 3.2 + set -u fail on empty array expansion.
MAVEN_POMS_LIST=""
MAVEN_BUILD_COMMANDS=""
if (( ${#BUILD_ENTRIES[@]} > 0 )); then
    for entry in "${BUILD_ENTRIES[@]}"; do
        r="${entry%%:*}"
        cmd="${entry#*:}"
        [[ -f "${WS_DIR}/${r}/pom.xml" ]] && \
            MAVEN_POMS_LIST+="                <option value=\"\$PROJECT_DIR\$/${r}/pom.xml\" />"$'\n'
        if [[ "${BUILD_MODE}" == "raw" ]]; then
            # BUILDS style: the value is always a raw bash command, run verbatim
            # inside the repo dir. No mvn/MVN_FLAGS wrapping -- Maven users write
            # "mvn ..." themselves.
            MAVEN_BUILD_COMMANDS+="[[ -d ${r} ]] && (cd ${r} && ${cmd})"$'\n'
        elif [[ "${cmd}" == '$'* ]]; then
            # MAVEN_BUILDS style, raw-command form: a value starting with '$' is
            # not a Maven goal but an arbitrary bash command run verbatim inside
            # the repo dir (for repos with no parent pom but several sub-dir
            # poms, e.g. "repo:$ cd a; mvn install; cd ../b; mvn install").
            # Everything after the leading '$' (whitespace trimmed) runs as-is --
            # MVN_FLAGS is NOT injected, the value spells out its own mvn calls.
            raw="${cmd#\$}"
            raw="${raw#"${raw%%[![:space:]]*}"}"   # trim leading whitespace
            MAVEN_BUILD_COMMANDS+="[[ -d ${r} ]] && (cd ${r} && ${raw})"$'\n'
        else
            # MAVEN_BUILDS style, mvn-goal form: inject `mvn ${MVN_FLAGS}`.
            MAVEN_BUILD_COMMANDS+="[[ -d ${r} ]] && (cd ${r} && mvn \${MVN_FLAGS} ${cmd})"$'\n'
        fi
    done
fi
MAVEN_BUILD_COMMANDS="${MAVEN_BUILD_COMMANDS%$'\n'}"

cat > "${WS_DIR}/.idea/misc.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
    <!-- Tell IntelliJ which pom.xml files to import. We list each subproject
         separately rather than pointing at a single workspace-root aggregator,
         because the subprojects' parent declarations have no explicit
         relativePath and Maven would falsely treat any root pom as their
         parent (and complain on every sync). With a flat list, IntelliJ
         imports each as its own top-level Maven project; transitive deps
         go through the local Maven repo as usual. -->
    <component name="MavenProjectsManager">
        <option name="originalFiles">
            <list>
${MAVEN_POMS_LIST}            </list>
        </option>
    </component>
    <component name="ProjectRootManager" version="2" languageLevel="JDK_21" default="true" project-jdk-name="21" project-jdk-type="JavaSDK">
        <output url="file://\$PROJECT_DIR\$/out" />
    </component>
</project>
XML

# DELIBERATELY NOT seeding .idea/spotless-applier.xml here.
#
# Spotless Applier (Lipiridi, v1.2.3) has two upstream bugs that surface in
# the ijent-based Dev Container mode introduced in JetBrains Gateway 2025.x:
#   1. SpotlessOnSaveOptions.getInstance() lazy-loads on the save listener path
#      and triggers PathMacroManager.expandPaths() -> MavenUtil resolving the
#      default local Maven repository via EelProvider.toEelApiBlocking() on EDT.
#      Eel asserts "no blocking calls on EDT" and the save crashes with
#      IllegalStateException.
#   2. The -DspotlessIdeHook=<file> argument is built from VirtualFile.getPath()
#      without Eel mapping, so it ends up as the literal virtual scheme
#      //$devcontainer.ij/<hash>@/workspaces/... which the in-container mvn
#      process cannot resolve -> notification says "Spotless applied" but the
#      file is unchanged.
# Both bugs only manifest in ijent mode; on host the plugin works fine because
# there is no Eel layer in between.
#
# Seeding .idea/spotless-applier.xml with myRunOnSave=true would cause bug 1
# on every first save in a new workspace. Until the plugin learns Eel (or the
# user switches to classic-Gateway-backend mode), the file is intentionally
# not created. Use IntelliJ's built-in "Reformat code" / "Optimize imports"
# Actions on Save (Settings -> Tools -> Actions on Save) plus a pre-commit
# 'mvn spotless:apply' instead.

# Enable annotation processing globally so IntelliJ stops asking "Enable
# Lombok?" when opening a Java file with @Data / @Builder / @Slf4j. The
# default profile applies to every module unless an explicit per-module
# profile is defined, so this single entry covers the whole reactor.
cat > "${WS_DIR}/.idea/compiler.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
    <component name="CompilerConfiguration">
        <annotationProcessing>
            <profile default="true" name="Default" enabled="true" />
        </annotationProcessing>
    </component>
</project>
XML

# Pre-create Spring Boot run configurations for the four main apps so a
# click in IntelliJ's run dropdown launches them with the right Spring
# profiles. IntelliJ still auto-detects @SpringBootApplication classes and
# offers its own (profileless) entries alongside.
mkdir -p "${WS_DIR}/.idea/runConfigurations"

# Copy each run-config XML from dev-containers/runConfigurations/ into the
# new workspace's .idea/runConfigurations/ directory. The substitute-
# placeholders pass below fills in port numbers etc. Filenames are listed
# in RUN_CONFIGS (.env.sh); add/remove/reorder entries there to change
# which run configs the new workspace gets.
#
# Conventions in the XML files (so they all behave consistently inside the
# remote backend):
#   - PASS_PARENT_ENVS=false: do NOT forward macOS-side env vars (HOME, PATH,
#     JAVA_HOME, LC_ALL, ...) from IntelliJ's frontend into the remote JVM.
#     Otherwise they overwrite the container's containerEnv, breaking
#     anything that depends on a Linux-side path or our DOCKER_API_VERSION.
#   - DOCKER_API_VERSION as both env (<envs>) and JVM system property
#     (VM_PARAMETERS): docker-java reads either, but IntelliJ's env passing
#     to remote backends is sometimes flaky -- the JVM arg always lands.
#   - __PORT_NNNN__ placeholders: substituted to the port-offsetted host port
#     so OAuth callback / cockpit URIs resolve correctly when several stories
#     run in parallel.
RUN_CONFIG_SRC_DIR="${SCRIPT_DIR}/runConfigurations"
# Length-guard: bash 3.2 + set -u fail on empty array expansion.
if (( ${#RUN_CONFIGS[@]} > 0 )); then
for rc_file in "${RUN_CONFIGS[@]}"; do
    src="${RUN_CONFIG_SRC_DIR}/${rc_file}"
    if [[ ! -f "${src}" ]]; then
        echo "Run-config source missing: ${src}" >&2
        echo "Check RUN_CONFIGS in .env.sh." >&2
        exit 1
    fi
    cp "${src}" "${WS_DIR}/.idea/runConfigurations/${rc_file}"
done
fi

# Ensure the shared memory directory exists on the host before the container mounts it.
# All story containers use ${WORKSPACE_PATH}, encoded by Claude Code as ${MEMORY_KEY}.
SHARED_MEMORY_DIR="${HOME}/.claude/projects/${MEMORY_KEY}/memory"
mkdir -p "${SHARED_MEMORY_DIR}"

# Resolve the host's glab config directory. glab is written in Go and uses
# os.UserConfigDir(), which returns DIFFERENT paths per OS:
#   - darwin: ~/Library/Application Support/glab-cli
#   - linux:  ~/.config/glab-cli (or \$XDG_CONFIG_HOME/glab-cli)
# Inside the container (Linux) glab looks at ~/.config/glab-cli, so we map the
# host's *actual* directory onto that target. Picking the right host source is
# the only OS-specific bit -- bind-mounting one onto the other lets the same
# config.yml flow between host and container regardless of platform.
# Fallback: if neither exists yet (fresh user, never ran glab anywhere), we
# create the linux-style path as a stub so the mount has a valid source. The
# user can then run 'glab auth login --hostname ${GLAB_HOSTNAME}' inside the
# container; that writes the config.yml back to the host via the bind mount.
GLAB_CONFIG_SRC=""
if [[ ${GLAB_ENABLED} -eq 1 ]]; then
    if [[ -d "${HOME}/Library/Application Support/glab-cli" ]]; then
        GLAB_CONFIG_SRC="${HOME}/Library/Application Support/glab-cli"
    elif [[ -d "${HOME}/.config/glab-cli" ]]; then
        GLAB_CONFIG_SRC="${HOME}/.config/glab-cli"
    else
        mkdir -p "${HOME}/.config/glab-cli"
        GLAB_CONFIG_SRC="${HOME}/.config/glab-cli"
        echo "note: no host glab config found, created stub at ${GLAB_CONFIG_SRC}"
        echo "      run 'glab auth login --hostname ${GLAB_HOSTNAME}' (host or container) to populate"
    fi
    echo "glab config source: ${GLAB_CONFIG_SRC}"
else
    echo "glab integration: disabled (GLAB_HOSTNAME and/or GLAB_VERSION empty in .env.sh)"
fi

# SSH-agent forwarding so SSH-key-based remotes (git@<host>:...) don't prompt
# for the key's passphrase on every operation. Two OS-specific paths:
#  - macOS Docker Desktop: exposes the host's ssh-agent at a magic socket
#    /run/host-services/ssh-auth.sock that's reachable from any container.
#    Docker Desktop sandboxes the host FS, so the host's real $SSH_AUTH_SOCK
#    path (e.g. /private/tmp/com.apple.launchd.*/Listeners on macOS) is not
#    bind-mountable directly.
#  - Linux: $SSH_AUTH_SOCK on the host is a Unix socket the container can
#    bind-mount directly.
# If neither is available we fall back to the macOS magic path -- the mount
# may not work, but it doesn't break anything and ssh just behaves like
# before (prompts for the passphrase as it does today).
case "$(uname -s)" in
    Darwin)
        SSH_AGENT_SRC="/run/host-services/ssh-auth.sock"
        ;;
    *)
        SSH_AGENT_SRC="${SSH_AUTH_SOCK:-/run/host-services/ssh-auth.sock}"
        ;;
esac
echo "ssh agent source: ${SSH_AGENT_SRC}"

# Host IANA timezone -> container TZ env var so Spring Boot (and every other
# JVM/tool) logs in the local timezone instead of the UTC default that ships
# with mcr.microsoft.com/devcontainers/base. Java's TimeZone.getDefault()
# honors $TZ first, then /etc/timezone, then /etc/localtime; setting TZ at
# PID-1 (containerEnv) is the least invasive of the three and works without
# any tzdata gymnastics in the Dockerfile (the MS base image already ships it).
# Detection: macOS symlinks /etc/localtime under /var/db/timezone/zoneinfo/,
# Linux either symlinks under /usr/share/zoneinfo/ or writes the name to
# /etc/timezone. Fallback is UTC, which just preserves today's behavior.
HOST_TZ=""
if [[ -L /etc/localtime ]]; then
    HOST_TZ="$(readlink /etc/localtime | sed -E 's|.*/zoneinfo/||')"
fi
if [[ -z "${HOST_TZ}" && -r /etc/timezone ]]; then
    HOST_TZ="$(tr -d '[:space:]' < /etc/timezone)"
fi
HOST_TZ="${HOST_TZ:-UTC}"
echo "host timezone:    ${HOST_TZ}"

# .devcontainer
mkdir -p "${WS_DIR}/.devcontainer"

# Resolve the host's ~/.npmrc into the workspace so post-create.sh can copy it
# into /home/vscode/.npmrc inside the container. We tried bind-mounting the host
# file directly (/tmp/host-npmrc) but the mount didn't survive in JetBrains'
# devcontainer setup -- some Docker configurations put a tmpfs over /tmp which
# hides binds. Going through the workspace bind avoids the issue.
#
# We do two things here:
#   1. Strip macOS absolute paths (/Users/...), which would break npm in Linux.
#   2. Substitute token placeholders (${TOKEN_NAME} for each FORWARDED_ENV_VAR) with values from
#      this shell -- so the resolved npmrc has *literal* tokens. This is the
#      reliable path for getting auth into the container; remoteEnv forwarding
#      worked unevenly across IntelliJ launch contexts.
# The resolved file holds tokens in plaintext under the story workspace dir.
# That's acceptable for personal dev workspaces (the path is below your $HOME),
# but never commit it -- the workspace isn't itself a git repo, so Git won't
# see it, but be aware if you tar/share the directory.
HOST_NPMRC="${HOME}/.npmrc"
if [[ -f "${HOST_NPMRC}" ]]; then
    # Build a sed -e expression per forwarded var. Each substitution replaces
    # the literal placeholder ${VAR} in the npmrc with the current shell's
    # value (or empty if unset). Empty FORWARDED_ENV_VARS = pure passthrough
    # (still useful: the macOS-path strip below kicks in either way).
    if [[ ${#FORWARDED_ENV_VARS[@]} -gt 0 ]]; then
        npmrc_sed_args=()
        for var in "${FORWARDED_ENV_VARS[@]}"; do
            npmrc_sed_args+=(-e "s|\${${var}}|${!var:-}|g")
        done
        sed "${npmrc_sed_args[@]}" "${HOST_NPMRC}"
    else
        # No token placeholders to substitute -- just pass through. cat avoids
        # bash 3.2's empty-array trap under set -u that 'sed "${arr[@]}"' would
        # hit when npmrc_sed_args is empty.
        cat "${HOST_NPMRC}"
    fi \
        | grep -v '/Users/' \
        > "${WS_DIR}/.devcontainer/host-npmrc.resolved"
    chmod 600 "${WS_DIR}/.devcontainer/host-npmrc.resolved"
    echo "wrote .devcontainer/host-npmrc.resolved (tokens substituted from this shell)"
else
    echo "note: no ~/.npmrc on host -- npm in the container will use defaults only"
fi

# Custom Dockerfile so we can patch the base image *before* devcontainer features run.
# The MS Java base image carries an apt source for the Yarn Debian repo whose signing
# key (NO_PUBKEY 62D54FD4003F6525) is expired. That makes every subsequent apt-get
# update inside any feature install (docker-in-docker etc.) fail with exit code 100.
# We don't need Yarn (Node + npm are provided by the node feature), so we simply drop
# the dead repo and refresh the package lists.
#
# We also bake in 'glab' (GitLab CLI) here, so any 'gitlab' Claude skill works
# straight from the container. Installed as a static binary from the official
# GitLab release tarball; arch is auto-detected (amd64 vs arm64 Macs). The host's
# glab config directory is bind-mounted below; spawn-workspace.sh resolves the
# right host path (macOS: ~/Library/Application Support/glab-cli, Linux:
# ~/.config/glab-cli) so login state is shared bidirectionally.
cat > "${WS_DIR}/.devcontainer/Dockerfile" <<'DOCKERFILE'
FROM __BASE_IMAGE__

# socat       -- post-start.sh exposes the docker socket on TCP 127.0.0.1:2375
#                so tools that prefer DOCKER_HOST=tcp://... have a backup endpoint.
# openssh-server -- lets IntelliJ's Database tool reach the in-container DB through
#                an SSH tunnel. In ijent Dev Container mode the IDE runs on the host
#                and its Database plugin cannot introspect a docker-in-docker DB
#                directly (it execs the host JBR path inside the container -> ENOENT).
#                An SSH-tunnel data source sidesteps that: the JDBC driver runs on the
#                host, the TCP hop is tunnelled into the container where 127.0.0.1
#                resolves to the DB. post-start.sh configures + starts sshd.
RUN rm -f /etc/apt/sources.list.d/yarn.list /etc/apt/keyrings/yarn.gpg \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        socat ca-certificates curl openssh-server \
 && rm -rf /var/lib/apt/lists/*

# Newer git than the base image ships. The MS devcontainer base images
# typically carry git 2.39 (Debian bookworm) which predates the credential
# helper "authtype" capability (added in 2.46). Without authtype support,
# git falls back to HTTP Basic auth when a helper returns an empty username
# alongside a Bearer-style token (which is exactly what 'glab auth
# git-credential' returns for GitLab token auth). The result is a password
# prompt on every git operation despite the helper being wired correctly.
# Installing a recent git fixes this once and for all.
#
# Source selection is distro-aware so the Dockerfile works on both Debian
# (apt backports) and Ubuntu (git-core PPA) bases:
RUN set -eux; \
    . /etc/os-release; \
    if [ "$ID" = "debian" ]; then \
        echo "deb http://deb.debian.org/debian ${VERSION_CODENAME}-backports main" \
            > /etc/apt/sources.list.d/${VERSION_CODENAME}-backports.list; \
        apt-get update; \
        apt-get install -y -t ${VERSION_CODENAME}-backports --no-install-recommends git; \
    elif [ "$ID" = "ubuntu" ]; then \
        apt-get update; \
        apt-get install -y --no-install-recommends software-properties-common; \
        add-apt-repository -y ppa:git-core/ppa; \
        apt-get update; \
        apt-get install -y --no-install-recommends git; \
    else \
        echo "unsupported base distro: $ID -- adapt Dockerfile manually" >&2; \
        exit 1; \
    fi; \
    git --version; \
    rm -rf /var/lib/apt/lists/*

# __GLAB_BLOCK_START__
# glab (GitLab CLI). Pinned to a known-good version; bump GLAB_VERSION in .env.sh.
# Release URL pattern: gitlab.com/gitlab-org/cli/-/releases/v<v>/downloads/glab_<v>_linux_<arch>.tar.gz
ARG GLAB_VERSION=__GLAB_VERSION__
RUN set -eux; \
    deb_arch="$(dpkg --print-architecture)"; \
    case "$deb_arch" in \
        amd64) glab_arch=x86_64 ;; \
        arm64) glab_arch=arm64  ;; \
        *) echo "unsupported arch: $deb_arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${glab_arch}.tar.gz" \
        -o /tmp/glab.tgz; \
    tar -xzf /tmp/glab.tgz -C /tmp; \
    install -m 0755 /tmp/bin/glab /usr/local/bin/glab; \
    rm -rf /tmp/glab.tgz /tmp/bin; \
    /usr/local/bin/glab --version
# __GLAB_BLOCK_END__
DOCKERFILE

cat > "${WS_DIR}/.devcontainer/devcontainer.json" <<'JSON'
{
    "name": "__PROJECT_NAME__-${localWorkspaceFolderBasename}",
    "build": { "dockerfile": "Dockerfile" },

    // runArgs feed straight to `docker run`. We use this rather than
    // forwardPorts/appPort for port mappings because:
    //  - "forwardPorts" interprets "host:port" as <service-name>:<port>
    //    (compose-style), not <host>:<container>, so it can't express the
    //    offset mapping we want.
    //  - "appPort" works but doesn't show in JetBrains' Services view.
    //  - "runArgs -p" gives a real Docker port-publish that JetBrains picks
    //    up automatically and any external tool (curl from another shell,
    //    Postman, ...) can reach without going through the IDE.
    "runArgs": [
        "--name", "__PROJECT_SHORT__-__LEAF__",
        __PORT_RUNARGS__
    ],

    "features": {
        "ghcr.io/devcontainers/features/git:1": {},
        "ghcr.io/devcontainers/features/java:1": { "version": "none", "installMaven": "true" },
        "ghcr.io/devcontainers/features/node:1": { "version": "__NODE_FEATURE_VERSION__" },
        "ghcr.io/devcontainers/features/docker-in-docker:2": { "moby": false }
    },

    // Workspace mounts at the same path in every story container -> Claude Code's
    // path-encoded project key is identical, which is what makes the shared-memory
    // bind below actually align across containers.
    "workspaceFolder": "__WORKSPACE_PATH__",
    "workspaceMount": "source=${localWorkspaceFolder},target=__WORKSPACE_PATH__,type=bind,consistency=cached",

    // Make sure all bind targets exist on the host before the container starts.
    // glab-cli's source dir is resolved by spawn-workspace.sh (macOS uses
    // ~/Library/Application Support/glab-cli, Linux uses ~/.config/glab-cli)
    // and pre-created there, so no mkdir needed here.
    "initializeCommand": "mkdir -p ~/.m2 ~/.ssh ~/.claude ~/.claude/projects/__MEMORY_KEY__/memory && touch ~/.claude.json",

    // Mount order matters: deeper paths must come AFTER their parents so they take
    // precedence. The layering is:
    //   1. ~/.claude               -> shared by default (login, agents, commands, ...)
    //   2. named volume per story  -> overrides per-project state (history, todos)
    //   3. shared memory bind      -> overrides only the memory/ subfolder back to shared
    "mounts": [
        // Worktree path resolution: a worktree's .git file says
        //   "gitdir: <host-path>/<repo>/.git/worktrees/<name>"
        // and the source repo's worktree metadata back-references the worktree's
        // location on disk. Both paths use the host's absolute path. We mount
        // both the source workspace AND the story workspace at their host paths
        // inside the container so those references resolve. Without these,
        // git in the container reports "fatal: not a git repository" on every
        // worktree, the 'branches' helper shows '?', and IntelliJ/Maven get
        // confused about module structure.
        "source=__SOURCE_WS__,target=__SOURCE_WS__,type=bind",
        "source=${localWorkspaceFolder},target=${localWorkspaceFolder},type=bind",

        "source=${localEnv:HOME}/.ssh,target=/home/vscode/.ssh,type=bind,readonly",
        "source=${localEnv:HOME}/.m2,target=/home/vscode/.m2,type=bind",
        // __GLAB_BLOCK_START__
        // glab CLI config (token for the configured GitLab host). Bind-mounted
        // rw so the login is shared between host and container -- 'glab auth
        // login' run in either place persists to the same config.yml. Source
        // path is OS-specific on the host (macOS: ~/Library/Application Support/
        // glab-cli, Linux: ~/.config/glab-cli) and resolved by spawn-
        // workspace.sh; target is always the linux-style path that glab
        // looks at inside the container.
        "source=__GLAB_CONFIG_SRC__,target=/home/vscode/.config/glab-cli,type=bind",
        // __GLAB_BLOCK_END__
        // SSH-agent socket forwarding: host's ssh-agent (with cached passphrase-
        // protected keys) is reachable inside the container at /ssh-agent. The
        // source path is OS-specific and resolved by spawn-workspace.sh:
        //  - macOS Docker Desktop magic socket: /run/host-services/ssh-auth.sock
        //  - Linux: $SSH_AUTH_SOCK from the host
        // SSH_AUTH_SOCK env var (containerEnv below) points ssh at this socket.
        "source=__SSH_AGENT_SRC__,target=/ssh-agent,type=bind",
        "source=${localEnv:HOME}/.claude.json,target=/home/vscode/.claude.json,type=bind",
        "source=${localEnv:HOME}/.claude,target=/home/vscode/.claude,type=bind",
        "source=__PROJECT_SHORT__-claude-project-${devcontainerId},target=/home/vscode/.claude/projects/__MEMORY_KEY__,type=volume",
        "source=${localEnv:HOME}/.claude/projects/__MEMORY_KEY__/memory,target=/home/vscode/.claude/projects/__MEMORY_KEY__/memory,type=bind"
        // host-mounted repos: REPOS entries with an empty base-ref are plain
        // host directories (not git worktrees), bind-mounted straight in at
        // their workspace path. Generated by spawn-workspace.sh from REPOS.
__HOST_MOUNT_BINDS__
        // node_modules volumes: one Docker named volume per npm module. These are
        // generated by spawn-workspace.sh from the package.json files found in
        // the workspace. Named volumes bypass the Virtualization.framework XPC
        // bind-mount bridge, eliminating the I/O bottleneck that makes npm
        // 10-100x slower on macOS. dispose-workspace.sh removes them automatically.
__NPM_NM_VOLUME_MOUNTS__
    ],

    "remoteUser": "vscode",

    "containerEnv": {
        "JAVA_HOME": "/usr/lib/jvm/msopenjdk-current",
        "MAVEN_OPTS": "-Xmx2g",
        // C.UTF-8 silences "manpath: can't set the locale" and similar
        // warnings on every shell start. The MS base image doesn't ship
        // glibc locales by default; C.UTF-8 is always available.
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        // Docker 25.0 raised its minimum supported API version from 1.24
        // to 1.40. Testcontainers' embedded docker-java client opens the
        // connection with API version 1.32 (its older default) and gets
        // rejected before negotiation. Setting this here (containerEnv,
        // PID-1 level) makes every child process see it, including IDE
        // run configs that strip remoteEnv overrides.
        "DOCKER_API_VERSION": "1.44",
        // Caveman plugin: pin the mode to 'full' (default caveman speak,
        // ~75% token cut) so it doesn't drift to lite/ultra across sessions.
        // The plugin's caveman-config resolver checks this env var first.
        "CAVEMAN_DEFAULT_MODE": "full",
        // Tell ssh inside the container where to find the agent socket
        // (forwarded from the host via the mount above). Result: ssh uses
        // the host's already-unlocked key for git over SSH without ever
        // prompting for the passphrase.
        "SSH_AUTH_SOCK": "/ssh-agent",
        // Host IANA timezone (detected at spawn time). Java reads TZ first
        // in TimeZone.getDefault(), so Spring Boot logs land in local time
        // instead of the UTC default of the devcontainer base image.
        "TZ": "__HOST_TZ__"
    },

    // remoteEnv has higher precedence than containerEnv (and any feature's
    // containerEnv) for processes started by the remote daemon -- IntelliJ's
    // terminal, the Claude plugin, lifecycle scripts run by the dev daemon.
    //
    // - JAVA_HOME: restated here because the java:1 feature (needed only for
    //   Maven via SDKMAN) can leave its own JAVA_HOME pointing at an empty
    //   SDKMAN candidate directory when version=none.
    // - FORWARDED_ENV_VARS from .env.sh: forwarded from host so that any
    //   '${TOKEN}'-style placeholder in the user's ~/.npmrc / ~/.m2/settings.xml
    //   resolves inside the container. Otherwise npm install of private
    //   packages and Maven resolution from private repos fail with 401.
    //   These read from the env that LAUNCHED IntelliJ (or that ran spawn-
    //   workspace.sh). If empty, run with .envrc loaded ('direnv allow' in
    //   the source workspace, then start IntelliJ from that shell).
    "remoteEnv": {
        "JAVA_HOME": "/usr/lib/jvm/msopenjdk-current"__REMOTE_ENV_FORWARDED__
    },

    // Port labels for the JetBrains Services view. Keys are the container-side
    // port numbers; the host-side port comes from runArgs -p above. Suppress
    // the auto-forward notification that pops up every time a service starts.
    // Labels come from PORT_LABELS in .env.sh.
    "portsAttributes": {
        __PORTS_ATTRS__
    },

    // Make the IDE wait for postCreateCommand (Maven builds, npm install)
    // before attaching. Default 'updateContentCommand' lets JetBrains open
    // the project window while postCreate is still running, which makes the
    // initial reactor look empty until Maven catches up.
    "waitFor": "postCreateCommand",

    "postCreateCommand": "__WORKSPACE_PATH__/.devcontainer/post-create.sh",

    // Re-runs every time the container starts (postCreate runs only once).
    // Used to kick dockerd: the docker-in-docker feature installs an init
    // script meant to run as the container's entrypoint, but JetBrains
    // Gateway overrides the entrypoint, so the daemon doesn't auto-start
    // and Testcontainers fails with "no Docker environment found".
    "postStartCommand": "__WORKSPACE_PATH__/.devcontainer/post-start.sh",

    "customizations": {
        "jetbrains": {
            "backend": "IntelliJ",
            // Gateway pre-installs these into the remote backend on first connect.
            //   - Docker (id: "Docker"): the full marketplace Docker plugin.
            //     Gateway's own bundled backend only ships "clouds-docker-gateway"
            //     (a stripped bridge that handles the Services view) WITHOUT the
            //     compose content-module -- so compose.yaml gets no file-type
            //     registration, no gutter Play buttons, and no "Docker Compose"
            //     entry under Run → Edit Configurations → +. Installing the
            //     full plugin fixes that.
            //   - YAML (id: "org.jetbrains.plugins.yaml"): the Docker plugin's
            //     compose sub-module declares <dependency module="intellij.yaml.
            //     backend"> -- without YAML the sub-module silently stays
            //     dormant even if Docker is loaded. JetBrains' remote backends
            //     don't bundle YAML by default.
            "plugins": [
                "Docker",
                "org.jetbrains.plugins.yaml",
                // Format-on-save in the remote project. Spotless Applier
                // (com.github.lipiridi.spotless-applier) does NOT work in
                // ijent mode -- it leaks Eel virtual paths into the mvn
                // command line and crashes on EDT during its first save
                // listener -- so we use "Adapter for Eclipse Code Formatter"
                // (Krasa) instead. It applies the project's
                // formatting_conventions.xml directly from inside the host
                // IDE, no Maven subprocess, no Eel layer. Combined with
                // FormatOnSaveOptions + OptimizeOnSaveOptions in
                // .idea/workspace.xml, save = reformat + optimize imports.
                //
                // NOTE: in ijent mode this list is hint-only -- the full IDE
                // runs on the HOST and uses the host's plugin set. Install
                // the Eclipse Code Formatter plugin once via Settings ->
                // Plugins -> Marketplace -> "Adapter for Eclipse Code
                // Formatter". The entry below is kept for forward-compat
                // with classic Gateway backend mode.
                "EclipseCodeFormatter"
            ]
        }
    }
}
JSON

# Build dynamic JSON fragments from .env.sh arrays. These are injected via the
# same sed-substitution pass below; we keep them as single-line strings so
# we don't have to wrestle with multi-line sed replacements on macOS.

# remoteEnv forwarded-vars snippet (leading comma + JSON keys for each var).
# Empty FORWARDED_ENV_VARS = empty snippet, which leaves the JSON valid
# (just "JAVA_HOME": "..." with nothing after).
REMOTE_ENV_FORWARDED=""
if [[ ${#FORWARDED_ENV_VARS[@]} -gt 0 ]]; then
    for var in "${FORWARDED_ENV_VARS[@]}"; do
        REMOTE_ENV_FORWARDED="${REMOTE_ENV_FORWARDED}, \"${var}\": \"\${localEnv:${var}}\""
    done
fi

# portsAttributes entries from PORT_LABELS ("port:label" pairs). Joined with
# commas; no trailing comma (JSON forbids it).
PORTS_ATTRS=""
if [[ ${#PORT_LABELS[@]} -gt 0 ]]; then
    for entry in "${PORT_LABELS[@]}"; do
        port="${entry%%:*}"
        label="${entry#*:}"
        [[ -n "${PORTS_ATTRS}" ]] && PORTS_ATTRS="${PORTS_ATTRS}, "
        PORTS_ATTRS="${PORTS_ATTRS}\"${port}\": { \"label\": \"${label}\", \"onAutoForward\": \"silent\" }"
    done
fi

# Substitute placeholders in the generated devcontainer.json and run configs
# (heredocs are quoted, so we do bash variable interpolation here instead).
# The path-style replacements (GLAB_CONFIG_SRC) use a separate sed pass with
# '|' as delimiter -- the path contains slashes (always) and may contain
# spaces ("Library/Application Support/..."), neither of which is safe in
# the default '/' delimiter form.
substitute_placeholders() {
    local file="$1"
    sed -i.bak \
        -e "s/__LEAF__/${LEAF}/g" \
        "${PORT_SED_ARGS[@]}" \
        -e "s|__PORT_RUNARGS__|${PORT_RUNARGS}|g" \
        -e "s/__PROJECT_NAME__/${PROJECT_NAME}/g" \
        -e "s/__PROJECT_SHORT__/${PROJECT_SHORT}/g" \
        -e "s|__WORKSPACE_PATH__|${WORKSPACE_PATH}|g" \
        -e "s|__SOURCE_WS__|${SOURCE_WS}|g" \
        -e "s/__MEMORY_KEY__/${MEMORY_KEY}/g" \
        -e "s|__BASE_IMAGE__|${BASE_IMAGE}|g" \
        -e "s/__GLAB_VERSION__/${GLAB_VERSION:-}/g" \
        -e "s/__NODE_FEATURE_VERSION__/${NODE_FEATURE_VERSION}/g" \
        -e "s/__GLAB_HOSTNAME__/${GLAB_HOSTNAME:-}/g" \
        -e "s|__REMOTE_ENV_FORWARDED__|${REMOTE_ENV_FORWARDED}|g" \
        -e "s|__PORTS_ATTRS__|${PORTS_ATTRS}|g" \
        -e "s|__GLAB_CONFIG_SRC__|${GLAB_CONFIG_SRC}|g" \
        -e "s|__SSH_AGENT_SRC__|${SSH_AGENT_SRC}|g" \
        -e "s|__HOST_TZ__|${HOST_TZ}|g" \
        -e "s/__PORT_OFFSET__/${PORT_OFFSET}/g" \
        -e "s/__SSH_HOST_PORT__/${SSH_HOST_PORT}/g" \
        -e "s/__FIRST_REPO__/${FIRST_REPO}/g" \
        "${file}"
    rm "${file}.bak"

    # Handle conditional GLAB blocks marked with __GLAB_BLOCK_START__ ...
    # __GLAB_BLOCK_END__ pairs in the template files. When GLAB_ENABLED=1,
    # strip just the marker lines (keep the content). When 0, drop both the
    # markers AND every line between them, so the resulting file is free of
    # the GitLab integration parts.
    if [[ ${GLAB_ENABLED} -eq 1 ]]; then
        sed -i.bak \
            -e '/__GLAB_BLOCK_START__/d' \
            -e '/__GLAB_BLOCK_END__/d' \
            "${file}"
    else
        sed -i.bak \
            -e '/__GLAB_BLOCK_START__/,/__GLAB_BLOCK_END__/d' \
            "${file}"
    fi
    rm "${file}.bak"
}
substitute_placeholders "${WS_DIR}/.devcontainer/devcontainer.json"
for rc in "${WS_DIR}"/.idea/runConfigurations/*.xml; do
    [[ -f "${rc}" ]] || continue
    substitute_placeholders "${rc}"
done

# Substitute __NPM_NM_VOLUME_MOUNTS__ with the actual volume mount JSON lines.
# substitute_placeholders uses sed which can only do single-line replacements;
# the node_modules volume mounts span multiple lines, so we use awk + a temp
# file here. The awk script replaces the placeholder line with the file's
# contents; if NPM_MODULE_DIRS is empty the temp file is empty and the
# placeholder line is simply removed.
{
    _nm_tmp="$(mktemp)"
    printf '%b' "${NPM_NM_VOLUME_MOUNTS}" > "${_nm_tmp}"
    awk -v mf="${_nm_tmp}" '
        /__NPM_NM_VOLUME_MOUNTS__/ {
            while ((getline line < mf) > 0) print line
            next
        }
        { print }
    ' "${WS_DIR}/.devcontainer/devcontainer.json" \
      > "${WS_DIR}/.devcontainer/devcontainer.json.nm_tmp"
    mv "${WS_DIR}/.devcontainer/devcontainer.json.nm_tmp" \
       "${WS_DIR}/.devcontainer/devcontainer.json"
    rm "${_nm_tmp}"
}

# Substitute __HOST_MOUNT_BINDS__ with the host-mount bind lines (same multi-line
# awk approach as the node_modules volumes above; empty -> placeholder removed).
{
    _hm_tmp="$(mktemp)"
    printf '%b' "${HOST_MOUNT_BINDS}" > "${_hm_tmp}"
    awk -v mf="${_hm_tmp}" '
        /__HOST_MOUNT_BINDS__/ {
            while ((getline line < mf) > 0) print line
            next
        }
        { print }
    ' "${WS_DIR}/.devcontainer/devcontainer.json" \
      > "${WS_DIR}/.devcontainer/devcontainer.json.hm_tmp"
    mv "${WS_DIR}/.devcontainer/devcontainer.json.hm_tmp" \
       "${WS_DIR}/.devcontainer/devcontainer.json"
    rm "${_hm_tmp}"
}

cat > "${WS_DIR}/.devcontainer/post-create.sh" <<'SH'
#!/usr/bin/env bash
# -E (errtrace): make the ERR trap fire inside functions, command
# substitutions and pipeline elements too, not just at the top level.
set -Eeuo pipefail

# The devcontainer lifecycle runner only reports "failed with exit code: 1" and
# swallows the failing command. This trap surfaces the real culprit -- the line
# number, the exact command, and the exit code -- so a failed warmup step is
# actually diagnosable from the build log.
trap 'rc=$?; echo "" >&2; echo "ERROR: post-create.sh failed (exit ${rc})" >&2; echo "  at line ${LINENO}: ${BASH_COMMAND}" >&2; exit ${rc}' ERR

# Discover a working JAVA_HOME and re-export it before any Maven invocation.
# The base image, the java:1 feature, and SDKMAN may each have their own idea
# of where Java lives; with version=none on the feature (we use it only for
# Maven), the feature's JAVA_HOME points at an empty SDKMAN candidate dir,
# which makes mvn exit with "JAVA_HOME is not defined correctly". Probe known
# locations and pick the first one that actually contains a JDK.
detect_java_home() {
    local candidate
    for candidate in \
        /usr/lib/jvm/msopenjdk-current \
        /usr/local/sdkman/candidates/java/current \
        /opt/java/openjdk; do
        if [[ -x "${candidate}/bin/javac" ]]; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

if JH="$(detect_java_home)"; then
    export JAVA_HOME="${JH}"
    echo "JAVA_HOME=${JAVA_HOME}"
else
    echo "ERROR: no JDK found at known locations (/usr/lib/jvm/msopenjdk-current, SDKMAN, /opt/java/openjdk)" >&2
    exit 1
fi

cd __WORKSPACE_PATH__

# Copy the resolved npmrc that spawn-workspace.sh produced. It already has
# macOS paths stripped and any forwarded token placeholders substituted with
# values from the spawn shell, so npm in the container can auth against
# private registries.
RESOLVED_NPMRC=__WORKSPACE_PATH__/.devcontainer/host-npmrc.resolved
if [[ -f "${RESOLVED_NPMRC}" ]]; then
    install -m 600 "${RESOLVED_NPMRC}" /home/vscode/.npmrc
    echo "npmrc installed from ${RESOLVED_NPMRC}"
else
    echo "WARN: ${RESOLVED_NPMRC} not found -- npm install of private packages will 401" >&2
fi

# install Claude Code globally — via login shell so npm/node from the Node feature
# are on PATH. No sudo: the Node feature makes /usr/local/share/nvm user-writable.
bash -lc "npm install -g @anthropic-ai/claude-code"

# named volume for per-story Claude project state is owned by root after first mount
sudo chown -R vscode:vscode /home/vscode/.claude/projects/__MEMORY_KEY__ || true

# Expose mvn and claude on /usr/local/bin so they work in IDE-spawned non-login
# shells (IntelliJ terminal, Claude plugin) where shell init is sometimes skipped.
# We resolve the real path through a login shell, which sources sdkman/nvm.
for cmd in mvn claude; do
    real="$(bash -lc "command -v ${cmd}" 2>/dev/null || true)"
    if [[ -n "${real}" ]]; then
        sudo ln -sf "${real}" "/usr/local/bin/${cmd}"
        echo "linked ${cmd} -> ${real}"
    else
        echo "WARN: ${cmd} not found via login shell, /usr/local/bin/${cmd} not created" >&2
    fi
done

# Tell git that worktrees mounted from the host are trusted, regardless of the
# UID on the files. macOS-mounted volumes appear with the host user's UID inside
# the container; if that doesn't match the vscode user, git refuses with
# "fatal: detected dubious ownership in repository". System-wide config so it
# applies to all users in the container.
sudo git config --system --add safe.directory '*'

# __GLAB_BLOCK_START__
# Use glab as git's credential helper for HTTPS pushes to the configured
# GitLab host (GLAB_HOSTNAME from .env.sh). glab is installed in the image
# and its config (with the auth token) is bind-mounted from the host, so
# the helper returns the stored token without prompting. Result: 'git push'
# over HTTPS to that host works silently.
#
# We do NOT wire glab's own 'glab auth git-credential' subcommand directly,
# because three things conspire to make plain wiring prompt for a password
# on every operation:
#   (a) glab declares 'capability[]=authtype' in its response but does not
#       use the authtype protocol's actual auth fields. git 2.46+ treats
#       this as a malformed response and falls through to a prompt.
#   (b) glab rejects 'get' requests whose 'username=<x>' field does not
#       match its OAuth-login state (empty username), erroring out with
#       'want "" but got "<x>"'. The repos here have URLs of the form
#       https://<user>@git.example.com/..., so git always passes the
#       URL-embedded username to the helper.
#   (c) GitLab expects 'oauth2' as the HTTP Basic username for OAuth-flow
#       tokens, not the user's own login name. Without the override, the
#       helper-returned empty username triggers git to fall back to the
#       URL username, which GitLab then rejects with 'HTTP Basic: Access
#       denied'.
# A tiny wrapper script handles all three.
mkdir -p /home/vscode
cat > /home/vscode/glab-creds.sh <<'WRAPPER'
#!/bin/sh
# git credential helper wrapper around 'glab auth git-credential'.
# See spawn-workspace.sh post-create.sh block for the why.
case "$1" in
    get)
        grep -v '^username=' \
            | glab auth git-credential get \
            | grep -v '^capability' \
            | awk -F= 'BEGIN{OFS=FS} /^username=/ {$2="oauth2"} {print}'
        ;;
    *)
        glab auth git-credential "$@"
        ;;
esac
WRAPPER
chmod +x /home/vscode/glab-creds.sh

# Register the wrapper as the credential helper for the GitLab host. The
# empty-helper line clears any inherited credential helper (e.g. a system-
# level credential cache) for this specific URL -- without it, git would
# invoke BOTH helpers and the first prompt-style one would still pop up.
# Prerequisite: the user must have run 'glab auth login --hostname <host>'
# on the host at least once (or once inside any container -- the config is
# shared via the bind mount).
git config --global --unset-all "credential.https://__GLAB_HOSTNAME__.helper" 2>/dev/null || true
git config --global --add "credential.https://__GLAB_HOSTNAME__.helper" ""
git config --global --add "credential.https://__GLAB_HOSTNAME__.helper" "!/home/vscode/glab-creds.sh"
# __GLAB_BLOCK_END__

# Align git's working-tree heuristics with the macOS host so the bind-mounted
# worktree doesn't look "dirty" inside the container.
#
# core.fileMode=false: macOS-Docker-Desktop bind mounts occasionally report
# different executable bits than the host's APFS does. With the Linux default
# (true) git treats those flips as file modifications, which during 'git
# rebase -i squash' surfaces as "Your local changes would be overwritten"
# even though the content is identical.
#
# core.autocrlf=input: matches the host's setting. With a mismatch, git in
# the container would convert line endings on checkout that the host left
# alone (or vice versa), making the same checkout look modified depending
# on which side last touched it.
git config --global core.fileMode false
git config --global core.autocrlf input

# Bind-mount stat-cache drift: macOS-Docker-Desktop reports different mtime
# nanoseconds / ctime / inode for the same file depending on whether the
# host or the container accessed it last. Git's default stat check (size +
# mtime-ns + ctime + inode) then flags "modified" mid-rebase even when md5
# is identical. 'git status' silently refreshes the stat cache so the tree
# looks clean from the prompt, but rebase sub-steps (merge-recursive) do
# NOT refresh, so a 'pick' or 'squash' that touches a drifted file aborts
# with "Your local changes would be overwritten by merge".
#
# core.checkStat=minimal : compare only size and second-precision mtime,
#                          ignore inode/ctime/ns drift
# core.trustctime=false  : ignore ctime entirely (still useful belt-and-
#                          suspenders since bind-mount ctime is unreliable)
git config --global core.checkStat minimal
git config --global core.trustctime false

# Install the caveman plugin (https://github.com/juliusbrussee/caveman) which
# trims ~75% of output tokens by talking like caveman. Mode is pinned to "full"
# via CAVEMAN_DEFAULT_MODE in containerEnv. Both commands are idempotent --
# re-running on an existing install no-ops. Uses 2>/dev/null||true so a
# transient marketplace fetch failure doesn't fail the entire post-create.
if command -v claude >/dev/null 2>&1; then
    echo "installing caveman plugin..."
    claude plugin marketplace add JuliusBrussee/caveman 2>/dev/null || true
    claude plugin install caveman@caveman 2>/dev/null || true
fi

# Locale + DOCKER_API_VERSION belt-and-suspenders.
#
# containerEnv sets these at PID 1 (inherited by every child process), but
# JetBrains' terminal opens an SSH-style channel that forwards macOS Terminal's
# locale (LC_CTYPE=UTF-8 -- glibc rejects this format with "manpath: can't
# set the locale") AFTER PID-1 env is applied, shadowing our LC_ALL. So we
# also write to two shell-rc layers:
#   - /etc/profile.d/zz-<PROJECT_SHORT>-env.sh : sourced by login shells via /etc/profile
#   - /etc/bash.bashrc append      : sourced by interactive non-login bashes
#                                    (which JetBrains' terminal usually is)
# The bash.bashrc layer runs AFTER SSH forwarding and reliably overrides.
sudo tee /etc/profile.d/zz-__PROJECT_SHORT__-env.sh >/dev/null <<'PROF'
export JAVA_HOME=/usr/lib/jvm/msopenjdk-current
export DOCKER_API_VERSION=1.44
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
unset LC_CTYPE
# Workspace shortcuts. WS holds the absolute workspace path, CDPATH lets
# 'cd <subdir>' jump straight into the workspace from anywhere. The leading
# '.' keeps relative cd-targets in the current directory winning over the
# workspace, so 'cd build' inside e.g. /tmp still does the local thing.
export WS=__WORKSPACE_PATH__
export CDPATH=".:__WORKSPACE_PATH__"
PROF
sudo chmod 644 /etc/profile.d/zz-__PROJECT_SHORT__-env.sh

if ! grep -q '# __PROJECT_SHORT__ container locale + docker overrides' /etc/bash.bashrc 2>/dev/null; then
    sudo tee -a /etc/bash.bashrc >/dev/null <<'BASHRC'

# __PROJECT_SHORT__ container locale + docker + java overrides. Sourced AFTER
# SDKMAN's init (which the java:1 feature with version=none drops onto
# interactive shells) so we win when SDKMAN points JAVA_HOME at /usr/local/
# sdkman/candidates/java/current -- a directory that doesn't exist when java
# isn't installed via SDKMAN. Also blocks macOS-Terminal SSH forwarding of
# LC_CTYPE=UTF-8 which glibc can't parse, and ensures DOCKER_API_VERSION is
# set even for IDE-spawned shells that don't go through /etc/profile.
export JAVA_HOME=/usr/lib/jvm/msopenjdk-current
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
unset LC_CTYPE
export DOCKER_API_VERSION=1.44
# Workspace shortcuts (see /etc/profile.d/zz-__PROJECT_SHORT__-env.sh).
export WS=__WORKSPACE_PATH__
export CDPATH=".:__WORKSPACE_PATH__"
BASHRC
fi

# /etc/environment is read by PAM at session start. Putting DOCKER_API_VERSION
# here means even IDE-launched processes that don't source bash rc files (e.g.
# JetBrains' Spring Boot run configs that bypass shell startup) inherit it
# from the session env. Append-only with a guard so we don't duplicate.
if ! grep -q '^DOCKER_API_VERSION=' /etc/environment 2>/dev/null; then
    echo 'DOCKER_API_VERSION=1.44' | sudo tee -a /etc/environment >/dev/null
fi

# docker-java reads ~/.docker-java.properties as one of its config sources, and
# Testcontainers reads ~/.testcontainers.properties. Both files trump env vars
# in some bootstrap paths (specifically the one that fails with "client
# version 1.32 is too old, minimum is 1.40" -- the project's docker-java
# initializes before its env vars have a chance to apply).
cat > /home/vscode/.docker-java.properties <<'PROPS'
api.version=1.44
PROPS

cat > /home/vscode/.testcontainers.properties <<'PROPS'
docker.client.strategy=org.testcontainers.dockerclient.UnixSocketClientProviderStrategy
testcontainers.reuse.enable=true
PROPS

chmod 644 /home/vscode/.docker-java.properties /home/vscode/.testcontainers.properties

# Convenience symlink so paths like ~/ws/pom.xml and Tab-completion off ~/ws/
# work in any shell, not just the workspace-rooted CDPATH. Forces overwrite
# so a stale link from a previous container survives. Lives next to the
# bind-mounted dotfiles in /home/vscode without touching them.
ln -sfn __WORKSPACE_PATH__ /home/vscode/ws

# 'branches' helper: prints the current branch of every worktree in the workspace.
# Quoted inner heredoc + placeholder for the workspace path: sed substitutes
# __WORKSPACE_PATH__ in the outer post-create.sh content (which sees through
# the quoted heredoc just fine), while ${dir} stays literal because the
# inner heredoc is quoted.
sudo tee /usr/local/bin/branches >/dev/null <<'BRANCHES'
#!/usr/bin/env bash
cd __WORKSPACE_PATH__ 2>/dev/null || exit 1
for dir in */; do
    [[ -e "${dir}.git" ]] || continue
    printf "  %-30s %s\n" "${dir%/}" "$(git -C "${dir}" branch --show-current 2>/dev/null || echo '?')"
done
BRANCHES
sudo chmod +x /usr/local/bin/branches

# Fix ownership of the per-module node_modules Docker named volumes.
# Each npm module's node_modules is mounted as a named volume (see
# devcontainer.json / NPM_NM_VOLUME_MOUNTS) so npm writes at Linux-native speed
# instead of through the slow macOS bind-mount. A freshly created named volume
# is owned by root:root, though, so npm running as vscode during the Maven
# warmup below can't write into it and dies with
#   EACCES: permission denied, mkdir '.../node_modules/@types'
# chown each mount-point to vscode up front. The find mirrors the module
# discovery in spawn-workspace.sh (package.json outside node_modules/.git), so
# it stays in sync with the volumes actually mounted -- no extra placeholder
# needed. Non-recursive is enough: npm creates everything below once it owns
# the mount root.
# The prune expression spliced in below (may be empty) skips any host-mounted
# repo dirs (REPOS entries with an empty base-ref): they carry no named-volume
# node_modules, and chowning anything inside them would rewrite ownership of the
# bind-mounted HOST files. The `if` (not `&&`) keeps a module without a
# node_modules dir from making the loop -- and thus the whole pipeline under
# `set -e`/`pipefail` -- exit non-zero.
echo "--- fixing node_modules volume ownership ---"
find __WORKSPACE_PATH__ __HOST_MOUNT_PRUNE__-name package.json \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -print0 2>/dev/null \
| while IFS= read -r -d '' pj; do
    nm="$(dirname "${pj}")/node_modules"
    if [[ -d "${nm}" ]]; then
        sudo chown vscode:vscode "${nm}"
    fi
done

# Optional project-specific initialization hook. Place initialize.sh next to
# spawn-workspace.sh in dev-containers/; spawn-workspace.sh copies it here.
# Runs with the workspace root as CWD, before the Maven warmup builds.
if [[ -f .devcontainer/initialize.sh ]]; then
    echo "--- running initialize.sh ---"
    bash .devcontainer/initialize.sh
fi

# Resolve build dependencies in order (BUILDS / MAVEN_BUILDS in .env.sh).
# Tests are skipped across the board so post-create stays fast -- the IDE just
# needs the reactor resolved; run tests on demand.
#
# Why three flags:
#   -Dmaven.test.skip=true : skips test-compile AND test phase at Maven-core
#                            level. Most aggressive; survives projects with
#                            custom test plugins that ignore -DskipTests.
#   -DskipTests            : explicit surefire skip, belt-and-suspenders.
#   -DskipITs              : explicit failsafe skip (integration-tests).
MVN_FLAGS="-B -ntp -Dspotless.check.skip=true -Dmaven.test.skip=true -DskipTests -DskipITs"
__MAVEN_BUILD_COMMANDS__

echo
echo "current branches:"
branches
echo
echo "post-create done."
SH
chmod +x "${WS_DIR}/.devcontainer/post-create.sh"
# MAVEN_BUILD_COMMANDS is multi-line; substitute via bash before sed takes over.
# __HOST_MOUNT_PRUNE__ is substituted the same way (it may be empty).
_pc=$(<"${WS_DIR}/.devcontainer/post-create.sh")
_pc="${_pc/__MAVEN_BUILD_COMMANDS__/${MAVEN_BUILD_COMMANDS}}"
_pc="${_pc/__HOST_MOUNT_PRUNE__/${HOST_MOUNT_PRUNE}}"
printf '%s\n' "${_pc}" > "${WS_DIR}/.devcontainer/post-create.sh"

# Copy optional initialization hook into the workspace's .devcontainer/.
# post-create.sh runs it before the Maven warmup builds if present.
if [[ -f "${SCRIPT_DIR}/initialize.sh" ]]; then
    cp "${SCRIPT_DIR}/initialize.sh" "${WS_DIR}/.devcontainer/initialize.sh"
    chmod +x "${WS_DIR}/.devcontainer/initialize.sh"
fi

# post-start.sh runs every time the container starts (postCreate is once-only).
# Its job: make sure dockerd is up so Testcontainers / the simulator stack can
# find a Docker environment. The docker-in-docker feature ships an entrypoint
# init script, but JetBrains Gateway replaces the container entrypoint with
# its own backend launcher, so the init never runs.
cat > "${WS_DIR}/.devcontainer/post-start.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

# Step 1: make sure dockerd is up (via docker-init.sh fallback to direct
# invocation). The DinD feature relies on its entrypoint to start dockerd,
# but JetBrains Gateway overrides the entrypoint, so we kick it ourselves.
if ! docker version >/dev/null 2>&1; then
    echo "starting dockerd in background..."
    if [[ -x /usr/local/share/docker-init.sh ]]; then
        sudo /usr/local/share/docker-init.sh >/tmp/dockerd.log 2>&1 &
    else
        sudo nohup dockerd \
            --host=unix:///var/run/docker.sock \
            >/tmp/dockerd.log 2>&1 &
    fi

    # wait up to 20s for the daemon to answer
    for _ in {1..40}; do
        sleep 0.5
        docker version >/dev/null 2>&1 && break
    done

    if ! docker version >/dev/null 2>&1; then
        echo "WARN: dockerd did not come up within 20s -- check /tmp/dockerd.log" >&2
        exit 0
    fi
    echo "dockerd is up"
else
    echo "dockerd was already up"
fi

# Step 2: relax socket perms so any user / IDE-spawned process can reach it.
# DinD usually creates /var/run/docker.sock as 0660 root:docker; in practice
# we've seen test runners launched from IntelliJ run configs not pick up the
# docker group, so a permissive socket is the simplest cure.
sudo chmod a+rw /var/run/docker.sock 2>/dev/null || true

# Step 3: expose the socket on TCP 127.0.0.1:2375 via socat. This is a backup
# endpoint for tools that set DOCKER_HOST=tcp://... (matches the GitLab CI
# dind pattern). socat shells out to the unix socket so it follows whatever
# perms we just set in step 2.
if ! curl -sf --max-time 2 http://127.0.0.1:2375/version >/dev/null 2>&1; then
    if command -v socat >/dev/null 2>&1; then
        nohup socat TCP-LISTEN:2375,bind=127.0.0.1,reuseaddr,fork \
                    UNIX-CONNECT:/var/run/docker.sock \
                    >/tmp/socat-docker.log 2>&1 &
        echo "socat exposing docker on tcp://127.0.0.1:2375"
    else
        echo "note: socat not installed -- TCP fallback unavailable"
    fi
fi

# Step 4: turn off IntelliJ's "Use safe write" in every existing remote backend
# config dir. Safe write saves via write-tmp + rename, which on macOS Docker
# bind-mounts produces a new inode + ctime drift that IntelliJ's external-
# change detector reads as "someone else touched the file" -> "Datei wurde
# extern geaendert" dialog right after every save. Disabling it makes the
# editor write the file in place (open+truncate+write), preserving the inode.
#
# NOTE: this block only fires for the CLASSIC Gateway mode where a full IDE
# backend runs INSIDE the container and writes its config to
# ~/.config/JetBrains/RemoteDev-IU/<hash>/options/. In the current ijent-based
# Dev Container mode (Gateway 2025.x / 2026.x default) the IDE runs on the
# HOST and ijent runs in the container as a thin file proxy -- no container-
# side config dir exists, so the glob below is empty and the loop is a no-op.
# In ijent mode the equivalent fix is to disable "Use safe write" ONCE in the
# host IDE (Settings -> Appearance & Behavior -> System Settings, restart
# required); that setting applies globally to every IntelliJ project, remote
# and local. The block is kept here as forward-compat for the classic mode.
#
# The Gateway backend creates its config dir on first connect and names it
# RemoteDev-IU/_<workspace-hash>; the hash is not knowable from here, so we
# glob. On the very first container start the dir doesn't exist yet -> the
# loop is a no-op and the dialog still appears for that first session. After
# the first connect (and any subsequent container start) the setting is
# in place and the dialog stops appearing.
shopt -s nullglob
for opts in /home/vscode/.config/JetBrains/RemoteDev-IU/*/options; do
    f="${opts}/ide.general.xml"
    if [[ ! -f "${f}" ]]; then
        cat > "${f}" <<'XML'
<application>
  <component name="GeneralSettings">
    <option name="useSafeWrite" value="false" />
  </component>
</application>
XML
        echo "wrote ${f} (useSafeWrite=false)"
    elif ! grep -q 'useSafeWrite' "${f}"; then
        # GeneralSettings block exists but no useSafeWrite line -> inject one.
        # If the component tag itself is missing we add a minimal block.
        if grep -q '<component name="GeneralSettings"' "${f}"; then
            sed -i 's|<component name="GeneralSettings"\([^>]*\)>|<component name="GeneralSettings"\1>\n    <option name="useSafeWrite" value="false" />|' "${f}"
        else
            sed -i 's|</application>|  <component name="GeneralSettings">\n    <option name="useSafeWrite" value="false" />\n  </component>\n</application>|' "${f}"
        fi
        echo "patched ${f} (useSafeWrite=false)"
    fi
done
shopt -u nullglob

# Step 5: start an sshd so IntelliJ's Database tool can reach the docker-in-
# docker Testcontainer DB through an SSH tunnel (see Dockerfile comment for the
# ijent-mode why). Listens on container port 2222. Auth is public-key only,
# reusing the host's own public keys: the host ~/.ssh is bind-mounted read-only
# at /home/vscode/.ssh, so we assemble authorized_keys from the *.pub there.
# IntelliJ runs on the host and authenticates with the matching host private
# key (or the host ssh-agent), so the tunnel just works without new secrets.
#
# Publishing: spawn-workspace.sh only maps the ports listed in HOST_PORTS
# (.env.sh) via 'docker run -p'. Add 2222 to HOST_PORTS so this sshd is
# reachable from the host at 2222+offset. Without that entry sshd still runs
# but is only reachable from inside the container.
SSHD_PORT=2222
SSHD_CONFIG=/tmp/sshd-devcontainer.conf
SSHD_PID=/tmp/sshd-devcontainer.pid
AUTHKEYS_DIR=/home/vscode/.ssh-container
AUTHKEYS="${AUTHKEYS_DIR}/authorized_keys"

# (Re)build authorized_keys from the host's mounted public keys every start, so
# a key added on the host shows up after a container restart.
mkdir -p "${AUTHKEYS_DIR}"
chmod 700 "${AUTHKEYS_DIR}"
if compgen -G "/home/vscode/.ssh/*.pub" >/dev/null 2>&1; then
    cat /home/vscode/.ssh/*.pub > "${AUTHKEYS}" 2>/dev/null || true
    chmod 600 "${AUTHKEYS}"
    echo "sshd: authorized_keys built from host public keys"
else
    echo "sshd: no host public keys found at /home/vscode/.ssh/*.pub --"
    echo "      add a key on the host (ssh-keygen) and restart the container to use the DB tunnel"
fi

# Host keys for the server itself (separate from the user keys above).
sudo ssh-keygen -A >/dev/null 2>&1 || true
sudo mkdir -p /run/sshd

# Minimal tunnel-only sshd config. No PAM, no password, pubkey only.
cat > "${SSHD_CONFIG}" <<SSHDCONF
Port ${SSHD_PORT}
ListenAddress 0.0.0.0
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile ${AUTHKEYS}
AllowUsers vscode
UsePAM no
PidFile ${SSHD_PID}
AllowTcpForwarding yes
X11Forwarding no
SSHDCONF

# Start sshd unless our instance is already listening (idempotent across the
# repeated postStartCommand runs).
if [[ -f "${SSHD_PID}" ]] && sudo kill -0 "$(cat "${SSHD_PID}")" 2>/dev/null; then
    echo "sshd already running on port ${SSHD_PORT} (pid $(cat "${SSHD_PID}"))"
else
    if sudo /usr/sbin/sshd -f "${SSHD_CONFIG}"; then
        echo "sshd listening on port ${SSHD_PORT} (DB tunnel endpoint)"
    else
        echo "WARN: sshd failed to start -- DB-tunnel data source won't work" >&2
    fi
fi

exit 0
SH
chmod +x "${WS_DIR}/.devcontainer/post-start.sh"

# Apply placeholder substitution to the .devcontainer template files written
# in literal heredocs (Dockerfile, post-create.sh, post-start.sh). The
# devcontainer.json / run-config XMLs are substituted earlier (their values
# are needed by the port-reservation scan from sibling workspaces, which we
# do before the rest of the heredocs are even written).
substitute_placeholders "${WS_DIR}/.devcontainer/Dockerfile"
substitute_placeholders "${WS_DIR}/.devcontainer/post-create.sh"
substitute_placeholders "${WS_DIR}/.devcontainer/post-start.sh"
# The workspace README uses the same __PLACEHOLDER__ / __GLAB_BLOCK__ mechanism
# as the other templates. PORT_TABLE_ROWS was already spliced in above via bash;
# substitute_placeholders handles the remaining tokens and GLAB blocks.
substitute_placeholders "${WS_DIR}/README.md"

cat <<EOF

workspace ready: ${WS_DIR}

Open in IntelliJ 2026.1:
  File -> Remote Development -> Dev Containers
  Pick: ${WS_DIR}/.devcontainer/devcontainer.json

  IntelliJ auto-opens README.md from the workspace root on first open --
  it contains the first-time setup steps for this story.

Port offset: +${PORT_OFFSET}  (host-side port = container port + offset)
${PORT_OUTPUT_LINES}

Inside the container, list each worktree's current branch with:
  branches

Dispose later with:
  bin/dispose-workspace.sh ${BRANCH}
EOF
