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
#    array in devcontainers-config.json) a worktree is created in the new workspace. The script
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
#    "backlog.md:") is not a git repo; no worktree is created. Instead the
#    host directory is bind-mounted into the workspace at the same path (mount
#    JSON built alongside NPM_NM_VOLUME_MOUNTS, injected into devcontainer.json).
#    For pre-built artifacts / non-versioned folders. Mono-repo's synthetic
#    "${PROJECT_NAME}:" entry also has an empty value but is a real git repo, so
#    it is excluded via MONO_REPO.
#
# 3. Per-repo base ref for new branches
#    Each entry in REPOS (devcontainers-config.json) is "<repo>:<base-ref>". When the branch
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
#    in devcontainers-config.json).
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
#    instructions, agents, and skills as the source workspace. .claude/ is
#    seeded by a one-time cp -R, EXCEPT .claude/skills which is additionally
#    bind-mounted back onto ${SOURCE_WS}/.claude/skills (see the mounts array in
#    devcontainer.json). So skills an agent creates or edits inside one story
#    container are shared live with every other container and the base workspace
#    instead of staying trapped in the container copy. A README.md is
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
# 6b. Distro support ("distro" in devcontainers-config.json)
#    The container can also be built on a RHEL-family base ("distro": "rocky";
#    covers Rocky, Alma, CentOS Stream and RHEL/UBI). The generated Dockerfile
#    then replaces every devcontainer feature -- they are Debian/Ubuntu-only,
#    their install.sh shells out to apt-get -- with dnf installs (vscode user,
#    JDK from javaVersion, Maven from mavenVersion, Node from NodeSource,
#    docker-ce), and devcontainer.json adds the --privileged/--init flags plus
#    the /var/lib/docker volume that the docker-in-docker feature would
#    otherwise contribute. Everything distro-specific lives in
#    __DEB_BLOCK_*__ / __RPM_BLOCK_*__ markers in the templates below; exactly
#    one side survives substitute_placeholders. Default is "debian", which
#    produces exactly the previous output.
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
#    between host and container regardless of platform. Likewise the host's
#    ~/.config/gh (same path on every OS) is mounted writable onto the
#    container's ~/.config/gh so the GitHub CLI (gh) login is shared; gh is
#    installed in the image (GH_VERSION in devcontainers-config.json) and wired as git's HTTPS
#    credential helper for github.com via 'gh auth setup-git'. ~/.npmrc is NOT
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
#    Port offset (multiple of PORT_OFFSET_STEP, default 10000, range 500..10000):
#    spawn-workspace.sh probes the host for free ports and picks the lowest
#    offset where all HOST_PORTS are free. The probe checks THREE sources:
#    currently-bound listeners, host ports statically reserved by other story
#    workspaces' devcontainer.json files (so a stopped-but-not-disposed
#    workspace can't be unstuck-into-conflict when restarted), AND host ports
#    bound by ANY docker container -- including stopped ones and containers of
#    OTHER projects, which the other two sources miss (closes the cross-project
#    collision gap). A larger step is collision-proof by construction (exceeds
#    the HOST_PORTS spread); a smaller step packs workspaces tighter but leans
#    on the detection above. Default offset is 0 (same numbers
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
# Companion script: dispose-workspace.sh removes a workspace and prunes
# its worktrees.
#
# ============================================================================
#
# Layout:
#   <workspaces-root>/<PROJECT_NAME>/                   (source workspace, read by this script)
#   <workspaces-root>/<PROJECT_NAME>-<branch-leaf>/     (created by this script)
#
# INSTALLATION
#   Clone this directory ONCE and put it on your PATH, e.g.
#       git clone <url> ~/tools/dev-containers
#       ln -s ~/tools/dev-containers/spawn-workspace.sh   /usr/local/bin/
#       ln -s ~/tools/dev-containers/dispose-workspace.sh /usr/local/bin/
#   (symlinks are resolved, so the sibling loader env-config.sh is still found).
#   Per-project settings then live in that project's own devcontainers-config.json; the
#   scripts themselves stay untouched and are shared by every project.
#
# The devcontainers-config.json is located in this order:
#   1. --config <path>   file, or a directory containing devcontainers-config.json
#   2. ./dev-containers/devcontainers-config.json, relative to the CURRENT WORKING DIRECTORY
#   3. ./devcontainers-config.json,                relative to the CURRENT WORKING DIRECTORY
# Its directory (CONFIG_DIR) is the base directory for the other project
# assets: README.md.tpl, initialize.sh and runConfigurations/ are read from
# there, falling back to the copies shipped next to the scripts. Because of
# that fallback, a lone devcontainers-config.json in the project directory is a complete
# setup -- no subdirectory required.
#
# The <workspaces-root> directory is resolved in this order:
#   1. --workspaces-root <path>            CLI flag (highest priority)
#   2. $<PROJECT_SHORT>_WORKSPACES_ROOT    environment variable (e.g. VANILLABP_WORKSPACES_ROOT)
#   3. "workspacesRoot" in devcontainers-config.json     (relative to the config's directory)
#   4. auto-detect: walk up from CONFIG_DIR to the directory named
#      <PROJECT_NAME> (the source workspace) and take its parent; falling back
#      to two directories above CONFIG_DIR
# Regardless of source, the script prints the resolved target workspace
# directory and asks for confirmation before creating anything; pass --yes
# to skip the prompt for scripted use.
#
# Usage:
#   spawn-workspace.sh [--config <path>] [--workspaces-root <path>] [--yes] <branch-name>
#
# Examples:
#   # from the project directory (finds ./dev-containers/devcontainers-config.json)
#   spawn-workspace.sh feature/FLOW-4711_example-story
#   # explicit config, runnable from anywhere
#   spawn-workspace.sh --config ~/work/myproject/dev-containers/devcontainers-config.json feature/FLOW-4711_example
#   spawn-workspace.sh --workspaces-root /opt/dev feature/FLOW-4711_example
#   VANILLABP_WORKSPACES_ROOT=/opt/dev spawn-workspace.sh feature/FLOW-4711_example
#
# Base refs for new branches are configured per repo in "repos" (devcontainers-config.json).
# If the branch already exists locally or on origin, the existing tip is
# reused and the base ref is ignored.
#
set -euo pipefail

# Resolve the script's own directory, following symlinks. The scripts are meant
# to be cloned ONCE and put on the PATH, which usually means a symlink from
# /usr/local/bin -- so a plain dirname "$0" would point at the symlink's
# directory and the sibling loader (env-config.sh) would not be found.
SCRIPT_SOURCE="$0"
while [[ -L "${SCRIPT_SOURCE}" ]]; do
    _link_dir="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
    SCRIPT_SOURCE="$(readlink "${SCRIPT_SOURCE}")"
    # A relative link target resolves against the directory holding the link.
    [[ "${SCRIPT_SOURCE}" != /* ]] && SCRIPT_SOURCE="${_link_dir}/${SCRIPT_SOURCE}"
done
SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing. Runs BEFORE the project config is loaded, because --config
# decides which config to load in the first place.
# ---------------------------------------------------------------------------

BRANCH=""
WORKSPACES_ROOT_CLI=""
CONFIG_CLI=""
ASSUME_YES=0
REBUILD_BASE_IMAGE=0

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
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        --rebuild-base-image)
            REBUILD_BASE_IMAGE=1
            shift
            ;;
        -h|--help)
            sed -n '2,190p' "$0"
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
    echo "usage: $0 [--config <path>] [--workspaces-root <path>] [--yes] <branch-name>" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Locate the project config.
#
# --config accepts either the config file itself or the directory holding it.
# Without the flag we look, relative to the CURRENT WORKING DIRECTORY, for
#   1. ./dev-containers/devcontainers-config.json
#   2. ./devcontainers-config.json
# Resolving against the working directory (not the script location) is what
# makes a single PATH-installed clone usable from any project: cd into the
# project and run the command. Because every other project asset falls back to
# the copies shipped with the scripts, a lone devcontainers-config.json in the project root is
# a complete setup -- no subdirectory required.
#
# The config file's directory becomes CONFIG_DIR, the base directory for every
# other project asset the script reads (README.md.tpl, initialize.sh,
# runConfigurations/). Assets are looked up there first and fall back to the
# script directory, so a project only has to override what it actually
# customises.
# ---------------------------------------------------------------------------

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

# Echo the --config flag back in the generated hints, but only when the user
# actually passed one -- without it the default lookup finds the same config
# anyway, so the shorter command is the correct advice.
DISPOSE_CONFIG_HINT=""
[[ -n "${CONFIG_CLI}" ]] && DISPOSE_CONFIG_HINT="--config ${CONFIG_JSON} "
# Trailing-space-free variant for templates that append their own argument.
DISPOSE_CMD="dispose-workspace.sh ${DISPOSE_CONFIG_HINT}"
DISPOSE_CMD="${DISPOSE_CMD% }"

# Resolve a project asset: prefer the copy next to devcontainers-config.json, fall back to the
# one shipped next to the scripts. Prints nothing and returns 1 when neither
# exists, so callers can treat the asset as optional.
config_asset() {
    local name="$1"
    if [[ -e "${CONFIG_DIR}/${name}" ]]; then
        echo "${CONFIG_DIR}/${name}"
    elif [[ -e "${SCRIPT_DIR}/${name}" ]]; then
        echo "${SCRIPT_DIR}/${name}"
    else
        return 1
    fi
}

# Source project-specific config (PROJECT_NAME, PROJECT_SHORT, REPOS, ports,
# base image, glab hostname, ...). Pointing the scripts at another project means
# writing another devcontainers-config.json; the script body is project-agnostic for the bits
# devcontainers-config.json covers ("Mittel" scope). env-config.sh reads the JSON (via jq) and
# exposes it as the shell variables used below; the same devcontainers-config.json is consumed
# by the PowerShell ports through EnvConfig.ps1.
ENV_CONFIG="${SCRIPT_DIR}/env-config.sh"
if [[ ! -f "${ENV_CONFIG}" ]]; then
    echo "Config loader not found: ${ENV_CONFIG}" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${ENV_CONFIG}"

# Derived from PROJECT_NAME for use in both shell logic and as sed-substituted
# placeholders in the heredoc'd templates below.
WORKSPACE_PATH="/workspaces/${PROJECT_NAME}"
MEMORY_KEY="-workspaces-${PROJECT_NAME}"
# Env var name for the workspaces-root override. Derived from PROJECT_SHORT
# (uppercased) so different projects don't fight for the same name.
ENV_VAR_WORKSPACES_ROOT="$(echo "${PROJECT_SHORT}" | tr '[:lower:]' '[:upper:]')_WORKSPACES_ROOT"

# GitLab integration is optional. It only kicks in when BOTH GLAB_HOSTNAME
# (the GitLab host the project lives on) and GLAB_VERSION (the glab CLI
# release to install in the container) are set in devcontainers-config.json. Empty either
# one and the project gets a container without glab installed, without
# the bind-mounted glab config, and without the git credential helper
# for that host. The conditional blocks in the generated files are
# stripped via __GLAB_BLOCK_START__/__GLAB_BLOCK_END__ markers below.
if [[ -n "${GLAB_HOSTNAME:-}" && -n "${GLAB_VERSION:-}" ]]; then
    GLAB_ENABLED=1
else
    GLAB_ENABLED=0
fi

# GitHub CLI (gh) is installed when GH_VERSION is set in devcontainers-config.json. gh always
# targets github.com, so unlike glab it needs no hostname. The host's gh config
# (~/.config/gh -- same path on macOS and Linux) is bind-mounted so the login
# is shared. Conditional blocks in the generated files are stripped via
# __GH_BLOCK_START__/__GH_BLOCK_END__ markers below.
if [[ -n "${GH_VERSION:-}" ]]; then
    GH_ENABLED=1
else
    GH_ENABLED=0
fi

# Corporate proxy / TLS interception. Three independent switches, each driving
# a conditional block in the generated Dockerfile / devcontainer.json:
#   PROXY_ENABLED  -- proxy URLs are passed to the build (build args) and to the
#                     running container (containerEnv)
#   CA_ENABLED     -- CA certificates are copied into the build context and
#                     installed into the OS, JVM and Node trust stores
#   PROXY_DEBIAN_HTTPS_ENABLED -- apt sources are rewritten from http to https
# All default to off, so a project without a "proxy" block gets exactly the
# same container as before.
if [[ -n "${PROXY_HTTP:-}" || -n "${PROXY_HTTPS:-}" ]]; then
    PROXY_ENABLED=1
else
    PROXY_ENABLED=0
fi
if (( ${#PROXY_CA_CERTS[@]} > 0 )); then
    CA_ENABLED=1
else
    CA_ENABLED=0
fi
if [[ "${PROXY_DEBIAN_HTTPS:-false}" == "true" ]]; then
    PROXY_DEBIAN_HTTPS_ENABLED=1
else
    PROXY_DEBIAN_HTTPS_ENABLED=0
fi

# Optional image build steps. Each defaults to on; turning one off drops the
# corresponding block from the generated Dockerfile (and, for chromium, the
# matching npm install from post-create.sh). Meant for builds that cannot reach
# a Debian package mirror -- see "imageBuild" in devcontainers-config.json for what each one
# costs.
_bool_enabled() { [[ "${1}" != "false" ]] && echo 1 || echo 0; }
APT_PKGS_ENABLED="$(_bool_enabled "${IMAGE_APT_PACKAGES:-true}")"
RECENT_GIT_ENABLED="$(_bool_enabled "${IMAGE_RECENT_GIT:-true}")"
CHROMIUM_ENABLED="$(_bool_enabled "${IMAGE_CHROMIUM:-true}")"
if (( APT_PKGS_ENABLED == 0 || RECENT_GIT_ENABLED == 0 || CHROMIUM_ENABLED == 0 )); then
    echo "image build steps: apt-packages=${APT_PKGS_ENABLED} recent-git=${RECENT_GIT_ENABLED} chromium=${CHROMIUM_ENABLED}"
fi
[[ "${FEATURE_REGISTRY}" != "ghcr.io" ]] && echo "feature registry:  ${FEATURE_REGISTRY}"

# Package-manager family of the base image ("debian" | "rocky"). Everything
# distro-specific in the generated files sits in __DEB_BLOCK_*__ / __RPM_BLOCK_*__
# markers; exactly one of the two survives the substitution pass.
#
# Why Rocky needs its own path at all: the devcontainer FEATURES (java, node,
# git, docker-in-docker) are Debian/Ubuntu-only -- their install.sh calls
# apt-get and aborts on a RHEL-family base. So on Rocky the generated
# devcontainer.json declares no features and the Dockerfile installs the same
# toolchain from dnf / upstream tarballs instead.
IS_ROCKY=0
[[ "${DISTRO:-debian}" == "rocky" ]] && IS_ROCKY=1
DEBIAN_ENABLED=$(( 1 - IS_ROCKY ))

# Where the JDK ends up, which the generated files hard-code in a dozen places
# (containerEnv, remoteEnv, profile.d, bashrc, post-create's probe).
#   Debian: the MS base image's own JDK.
#   Rocky : a stable symlink the Dockerfile creates next to the versioned
#           java-<n>-openjdk directory dnf installs, so the value stays
#           independent of the exact package release and the architecture.
JAVA_HOME_PATH="/usr/lib/jvm/msopenjdk-current"
# System-wide rc file for interactive non-login bashes: Debian reads
# /etc/bash.bashrc, RHEL-family /etc/bashrc.
SYSTEM_BASHRC="/etc/bash.bashrc"
if (( IS_ROCKY )); then
    JAVA_HOME_PATH="/usr/lib/jvm/devcontainer-java"
    SYSTEM_BASHRC="/etc/bashrc"
    echo "distro:           rocky (jdk ${JAVA_VERSION}, maven ${MAVEN_VERSION}, node ${NODE_FEATURE_VERSION}, no devcontainer features)"
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

# Mono-repo mode: REPOS=() in devcontainers-config.json signals that the source workspace IS
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

# Resolve the workspaces root. Priority (see resolve_workspaces_root in
# env-config.sh): --workspaces-root flag, ${ENV_VAR_WORKSPACES_ROOT} env var,
# "workspacesRoot" in devcontainers-config.json, then auto-detect from the config location.
# Deliberately derived from the config and NOT from the script, which may sit
# anywhere on the PATH.
WORKSPACES_ROOT="$(resolve_workspaces_root "${WORKSPACES_ROOT_CLI}")" || exit 1

SOURCE_WS="${WORKSPACES_ROOT}/${PROJECT_NAME}"

LEAF="${BRANCH##*/}"
WS_NAME="${PROJECT_NAME}-${LEAF}"
WS_DIR="${WORKSPACES_ROOT}/${WS_NAME}"

# Existence check up-front: a leftover workspace from an earlier spawn would
# cause partial overwrites if we charged ahead. Dispose it first or rename
# it out of the way.
if [[ -e "${WS_DIR}" ]]; then
    echo "Workspace already exists: ${WS_DIR}" >&2
    echo "Dispose it first: dispose-workspace.sh ${BRANCH}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Preflight: validate EVERY config-driven file asset before touching anything.
#
# All the generation below mutates the host (WS_DIR, worktrees, branches,
# generated files) and only THEN starts the DevContainer image build. An asset
# that resolves to a missing file -- a run-config XML, a CA certificate, the
# README template -- must therefore be caught here, before the first mutation
# and before the confirmation prompt. Otherwise a late failure leaves a
# half-built workspace with orphaned branches behind (exactly the ".devcontainer
# never created" symptom). Each source path is resolved once and reused by the
# copy site far below, so there is a single source of truth per asset.
#
# Assets that degrade gracefully are deliberately NOT hard-checked here:
# initialize.sh is optional (skipped when absent), a missing per-repo base ref
# falls back to origin/HEAD, and a repo with no .git is skipped -- none of them
# abort, so none can leave a half-built workspace.

# Run-config XMLs (RUN_CONFIGS -> runConfigurations/).
RUN_CONFIG_SRC_DIR="$(config_asset runConfigurations || echo "${CONFIG_DIR}/runConfigurations")"
if (( ${#RUN_CONFIGS[@]} > 0 )); then
    for rc_file in "${RUN_CONFIGS[@]}"; do
        if [[ ! -f "${RUN_CONFIG_SRC_DIR}/${rc_file}" ]]; then
            echo "Run-config source missing: ${RUN_CONFIG_SRC_DIR}/${rc_file}" >&2
            echo "Check runConfigs in devcontainers-config.json." >&2
            exit 1
        fi
    done
fi

# Corporate-proxy CA certificates (proxy.caCertificates). Copied into the build
# context by the CA_ENABLED block far below; CA_ENABLED implies PROXY_CA_CERTS
# is non-empty, so the expansion is safe.
if (( CA_ENABLED == 1 )); then
    for _ca in "${PROXY_CA_CERTS[@]}"; do
        _ca_src="${_ca}"
        [[ "${_ca_src}" != /* ]] && _ca_src="${CONFIG_DIR}/${_ca_src}"
        if [[ ! -f "${_ca_src}" ]]; then
            echo "CA certificate not found: ${_ca_src}" >&2
            echo "Check \"proxy.caCertificates\" in ${CONFIG_JSON}." >&2
            exit 1
        fi
    done
fi

# Welcome README template (README.md.tpl, project copy or the fallback next to
# the scripts). README_TPL_SRC is reused by the copy site below.
README_TPL_SRC="$(config_asset README.md.tpl)" || {
    echo "README template not found: ${CONFIG_DIR}/README.md.tpl (nor next to the scripts)" >&2
    exit 1
}
# ---------------------------------------------------------------------------

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
# HOST_PORTS comes from devcontainers-config.json.

# Collect host ports already reserved by OTHER story workspaces' devcontainer.json
# files. Even if their containers are stopped right now, starting them later
# would clash with our offset choice -- so we treat statically-mapped host
# ports as taken alongside currently-bound ones. The grep-based extraction
# matches "<num>:<num>" inside any of the workspace's devcontainer.json files
# (only port mappings appear in that quoted-pair shape; mounts use
# source=...,target=... and other JSON values don't have the colon-between-
# digits pattern).
RESERVED_HOST_PORTS=()
for dc in "${WORKSPACES_ROOT}"/"${PROJECT_NAME}"-*/.devcontainer/devcontainer.json; do
    [[ -f "${dc}" ]] || continue
    [[ "${dc}" == "${WS_DIR}/.devcontainer/devcontainer.json" ]] && continue
    while IFS= read -r host_port; do
        RESERVED_HOST_PORTS+=("${host_port}")
    done < <(grep -oE '"[0-9]+:[0-9]+"' "${dc}" | tr -d '"' | cut -d: -f1)
done
if (( ${#RESERVED_HOST_PORTS[@]} > 0 )); then
    echo "ports reserved by other workspaces: ${RESERVED_HOST_PORTS[*]}"
fi

# Also collect host ports bound by ANY docker container on this host --
# including STOPPED ones and containers of OTHER projects, which the
# devcontainer.json scan above (scoped to this project's workspaces) and
# the live-listener check below (stopped containers have no listener) both
# miss. This closes the cross-project collision gap: a stopped DevContainer
# from an unrelated project can no longer have its offset silently reused.
# HostConfig.PortBindings holds the statically-mapped host ports regardless
# of run state. Best-effort: skipped when docker is absent or the daemon is
# unreachable.
if command -v docker >/dev/null 2>&1; then
    DOCKER_RESERVED=()
    while IFS= read -r host_port; do
        [[ -n "${host_port}" ]] && DOCKER_RESERVED+=("${host_port}")
    done < <(
        docker ps -a --format '{{.ID}}' 2>/dev/null \
            | xargs -r docker inspect \
                --format '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}}
{{end}}{{end}}' 2>/dev/null
    )
    if (( ${#DOCKER_RESERVED[@]} > 0 )); then
        RESERVED_HOST_PORTS+=("${DOCKER_RESERVED[@]}")
        echo "ports reserved by docker containers: ${DOCKER_RESERVED[*]}"
    fi
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

# Step size between candidate offsets comes from devcontainers-config.json (default 10000).
# Constrained to [500, 10000]: below 500 the offset ranges of two workspaces
# could overlap by less than the HOST_PORTS spread AND leave too little room
# between adjacent ports; above 10000 offers no benefit and quickly runs host
# ports past the 65535 ceiling. Abort loudly on a misconfigured value.
PORT_OFFSET_STEP="${PORT_OFFSET_STEP:-10000}"
if ! [[ "${PORT_OFFSET_STEP}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: PORT_OFFSET_STEP must be an integer, got '${PORT_OFFSET_STEP}'" >&2
    exit 1
fi
if (( PORT_OFFSET_STEP < 500 || PORT_OFFSET_STEP > 10000 )); then
    echo "ERROR: PORT_OFFSET_STEP must be between 500 and 10000, got ${PORT_OFFSET_STEP}" >&2
    exit 1
fi

# Upper bound keeps the highest host port (max HOST_PORT + offset) safely
# below the 65535 ceiling regardless of the configured step.
PORT_OFFSET_MAX=50000
PORT_OFFSET=0
while (( PORT_OFFSET <= PORT_OFFSET_MAX )); do
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
    PORT_OFFSET=$((PORT_OFFSET + PORT_OFFSET_STEP))
done
if (( PORT_OFFSET > PORT_OFFSET_MAX )); then
    echo "ERROR: no free port range found (tried offset 0..${PORT_OFFSET_MAX} in ${PORT_OFFSET_STEP} steps)" >&2
    exit 1
fi
echo "port offset: ${PORT_OFFSET}"

# Build everything that depends on the per-port host numbers from HOST_PORTS
# (which lives in devcontainers-config.json) so adding a new forwarded port only takes editing
# the devcontainers-config.json entry, never this file. Four derived artifacts:
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
_repos_1="${REPOS[0]:-}"
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

# Splice a (possibly multi-line) value into every occurrence of a placeholder
# token in a file.
#
# Why not "${text/__TOKEN__/${value}}": bash 5.2 changed the pattern-substitution
# replacement so that an unescaped '&' stands for the matched text. Any value
# containing '&&' (every generated build command does) would therefore inject the
# placeholder back into the output -- the script still works on macOS's bash 3.2
# but produces a syntactically broken post-create.sh on modern Linux bash.
# Why not sed: the values contain '/', '&', '\(' and newlines, all of which
# would need escaping. awk reading the value from a FILE processes no escape
# sequences at all, and index()/substr() do a literal replacement, so the value
# is copied through byte for byte.
splice_placeholder() {
    local file="$1" token="$2" value="$3"
    local vf tmp
    vf="$(mktemp)"
    tmp="$(mktemp)"
    printf '%s' "${value}" > "${vf}"
    awk -v tok="${token}" -v vf="${vf}" '
        BEGIN {
            val = ""; first = 1
            while ((getline line < vf) > 0) {
                val = first ? line : val "\n" line
                first = 0
            }
        }
        {
            while ((i = index($0, tok)) > 0) {
                $0 = substr($0, 1, i - 1) val substr($0, i + length(tok))
            }
            print
        }
    ' "${file}" > "${tmp}"
    # Truncate-and-rewrite the ORIGINAL file rather than `mv`ing the mktemp over
    # it: mv would rename the mktemp's inode into place, and mktemp files are
    # mode 0600 with no exec bit -- silently stripping the +x that was already
    # set on post-create.sh (invoked directly as a lifecycle command, so a
    # missing exec bit fails it with exit 126). Redirecting into "${file}" keeps
    # its permissions untouched.
    cat "${tmp}" > "${file}"
    rm -f "${vf}" "${tmp}"
}

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

    # Accept both a real .git directory and a .git *file*: git submodules store
    # their metadata under the superproject's .git/modules/<name> and leave only
    # a "gitdir: ..." pointer file in the working tree, so -d would wrongly skip
    # every submodule (leaving empty worktrees -> no Maven warmup). -e matches both.
    if [[ ! -e "${src}/.git" ]]; then
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

# Host-mount repos: a REPOS entry with an EMPTY value (e.g. "backlog.md:")
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
    # -e (not -d): submodules carry a .git *file* pointer, not a directory.
    [[ -e "${src_repo}/.git" ]] || continue
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
    rel="${pj_dir#"${WS_DIR}"/}"
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

# Share the project-level Claude skills directory back to the SOURCE workspace
# instead of leaving it as the one-time copy above. The cp -R seeds .claude/ so
# settings/agents/skills are inherited on first start, but a devcontainer bind
# mount then overlays .claude/skills onto ${SOURCE_WS}/.claude/skills at runtime
# (see the mounts array in the generated devcontainer.json). That way skills an
# agent creates or edits in one story container are immediately visible to every
# other container and to the base workspace. Pre-create both the bind source (on
# the base workspace) and the mountpoint (in this story workspace) so Docker
# doesn't materialise them as root-owned dirs on first mount.
mkdir -p "${SOURCE_WS}/.claude/skills"
mkdir -p "${WS_DIR}/.claude/skills"

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
# README_TPL_SRC was resolved and validated up-front (preflight), so just copy.
cp "${README_TPL_SRC}" "${WS_DIR}/README.md"
splice_placeholder "${WS_DIR}/README.md" "__PORT_TABLE_ROWS__" "${PORT_TABLE_ROWS}"

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
        <option name="myStartingDirectory" value="$PROJECT_DIR$" />__TERMINAL_SHELL_OPTION__
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

# Optionally pin the terminal's login shell. Without myShellPath JetBrains
# auto-detects one and prefers zsh when present (the base image ships oh-my-zsh
# via common-utils) even though vscode's login shell is /bin/bash. When
# terminalShell is set we splice a second <option> onto the same line as
# myStartingDirectory above; the value carries its own leading newline + indent,
# so an unset terminalShell leaves that line byte-identical to before.
TERMINAL_SHELL_OPTION=""
if [[ -n "${TERMINAL_SHELL:-}" ]]; then
    TERMINAL_SHELL_OPTION=$'\n        <option name="myShellPath" value="'"${TERMINAL_SHELL}"'" />'
fi
splice_placeholder "${WS_DIR}/.idea/workspace.xml" "__TERMINAL_SHELL_OPTION__" "${TERMINAL_SHELL_OPTION}"

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
# in RUN_CONFIGS (devcontainers-config.json); add/remove/reorder entries there to change
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
# RUN_CONFIG_SRC_DIR and the existence of every entry were already resolved and
# validated up-front (before any mutation), so here we only copy.
# Length-guard: bash 3.2 + set -u fail on empty array expansion.
if (( ${#RUN_CONFIGS[@]} > 0 )); then
for rc_file in "${RUN_CONFIGS[@]}"; do
    cp "${RUN_CONFIG_SRC_DIR}/${rc_file}" "${WS_DIR}/.idea/runConfigurations/${rc_file}"
done
fi

# Ensure the shared memory directory exists on the host before the container mounts it.
# All story containers use ${WORKSPACE_PATH}, encoded by Claude Code as ${MEMORY_KEY}.
SHARED_MEMORY_DIR="${HOME}/.claude/projects/${MEMORY_KEY}/memory"
mkdir -p "${SHARED_MEMORY_DIR}"

# Same idea for the GitHub Copilot CLI's ~/.copilot -- only skills/instructions/
# prompts get shared (see the mounts block below for the full rationale).
mkdir -p "${HOME}/.copilot/skills" "${HOME}/.copilot/instructions" "${HOME}/.copilot/prompts"

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
    echo "glab integration: disabled (GLAB_HOSTNAME and/or GLAB_VERSION empty in devcontainers-config.json)"
fi

# Resolve the host's gh (GitHub CLI) config directory. Unlike glab, gh uses
# ~/.config/gh on BOTH macOS and Linux (it honours GH_CONFIG_DIR / XDG, not
# Go's os.UserConfigDir()), so there's no OS-specific source path. Bind-mounting
# it onto the container's ~/.config/gh shares hosts.yml (the github.com auth
# token) in both directions. Fallback: create the dir as a stub if the user
# never ran gh, so the mount has a valid source; 'gh auth login' (host or
# container) then populates it and the token flows back to the host.
GH_CONFIG_SRC=""
if [[ ${GH_ENABLED} -eq 1 ]]; then
    if [[ -d "${HOME}/.config/gh" ]]; then
        GH_CONFIG_SRC="${HOME}/.config/gh"
    else
        mkdir -p "${HOME}/.config/gh"
        GH_CONFIG_SRC="${HOME}/.config/gh"
        echo "note: no host gh config found, created stub at ${GH_CONFIG_SRC}"
        echo "      run 'gh auth login' (host or container) to populate"
    fi
    echo "gh config source: ${GH_CONFIG_SRC}"
else
    echo "gh integration: disabled (GH_VERSION empty in devcontainers-config.json)"
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

# Corporate proxy: copy the CA certificates into the build context so the
# Dockerfile can COPY them (a build context cannot reach outside its directory).
# Paths in devcontainers-config.json are relative to the config's own directory.
#
# Why the certificates are needed at all: a TLS-intercepting proxy re-signs every
# HTTPS response with its own CA. Without that CA in the trust store, curl, apt,
# npm, git and Maven all fail with "self-signed certificate in certificate
# chain". Three separate trust stores have to be fed, which the Dockerfile does:
# the OS bundle (curl/apt/git), the JVM truststore (Maven does NOT use the OS
# bundle) and Node (via NODE_EXTRA_CA_CERTS).
# Existence of every declared certificate was already validated up-front
# (before any mutation), so here we only resolve the path and copy.
if (( CA_ENABLED == 1 )); then
    mkdir -p "${WS_DIR}/.devcontainer/certs"
    for _ca in "${PROXY_CA_CERTS[@]}"; do
        _ca_src="${_ca}"
        [[ "${_ca_src}" != /* ]] && _ca_src="${CONFIG_DIR}/${_ca_src}"
        cp "${_ca_src}" "${WS_DIR}/.devcontainer/certs/$(basename "${_ca_src}")"
        echo "ca certificate: $(basename "${_ca_src}")"
    done
fi

# Rocky only: yum repo files pointing at the internal repos.ads.dmz mirror
# instead of dl.rockylinux.org / download.docker.com. Both are on the open
# internet, and this network's web gateway answers every compressed download
# from there with "403 MediaTypeBlocked" -- verified to be a blanket policy
# (the same 403 hits Debian's and npm's compressed downloads too), not
# something specific to Rocky's mirrors. repos.ads.dmz is in NO_PROXY and
# reachable directly, so the Dockerfile drops the stock repo files and COPYs
# these instead. No secrets in here -- it is an internal, unauthenticated
# mirror -- so unlike certs/ above there is nothing to read from devcontainers-config.json;
# the content is simply the file the network admin handed us.
if (( IS_ROCKY == 1 )); then
    mkdir -p "${WS_DIR}/.devcontainer/rocky-repos"
    cat > "${WS_DIR}/.devcontainer/rocky-repos/rocky-9.repo" <<'ROCKYREPO'
[rocky-9-appstream]
name=rocky-9-appstream Repository
baseurl=https://repos.ads.dmz/rocky/9/x86_64/appstream/rocky-9-appstream
enabled=1
gpgcheck=0
sslverify=0

[rocky-9-baseos]
name=rocky-9-baseos Repository
baseurl=https://repos.ads.dmz/rocky/9/x86_64/baseos/rocky-9-baseos
enabled=1
gpgcheck=0
sslverify=0

[rocky-9-devel]
name=rocky-9-devel Repository
baseurl=https://repos.ads.dmz/rocky/9/x86_64/devel/rocky-9-devel
enabled=1
gpgcheck=0
sslverify=0
ROCKYREPO
    cat > "${WS_DIR}/.devcontainer/rocky-repos/docker-ce-9.repo" <<'DOCKERREPO'
[docker-ce-9-stable]
name=docker-ce-9-stable Repository
baseurl=https://repos.ads.dmz/docker-ce-9/docker-ce-9-stable
enabled=1
gpgcheck=0
sslverify=0
DOCKERREPO
    echo "rocky repos:      baseos/appstream/devel/docker-ce via repos.ads.dmz (internal mirror)"
fi

# Proxy JSON fragments for devcontainer.json. Both build args (used while the
# image is built) and containerEnv (used by post-create's npm/Maven runs and by
# anything the developer runs later) are emitted, in upper- and lowercase
# spelling because tools disagree about which they read.
PROXY_BUILD_ARGS=""
PROXY_CONTAINER_ENV=""
if (( PROXY_ENABLED == 1 )); then
    _p_http="${PROXY_HTTP:-${PROXY_HTTPS}}"
    _p_https="${PROXY_HTTPS:-${PROXY_HTTP}}"
    PROXY_BUILD_ARGS="\"HTTP_PROXY\": \"${_p_http}\", \"HTTPS_PROXY\": \"${_p_https}\", \"http_proxy\": \"${_p_http}\", \"https_proxy\": \"${_p_https}\""
    PROXY_CONTAINER_ENV=", \"HTTP_PROXY\": \"${_p_http}\", \"HTTPS_PROXY\": \"${_p_https}\", \"http_proxy\": \"${_p_http}\", \"https_proxy\": \"${_p_https}\""
    if [[ -n "${PROXY_NO}" ]]; then
        PROXY_BUILD_ARGS="${PROXY_BUILD_ARGS}, \"NO_PROXY\": \"${PROXY_NO}\", \"no_proxy\": \"${PROXY_NO}\""
        PROXY_CONTAINER_ENV="${PROXY_CONTAINER_ENV}, \"NO_PROXY\": \"${PROXY_NO}\", \"no_proxy\": \"${PROXY_NO}\""
    fi
    echo "proxy:            ${_p_https} (no_proxy: ${PROXY_NO:-<none>})"
fi

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
#
# The template covers BOTH supported distro families. Everything that differs
# sits in __DEB_BLOCK_*__ / __RPM_BLOCK_*__ markers, and substitute_placeholders
# keeps exactly one side depending on "distro" in devcontainers-config.json. On the rocky side
# the Dockerfile additionally has to do the whole job of the devcontainer
# features (user, JDK, Maven, Node, docker-ce), which are Debian/Ubuntu-only.
cat > "${WS_DIR}/.devcontainer/Dockerfile" <<'DOCKERFILE'
FROM __BASE_IMAGE__

# __PROXY_BLOCK_START__
# Corporate proxy. Declaring the well-known names as ARG makes BuildKit expose
# them as environment variables to every RUN below, so apt/dnf/curl/npm pick
# them up without any further wiring. They are deliberately NOT turned into ENV:
# that would bake the (host-specific) proxy into the image. The running container
# gets the same values via containerEnv in devcontainer.json.
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy
# __RPM_BLOCK_START__
# dnf/librepo do honour the *_proxy environment variables, but only for the
# spellings they know and not for the `dnf` invocations that some RPM scriptlets
# run with a scrubbed environment. Writing the proxy into /etc/dnf/dnf.conf makes
# it unconditional for every dnf call in this build.
RUN set -eux; \
    p="${https_proxy:-${HTTPS_PROXY:-}}"; \
    if [ -n "$p" ]; then \
        printf 'proxy=%s\n' "$p" >> /etc/dnf/dnf.conf; \
        echo "dnf proxy: $p"; \
    fi
# __RPM_BLOCK_END__
# __PROXY_BLOCK_END__

# __CA_BLOCK_START__
# Corporate TLS interception: the proxy re-signs every HTTPS response with its
# own CA, so that CA has to be trusted or every download fails with
# "self-signed certificate in certificate chain". THREE trust stores need it:
#   1. the OS bundle          -- curl, apt/dnf, git, wget
#   2. the JVM truststore     -- Maven/Gradle ignore the OS bundle entirely
#   3. Node                   -- via NODE_EXTRA_CA_CERTS (set below)
# __DEB_BLOCK_START__
# The JVM loop is best-effort (|| true): the base image may ship a different
# JDK layout, and a missing truststore must not fail the whole build.
COPY certs/ /usr/local/share/ca-certificates/
RUN set -eux; \
    if command -v update-ca-certificates >/dev/null 2>&1; then \
        update-ca-certificates; \
    else \
        cat /usr/local/share/ca-certificates/*.crt >> /etc/ssl/certs/ca-certificates.crt; \
    fi; \
    for jh in /usr/lib/jvm/msopenjdk-current /opt/java/openjdk /usr/lib/jvm/default-jvm; do \
        [ -x "$jh/bin/keytool" ] || continue; \
        for c in /usr/local/share/ca-certificates/*.crt; do \
            "$jh/bin/keytool" -importcert -noprompt -trustcacerts \
                -alias "devcontainer-$(basename "$c" .crt)" \
                -file "$c" \
                -keystore "$jh/lib/security/cacerts" \
                -storepass changeit >/dev/null 2>&1 || true; \
        done; \
    done
# Node ships its own CA bundle and ignores the OS one; this makes npm work.
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
# __DEB_BLOCK_END__
# __RPM_BLOCK_START__
# RHEL-family: anchors + `update-ca-trust extract`. No keytool loop needed --
# update-ca-trust also regenerates /etc/pki/ca-trust/extracted/java/cacerts, and
# the RHEL OpenJDK packages symlink their lib/security/cacerts at exactly that
# file. That is why this step runs BEFORE the JDK is installed further down and
# still covers Maven: the JDK picks up the already-patched extracted store.
COPY certs/ /etc/pki/ca-trust/source/anchors/
RUN set -eux; \
    update-ca-trust extract; \
    ls -1 /etc/pki/ca-trust/source/anchors/
# Node ships its own CA bundle and ignores the OS one; this makes npm work.
ENV NODE_EXTRA_CA_CERTS=/etc/pki/tls/certs/ca-bundle.crt
# __RPM_BLOCK_END__
# __CA_BLOCK_END__

# __APT_HTTPS_BLOCK_START__
# __DEB_BLOCK_START__
# Switch the Debian package sources from http:// to https://. Many corporate
# proxies forward CONNECT (HTTPS) but refuse plain-HTTP relaying, which makes
# "apt-get update" fail while every HTTPS download works. Handles both the
# classic sources.list and the deb822 *.sources layout of bookworm images.
RUN set -eux; \
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do \
        [ -f "$f" ] || continue; \
        sed -i 's|http://deb.debian.org|https://deb.debian.org|g; s|http://security.debian.org|https://security.debian.org|g; s|http://archive.ubuntu.com|https://archive.ubuntu.com|g; s|http://security.ubuntu.com|https://security.ubuntu.com|g' "$f"; \
    done
# __DEB_BLOCK_END__
# __RPM_BLOCK_START__
# The stock Rocky repo files point at dl.rockylinux.org / download.docker.com,
# and this network's web gateway answers every compressed download from the
# open internet with "403 MediaTypeBlocked" (verified: same 403 for Debian's
# and npm's compressed downloads too, so it is a blanket policy, not something
# specific to Rocky's mirrors). The only way in is the internal, gateway-exempt
# mirror at repos.ads.dmz (it is in NO_PROXY, see the ARGs above) -- so the
# stock repo files are dropped entirely and replaced with the ones the network
# admin provided, which point there instead.
RUN rm -f /etc/yum.repos.d/*.repo
COPY rocky-repos/*.repo /etc/yum.repos.d/
RUN set -eux; \
    grep -h '^baseurl=' /etc/yum.repos.d/*.repo | sort -u; \
    dnf -y makecache
# __RPM_BLOCK_END__
# __APT_HTTPS_BLOCK_END__

# __RPM_BLOCK_START__
# ===========================================================================
# Rocky Linux (RHEL family) base setup
# ===========================================================================
# Everything below replaces what the Debian path gets for free from the MS
# devcontainer base image plus the devcontainer features. The features are not
# an option here: devcontainers/features/{java,node,git,docker-in-docker} call
# apt-get in their install.sh and abort on a dnf distro, so the generated
# devcontainer.json declares none of them when distro=rocky.

# --- base tooling ----------------------------------------------------------
# Deliberately NOT part of the optional package block below: without sudo, git
# and tar the lifecycle scripts and the IDE backend cannot work at all.
# curl is provided by curl-minimal in the base image -- asking for "curl" here
# would force an --allowerasing swap for no benefit.
RUN set -eux; \
    dnf -y install --setopt=install_weak_deps=False \
        sudo shadow-utils passwd procps-ng iproute hostname \
        tar gzip bzip2 xz zip unzip which findutils diffutils file less \
        gawk sed grep \
        git openssh-clients rsync ca-certificates; \
    dnf clean all; \
    rm -rf /var/cache/dnf

# Rocky's 'which' package ships /etc/profile.d/which2.sh, which wraps the
# 'which' binary in a shell FUNCTION and exports it (export -f) so aliases are
# visible to it. Every non-bash process that inherits the environment (JetBrains
# Gateway's backend launcher, /bin/sh, etc.) tries to parse that exported
# function definition and fails with "syntax error: unexpected end of file" /
# "error importing function definition for `which'" -- on EVERY shell start.
# The wrapper only adds alias-awareness we don't need in a devcontainer; the
# real /usr/bin/which binary (installed by the same package) still works fine
# without it, so we just drop the profile script.
RUN rm -f /etc/profile.d/which2.sh

# --- the 'vscode' user -----------------------------------------------------
# Same name/uid/gid the MS devcontainer images use, because devcontainer.json's
# remoteUser, every bind-mount target under /home/vscode and the lifecycle
# scripts hard-code it. secure_path is widened so `sudo <tool>` also finds
# things installed under /usr/local.
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=1000
RUN set -eux; \
    groupadd --gid ${USER_GID} ${USERNAME}; \
    useradd --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash ${USERNAME}; \
    printf '%s ALL=(ALL) NOPASSWD:ALL\nDefaults:%s secure_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' \
        "${USERNAME}" "${USERNAME}" > /etc/sudoers.d/${USERNAME}; \
    chmod 0440 /etc/sudoers.d/${USERNAME}; \
    visudo -c

# --- JDK -------------------------------------------------------------------
# dnf installs into a versioned directory whose name carries the exact package
# release and the architecture. The generated files need ONE stable value for
# JAVA_HOME, so we resolve javac and pin a symlink at that path.
ARG JAVA_VERSION=__JAVA_VERSION__
RUN set -eux; \
    dnf -y install --setopt=install_weak_deps=False java-${JAVA_VERSION}-openjdk-devel; \
    dnf clean all; \
    jdk="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"; \
    ln -sfn "$jdk" __JAVA_HOME__; \
    __JAVA_HOME__/bin/javac -version
ENV JAVA_HOME=__JAVA_HOME__

# --- Maven -----------------------------------------------------------------
# Preferred: the Apache binary tarball, pinned to the exact configured version
# (the AppStream maven package drags in its own, older JDK and a fixed version
# it does not let us choose). dlcdn/archive.apache.org are both on the open
# internet though, so on networks where the gateway blocks that (see the RPM
# repo swap above) both attempts fail fast and dnf's AppStream package is the
# fallback -- an older, but working, Maven beats no Maven at all. That fallback
# package pulls in java-17-openjdk as its own dependency, and dnf's alternatives
# system then silently repoints the bare `java`/`javac` on PATH at 17 instead of
# the JAVA_VERSION installed above -- so both get pinned back to __JAVA_HOME__
# unconditionally, regardless of which Maven branch ran.
ARG MAVEN_VERSION=__MAVEN_VERSION__
RUN set -eux; \
    if curl -fsSL "https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" -o /tmp/maven.tgz \
       || curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" -o /tmp/maven.tgz; \
    then \
        mkdir -p /opt/maven; \
        tar -xzf /tmp/maven.tgz -C /opt/maven --strip-components=1; \
        rm -f /tmp/maven.tgz; \
        ln -sfn /opt/maven/bin/mvn /usr/local/bin/mvn; \
    else \
        echo "note: apache.org unreachable -- falling back to the AppStream maven package (older, fixed version)" >&2; \
        dnf -y install --setopt=install_weak_deps=False maven; \
        dnf clean all; \
        rm -rf /var/cache/dnf; \
    fi; \
    ln -sfn __JAVA_HOME__/bin/java /usr/bin/java; \
    ln -sfn __JAVA_HOME__/bin/javac /usr/bin/javac; \
    java -version; \
    mvn -v

# --- Node ------------------------------------------------------------------
# NodeSource carries the current major versions for RHEL 9; the AppStream module
# stream is the fallback for networks that cannot reach rpm.nodesource.com (it
# tops out at nodejs:22, so a newer nodeFeatureVersion silently lands on the
# newest stream available).
# The global prefix is moved to /usr/local and handed to the vscode user, so
# `npm install -g` in post-create.sh works without sudo -- exactly like it does
# on the Debian path where the node feature owns its nvm directory.
ARG NODE_MAJOR=__NODE_FEATURE_VERSION__
RUN set -eux; \
    ( curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource.sh \
      && bash /tmp/nodesource.sh \
      && dnf -y install nodejs ) \
    || ( echo "note: NodeSource unavailable -- falling back to the AppStream module" >&2; \
         dnf -y module reset nodejs; \
         dnf -y module enable "nodejs:${NODE_MAJOR}" || dnf -y module enable nodejs:22; \
         dnf -y install nodejs npm ); \
    rm -f /tmp/nodesource.sh; \
    dnf clean all; \
    npm config set prefix /usr/local --global; \
    mkdir -p /usr/local/lib/node_modules; \
    chown -R ${USER_UID}:${USER_GID} /usr/local/lib/node_modules /usr/local/bin /usr/local/share; \
    node --version; npm --version

# --- Docker (docker-in-docker) ---------------------------------------------
# Stands in for the docker-in-docker feature: docker-ce from the internal
# mirror's docker-ce-9 repo (already dropped into /etc/yum.repos.d/ by the RPM
# repo swap above -- download.docker.com itself is unreachable, same story as
# dl.rockylinux.org). The daemon is started by post-start.sh (JetBrains Gateway
# overrides the entrypoint, so an entrypoint-based start would never run),
# /var/lib/docker is a named volume declared in devcontainer.json, and the
# container is launched with --privileged via runArgs.
RUN set -eux; \
    dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; \
    dnf clean all; \
    rm -rf /var/cache/dnf; \
    usermod -aG docker ${USERNAME}; \
    mkdir -p /var/lib/docker; \
    dockerd --version
# __RPM_BLOCK_END__

# __APT_PKGS_BLOCK_START__
# socat       -- post-start.sh exposes the docker socket on TCP 127.0.0.1:2375
#                so tools that prefer DOCKER_HOST=tcp://... have a backup endpoint.
# jq          -- the shared Claude Code statusline (~/.claude/statusline.sh, bind-
#                mounted in via the ~/.claude mount) parses the statusline JSON
#                payload with jq to render the session/weekly usage limits.
#                Without it the statusline silently drops the limit segment.
# openssh-server -- lets IntelliJ's Database tool reach the in-container DB through
#                an SSH tunnel. In ijent Dev Container mode the IDE runs on the host
#                and its Database plugin cannot introspect a docker-in-docker DB
#                directly (it execs the host JBR path inside the container -> ENOENT).
#                An SSH-tunnel data source sidesteps that: the JDBC driver runs on the
#                host, the TCP hop is tunnelled into the container where 127.0.0.1
#                resolves to the DB. post-start.sh configures + starts sshd.
# dbus/gnome-keyring/libsecret -- give CLI tools that use a Secret Service backend
#                for credential storage (observed: the GitHub Copilot CLI's login,
#                which otherwise has NO secure place to persist a token in a minimal
#                container and would either fail or fall back to writing it in
#                plaintext) something real to talk to. post-start.sh starts a
#                per-container session bus + auto-unlocked keyring at a fixed
#                address (see DBUS_SESSION_BUS_ADDRESS in containerEnv below).
# __DEB_BLOCK_START__
RUN rm -f /etc/apt/sources.list.d/yarn.list /etc/apt/keyrings/yarn.gpg \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        socat ca-certificates curl jq openssh-server \
        dbus gnome-keyring libsecret-tools \
 && rm -rf /var/lib/apt/lists/*
# __DEB_BLOCK_END__
# __RPM_BLOCK_START__
RUN set -eux; \
    dnf -y install --setopt=install_weak_deps=False \
        socat jq openssh-server \
        dbus-daemon dbus-tools gnome-keyring libsecret; \
    dnf clean all; \
    rm -rf /var/cache/dnf
# __RPM_BLOCK_END__
# __APT_PKGS_BLOCK_END__


# __RECENT_GIT_BLOCK_START__
# __DEB_BLOCK_START__
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
# __DEB_BLOCK_END__
# __RPM_BLOCK_START__
# git and the credential helper: Rocky has no backports-style channel --
# AppStream ships a single git (2.43 on Rocky 9) and no supported repository
# offers a newer one. So this step only makes sure git is current within the
# enabled repos and warns when the result is older than the 2.46 the glab
# credential helper needs. Everything else works fine with 2.43; build a newer
# git from source here if you do need glab over HTTPS.
RUN set -eux; \
    dnf -y upgrade git; \
    dnf clean all; \
    git --version; \
    v="$(git --version | awk '{print $3}')"; \
    major="${v%%.*}"; rest="${v#*.}"; minor="${rest%%.*}"; \
    if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 46 ]; }; then \
        echo "note: git ${v} < 2.46 -- the glab credential helper will fall back to a password prompt" >&2; \
    fi
# __RPM_BLOCK_END__
# __RECENT_GIT_BLOCK_END__

# __CHROMIUM_BLOCK_START__
# Chromium for the 'bpmn-to-image' CLI (installed via npm in post-create.sh).
# bpmn-to-image drives a headless Chrome through Puppeteer to render BPMN
# diagrams to PNG/SVG/PDF. Puppeteer's own bundled Chrome-for-Testing has NO
# linux-arm64 build: on Apple-silicon hosts it downloads the x86-64 binary,
# which Docker Desktop's Rosetta can only run if the image ships the x86 ELF
# loader (/lib64/ld-linux-x86-64.so.2). The MS arm64 base image doesn't, so a
# render dies with "rosetta error: failed to open elf at /lib64/ld-linux-x86-64.so.2".
# Fix: install the distro's native Chromium (arm64 on Apple silicon, amd64 on
# Intel) and point Puppeteer at it, skipping its own download entirely.
#   - PUPPETEER_SKIP_DOWNLOAD (Puppeteer >= 20) suppresses the postinstall
#     browser fetch, so 'npm install -g bpmn-to-image' pulls no ~500 MB x86
#     Chrome. PUPPETEER_SKIP_CHROMIUM_DOWNLOAD is the legacy name, kept for
#     older Puppeteer transitive versions.
#   - PUPPETEER_EXECUTABLE_PATH makes puppeteer.launch() use the system binary;
#     bpmn-to-image needs no patch because it honours a plain launch().
# These are Dockerfile ENV (not containerEnv/remoteEnv) so they also apply
# during the post-create npm install, where the download must be skipped.
# __DEB_BLOCK_START__
# The 'chromium' package name is Debian's; the MS Java base is Debian bookworm.
RUN set -eux; \
    . /etc/os-release; \
    if [ "$ID" = "debian" ]; then \
        apt-get update; \
        apt-get install -y --no-install-recommends chromium; \
        rm -rf /var/lib/apt/lists/*; \
    else \
        echo "note: expected Debian base for 'chromium' package; got $ID -- adapt Dockerfile if bpmn-to-image is needed" >&2; \
    fi; \
    chromium --version || true
# __DEB_BLOCK_END__
# __RPM_BLOCK_START__
# RHEL 9 has no Chromium in BaseOS/AppStream -- it lives in EPEL, and the binary
# is called chromium-browser there. The symlink keeps PUPPETEER_EXECUTABLE_PATH
# identical across both distros.
# The epel-release package writes its own repo file pointing at the public EPEL
# mirrorlist -- open internet again, same 403 story as the other RPM repos (see
# the RPM repo swap earlier in this file). It gets overwritten to point at the
# internal mirror the same way.
RUN set -eux; \
    dnf -y install epel-release; \
    rm -f /etc/yum.repos.d/epel*.repo; \
    printf '[epel]\nname=epel Repository\nbaseurl=https://repos.ads.dmz/epel/9/x86_64\nenabled=1\ngpgcheck=0\nsslverify=0\n' > /etc/yum.repos.d/epel.repo; \
    dnf -y install chromium; \
    dnf clean all; \
    rm -rf /var/cache/dnf; \
    if [ ! -e /usr/bin/chromium ] && [ -e /usr/bin/chromium-browser ]; then \
        ln -sfn /usr/bin/chromium-browser /usr/bin/chromium; \
    fi; \
    chromium --version || true
# __RPM_BLOCK_END__
ENV PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
# __CHROMIUM_BLOCK_END__

# __GLAB_BLOCK_START__
# glab (GitLab CLI). Pinned to a known-good version; bump GLAB_VERSION in devcontainers-config.json.
# Release URL pattern: gitlab.com/gitlab-org/cli/-/releases/v<v>/downloads/glab_<v>_linux_<arch>.tar.gz
ARG GLAB_VERSION=__GLAB_VERSION__
RUN set -eux; \
    case "$(uname -m)" in \
        x86_64)        glab_arch=x86_64 ;; \
        aarch64|arm64) glab_arch=arm64  ;; \
        *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${glab_arch}.tar.gz" \
        -o /tmp/glab.tgz; \
    tar -xzf /tmp/glab.tgz -C /tmp; \
    install -m 0755 /tmp/bin/glab /usr/local/bin/glab; \
    rm -rf /tmp/glab.tgz /tmp/bin; \
    /usr/local/bin/glab --version
# __GLAB_BLOCK_END__

# __GH_BLOCK_START__
# gh (GitHub CLI). Pinned to a known-good version; bump GH_VERSION in devcontainers-config.json.
# Release URL pattern: github.com/cli/cli/releases/download/v<v>/gh_<v>_linux_<arch>.tar.gz
# The tarball extracts to gh_<v>_linux_<arch>/bin/gh.
ARG GH_VERSION=__GH_VERSION__
RUN set -eux; \
    case "$(uname -m)" in \
        x86_64)        gh_arch=amd64 ;; \
        aarch64|arm64) gh_arch=arm64 ;; \
        *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_arch}.tar.gz" \
        -o /tmp/gh.tgz; \
    tar -xzf /tmp/gh.tgz -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${gh_arch}/bin/gh" /usr/local/bin/gh; \
    rm -rf /tmp/gh.tgz "/tmp/gh_${GH_VERSION}_linux_${gh_arch}"; \
    /usr/local/bin/gh --version
# __GH_BLOCK_END__
DOCKERFILE

cat > "${WS_DIR}/.devcontainer/devcontainer.json" <<'JSON'
{
    "name": "__PROJECT_NAME__-${localWorkspaceFolderBasename}",
    "build": {
        "dockerfile": "Dockerfile"
        // __PROXY_BLOCK_START__
        ,
        // Corporate proxy, handed to the image build. Without these the
        // Dockerfile's apt/curl steps cannot reach the internet.
        "args": { __PROXY_BUILD_ARGS__ }
        // __PROXY_BLOCK_END__
    },

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
        // __RPM_BLOCK_START__
        // Debian gets these from the docker-in-docker feature's metadata
        // ("privileged": true, "init": true). With distro=rocky there is no
        // feature, so the flags are declared here: dockerd needs full
        // capabilities, and --init reaps the processes it leaves behind.
        "--privileged", "--init",
        // __RPM_BLOCK_END__
        __PORT_RUNARGS__
    ],

    // __DEB_BLOCK_START__
    "features": {
        "__FEATURE_REGISTRY__/devcontainers/features/git:1": {},
        "__FEATURE_REGISTRY__/devcontainers/features/java:1": { "version": "none", "installMaven": "true" },
        "__FEATURE_REGISTRY__/devcontainers/features/node:1": { "version": "__NODE_FEATURE_VERSION__" },
        "__FEATURE_REGISTRY__/devcontainers/features/docker-in-docker:2": { "moby": false }
    },
    // __DEB_BLOCK_END__
    // __RPM_BLOCK_START__
    // No features on a RHEL-family base: devcontainers/features/{git,java,node,
    // docker-in-docker} all shell out to apt-get in their install.sh and fail on
    // dnf. The Dockerfile installs the same toolchain from dnf / upstream
    // tarballs instead.
    "features": {},
    // __RPM_BLOCK_END__

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

        // Project-level Claude skills are shared back to the SOURCE workspace so
        // that skills created or edited by an agent inside one story container
        // are immediately available to every other container and to the base
        // workspace. Without this the workspace .claude/ is only a one-time copy
        // (see the cp -R in spawn-workspace.sh), so skill changes would stay
        // trapped in the container. This deeper bind overlays ONLY the skills/
        // subfolder on top of the workspaceMount above (deeper path wins).
        "source=__SOURCE_WS__/.claude/skills,target=__WORKSPACE_PATH__/.claude/skills,type=bind",

        "source=${localEnv:HOME}/.ssh,target=/home/vscode/.ssh,type=bind,readonly",
        "source=${localEnv:HOME}/.m2,target=/home/vscode/.m2,type=bind",
        // __RPM_BLOCK_START__
        // Docker's own storage tree on a named volume, one per container -- the
        // same thing the docker-in-docker feature declares on the Debian path.
        // Without it dockerd would write its overlay2 layers into the container
        // filesystem, which is slow and lost on every rebuild.
        "source=dind-var-lib-docker-${devcontainerId},target=/var/lib/docker,type=volume",
        // __RPM_BLOCK_END__
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
        // __GH_BLOCK_START__
        // gh (GitHub CLI) config: hosts.yml holds the github.com auth token.
        // Bind-mounted rw so 'gh auth login' run on the host or in the
        // container persists to the same file. gh uses ~/.config/gh on every
        // OS, so __GH_CONFIG_SRC__ needs no per-platform resolution.
        "source=__GH_CONFIG_SRC__,target=/home/vscode/.config/gh,type=bind",
        // __GH_BLOCK_END__
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
        "source=${localEnv:HOME}/.claude/projects/__MEMORY_KEY__/memory,target=/home/vscode/.claude/projects/__MEMORY_KEY__/memory,type=bind",
        // GitHub Copilot CLI equivalent of the ~/.claude sharing above. Only the
        // "content" subfolders are bind-mounted (skills, custom instructions,
        // saved prompts) -- NOT ~/.copilot/session-store.db or ~/.copilot/session-
        // state, which are live SQLite/session files; bind-mounting those across
        // the container boundary while the host CLI might be running concurrently
        // risks "database is locked" errors or, on some Docker Desktop VM backends,
        // outright corruption. Skills/instructions/prompts are just files an agent
        // reads, so sharing them the same way Claude's skills/ folder is shared is
        // safe and gives every devcontainer the same Copilot skills/instructions
        // without reinstalling them per container. Auth still needs one 'copilot
        // /login' per container (a few seconds), same tradeoff, safer failure mode.
        "source=${localEnv:HOME}/.copilot/skills,target=/home/vscode/.copilot/skills,type=bind",
        "source=${localEnv:HOME}/.copilot/instructions,target=/home/vscode/.copilot/instructions,type=bind",
        "source=${localEnv:HOME}/.copilot/prompts,target=/home/vscode/.copilot/prompts,type=bind"
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
        "JAVA_HOME": "__JAVA_HOME__",
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
        "TZ": "__HOST_TZ__",
        // Fixed (not auto-negotiated) D-Bus session + keyring address so every
        // process -- login shells, IDE-spawned non-login shells, exec sessions --
        // finds the same Secret Service without needing to source a profile
        // script first. post-start.sh starts the daemon + auto-unlocks the
        // keyring at exactly this address (see Step 7 there). Without this, CLI
        // tools that rely on a Secret Service backend for credential storage
        // (observed: GitHub Copilot CLI's login) find none in this minimal
        // container and either error out or fall back to storing the token in
        // plaintext.
        // Names of env vars on the host that get forwarded into the container.
        // Baked into BOTH remoteEnv (below) and containerEnv (see
        // __CONTAINER_ENV_FORWARDED__ above the closing brace) so any
        // '${TOKEN}'-style placeholder in ~/.npmrc / ~/.m2/settings.xml OR in a
        // project-local .npmrc (e.g. checked-in webapp/.npmrc referencing
        // '${NEXUS_TOKEN_BASE64}') resolves inside the container regardless of
        // how the process that runs npm/mvn was launched.
        "XDG_RUNTIME_DIR": "/run/user/1000",
        "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
        // Auto-approve GitHub Copilot CLI tool calls, mirroring Claude Code's
        // permissions.defaultMode=bypassPermissions above (see .claude/settings.local.json
        // written further up): the container is a sandbox and all tool calls go through
        // it, so skipping the interactive confirmation prompt here doesn't loosen
        // anything on the host. Equivalent to always passing --allow-all-tools.
        "COPILOT_ALLOW_ALL": "true"__CONTAINER_ENV_FORWARDED____PROXY_CONTAINER_ENV__
    },

    // remoteEnv has higher precedence than containerEnv (and any feature's
    // containerEnv) for processes started by the remote daemon -- IntelliJ's
    // terminal, the Claude plugin, lifecycle scripts run by the dev daemon.
    //
    // - JAVA_HOME: restated here because the java:1 feature (needed only for
    //   Maven via SDKMAN) can leave its own JAVA_HOME pointing at an empty
    //   SDKMAN candidate directory when version=none.
    // - FORWARDED_ENV_VARS from devcontainers-config.json: forwarded from host so that any
    //   '${TOKEN}'-style placeholder in the user's ~/.npmrc / ~/.m2/settings.xml
    //   resolves inside the container. Otherwise npm install of private
    //   packages and Maven resolution from private repos fail with 401.
    //   These read from the env that LAUNCHED IntelliJ (or that ran spawn-
    //   workspace.sh). If empty, run with .envrc loaded ('direnv allow' in
    //   the source workspace, then start IntelliJ from that shell).
    "remoteEnv": {
        "JAVA_HOME": "__JAVA_HOME__"__REMOTE_ENV_FORWARDED__
    },

    // Port labels for the JetBrains Services view. Keys are the container-side
    // port numbers; the host-side port comes from runArgs -p above. Suppress
    // the auto-forward notification that pops up every time a service starts.
    // Labels come from PORT_LABELS in devcontainers-config.json.
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

# Build dynamic JSON fragments from devcontainers-config.json arrays. These are injected via the
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

# Same vars, ALSO baked into containerEnv (not just remoteEnv). remoteEnv is
# resolved per remote-launched process and, per the DOCKER_API_VERSION comment
# in the devcontainer.json template, some IntelliJ launch paths (run configs,
# background tasks) bypass it entirely. containerEnv is set once at
# container-create time and reaches every process unconditionally, so
# private-registry tokens referenced by in-repo '${TOKEN}'-style
# .npmrc/settings.xml files (not just the HOME ~/.npmrc that spawn-workspace
# resolves itself) still work when npm/Maven is invoked from a context
# remoteEnv doesn't cover.
CONTAINER_ENV_FORWARDED=""
if [[ ${#FORWARDED_ENV_VARS[@]} -gt 0 ]]; then
    for var in "${FORWARDED_ENV_VARS[@]}"; do
        CONTAINER_ENV_FORWARDED="${CONTAINER_ENV_FORWARDED}, \"${var}\": \"\${localEnv:${var}}\""
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
        -e "s/__GH_VERSION__/${GH_VERSION:-}/g" \
        -e "s|__REMOTE_ENV_FORWARDED__|${REMOTE_ENV_FORWARDED}|g" \
        -e "s|__CONTAINER_ENV_FORWARDED__|${CONTAINER_ENV_FORWARDED}|g" \
        -e "s|__PORTS_ATTRS__|${PORTS_ATTRS}|g" \
        -e "s|__GLAB_CONFIG_SRC__|${GLAB_CONFIG_SRC}|g" \
        -e "s|__GH_CONFIG_SRC__|${GH_CONFIG_SRC}|g" \
        -e "s|__SSH_AGENT_SRC__|${SSH_AGENT_SRC}|g" \
        -e "s|__HOST_TZ__|${HOST_TZ}|g" \
        -e "s/__PORT_OFFSET__/${PORT_OFFSET}/g" \
        -e "s/__SSH_HOST_PORT__/${SSH_HOST_PORT}/g" \
        -e "s/__FIRST_REPO__/${FIRST_REPO}/g" \
        -e "s|__SPAWN_CMD__|spawn-workspace.sh|g" \
        -e "s|__DISPOSE_CMD__|${DISPOSE_CMD}|g" \
        -e "s|__PROXY_BUILD_ARGS__|${PROXY_BUILD_ARGS}|g" \
        -e "s|__PROXY_CONTAINER_ENV__|${PROXY_CONTAINER_ENV}|g" \
        -e "s|__FEATURE_REGISTRY__|${FEATURE_REGISTRY}|g" \
        -e "s|__JAVA_HOME__|${JAVA_HOME_PATH}|g" \
        -e "s|__SYSTEM_BASHRC__|${SYSTEM_BASHRC}|g" \
        -e "s/__JAVA_VERSION__/${JAVA_VERSION}/g" \
        -e "s/__MAVEN_VERSION__/${MAVEN_VERSION}/g" \
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

    # Same conditional handling for the gh (GitHub CLI) blocks.
    if [[ ${GH_ENABLED} -eq 1 ]]; then
        sed -i.bak \
            -e '/__GH_BLOCK_START__/d' \
            -e '/__GH_BLOCK_END__/d' \
            "${file}"
    else
        sed -i.bak \
            -e '/__GH_BLOCK_START__/,/__GH_BLOCK_END__/d' \
            "${file}"
    fi
    rm "${file}.bak"

    # ... and for the three corporate-proxy blocks. Each is independent: a
    # project may need only the CA certificates (proxy configured globally in
    # Docker Desktop), only the proxy URLs, or all three.
    strip_block() {
        local marker="$1" enabled="$2"
        if [[ ${enabled} -eq 1 ]]; then
            sed -i.bak -e "/__${marker}_BLOCK_START__/d" -e "/__${marker}_BLOCK_END__/d" "${file}"
        else
            sed -i.bak -e "/__${marker}_BLOCK_START__/,/__${marker}_BLOCK_END__/d" "${file}"
        fi
        rm "${file}.bak"
    }
    strip_block PROXY "${PROXY_ENABLED}"
    strip_block CA "${CA_ENABLED}"
    strip_block APT_HTTPS "${PROXY_DEBIAN_HTTPS_ENABLED}"
    strip_block APT_PKGS "${APT_PKGS_ENABLED}"
    strip_block RECENT_GIT "${RECENT_GIT_ENABLED}"
    strip_block CHROMIUM "${CHROMIUM_ENABLED}"

    # Distro split LAST. The DEB/RPM markers are NESTED inside several of the
    # blocks above (PROXY, CA, APT_HTTPS, APT_PKGS, RECENT_GIT, CHROMIUM), and
    # sed's range delete stops at the first END marker it sees -- so the outer
    # pairs have to be resolved before these.
    strip_block DEB "${DEBIAN_ENABLED}"
    strip_block RPM "${IS_ROCKY}"
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
        __JAVA_HOME__ \
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
    echo "ERROR: no JDK found at known locations (__JAVA_HOME__, /usr/lib/jvm/msopenjdk-current, SDKMAN, /opt/java/openjdk)" >&2
    exit 1
fi

cd __WORKSPACE_PATH__

# XDG_RUNTIME_DIR is pinned to /run/user/1000 via containerEnv, but that dir is
# created by post-start.sh -- which the devcontainer lifecycle runs AFTER
# postCreate. Create it here too (idempotent, same as post-start.sh) so the
# nested dockerd has it before the initialize.sh hook below runs `docker
# compose`; without it the daemon aborts container creation with
#   "failed to create temp dir: stat /run/user/1000: no such file or directory".
_rt="${XDG_RUNTIME_DIR:-/run/user/1000}"
sudo mkdir -p "${_rt}"
sudo chown "$(id -u):$(id -g)" "${_rt}"
chmod 700 "${_rt}"

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
#
# Non-fatal: this is an optional AI-assistant convenience tool, not something the
# devcontainer itself depends on, so a registry hiccup here shouldn't block the
# whole setup. The most common cause is the HOST's ~/.npmrc having no top-level
# "registry=" line, so npm defaults to registry.npmjs.org, which a corporate
# proxy commonly blocks outright (403 MediaTypeBlocked) -- point it at your
# internal npm mirror/group repo instead (e.g. "registry=https://<nexus-host>/
# repository/<npm-group-repo>/") in ~/.npmrc on the HOST; spawn-workspace re-reads
# and copies it into every new workspace automatically.
if ! bash -lc "npm install -g @anthropic-ai/claude-code"; then
    echo "WARN: Claude Code install failed -- see the npm error above." >&2
    echo "      If it says '403 MediaTypeBlocked' from registry.npmjs.org, add a" >&2
    echo "      'registry=' line to ~/.npmrc on the HOST (pointing at your internal" >&2
    echo "      npm mirror) and re-spawn the workspace." >&2
fi

# install the GitHub Copilot CLI globally, same rationale and same non-fatal
# handling as Claude Code above. Unlike the JetBrains Copilot plugin (which
# hardcodes a local proxy port and doesn't understand Gateway's remote-dev
# workspace URIs), the CLI is a plain terminal process that reads HTTP_PROXY/
# HTTPS_PROXY from the environment -- already wired into the container via
# containerEnv, so no 8888 forward needed.
if ! bash -lc "npm install -g @github/copilot"; then
    echo "WARN: GitHub Copilot CLI install failed -- see the npm error above (same" >&2
    echo "      registry= hint as the Claude Code warning applies here too)." >&2
fi

# __CHROMIUM_BLOCK_START__
# install bpmn-to-image (https://github.com/bpmn-io/bpmn-to-image) globally.
# Must run here, not in the Dockerfile, because node/npm come from the Node
# devcontainer feature, which installs AFTER the image build. The Dockerfile's
# PUPPETEER_SKIP_DOWNLOAD=true ENV is in effect here, so Puppeteer skips its
# (x86-only, Rosetta-breaking) Chrome download and the CLI uses the system
# chromium via PUPPETEER_EXECUTABLE_PATH at render time.
#
# Non-fatal (like Claude Code/Copilot CLI above): this IS a functional
# dependency of the project's own tooling, so the WARN is louder -- but a
# registry hiccup here must not abort the whole post-create and take the mvn/
# claude symlinks, the copilot chown and the Maven warmup down with it. If it
# 403s with MediaTypeBlocked, see the registry= hint two blocks up -- same root
# cause, same fix -- then re-run `npm install -g bpmn-to-image` in the container.
if ! bash -lc "npm install -g bpmn-to-image"; then
    echo "WARN: bpmn-to-image install failed -- see the npm error above. This is a" >&2
    echo "      functional dependency: BPMN diagram rendering will not work until it" >&2
    echo "      is installed. Same registry= hint as the Claude Code warning applies." >&2
fi
# __CHROMIUM_BLOCK_END__

# named volume for per-story Claude project state is owned by root after first mount
sudo chown -R vscode:vscode /home/vscode/.claude/projects/__MEMORY_KEY__ || true

# Docker auto-creates missing bind-mount parent directories as root:root before
# the mount happens. ~/.copilot/{skills,instructions,prompts} are bind-mounted
# (see the mounts block above), but ~/.copilot ITSELF does not exist in the base
# image, so Docker creates it as root, leaving the vscode user unable to write
# ~/.copilot/config.json, session-store.db, logs/, etc. Without this, the
# GitHub Copilot CLI fails to initialize and exits silently (no output at all,
# not even the "no authentication" message) -- looks like a hang, not an error.
sudo chown vscode:vscode /home/vscode/.copilot || true

# Expose mvn and claude on /usr/local/bin so they work in IDE-spawned non-login
# shells (IntelliJ terminal, Claude plugin) where shell init is sometimes skipped.
# We resolve the real path through a login shell, which sources sdkman/nvm.
for cmd in mvn claude bpmn-to-image; do
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
# GitLab host (GLAB_HOSTNAME from devcontainers-config.json). glab is installed in the image
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

# __GH_BLOCK_START__
# Wire gh as git's credential helper for HTTPS operations on github.com, so
# pushes/pulls to HTTPS github remotes (e.g. the *.wiki repos) reuse the token
# from the bind-mounted gh config without prompting. SSH remotes are unaffected
# -- they keep using the forwarded ssh-agent. Unlike glab, gh's own
# 'gh auth git-credential' is well-behaved, so 'gh auth setup-git' wires it
# directly (no wrapper needed). It's idempotent and only a no-op warning when
# gh isn't logged in yet.
gh auth setup-git 2>/dev/null \
    || echo "note: 'gh auth setup-git' skipped -- run 'gh auth login' (host or container) to enable HTTPS github pushes"
# __GH_BLOCK_END__

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
#   - __SYSTEM_BASHRC__ append     : sourced by interactive non-login bashes
#                                    (which JetBrains' terminal usually is)
# The bashrc layer runs AFTER SSH forwarding and reliably overrides.
sudo tee /etc/profile.d/zz-__PROJECT_SHORT__-env.sh >/dev/null <<'PROF'
export JAVA_HOME=__JAVA_HOME__
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

if ! grep -q '# __PROJECT_SHORT__ container locale + docker overrides' __SYSTEM_BASHRC__ 2>/dev/null; then
    sudo tee -a __SYSTEM_BASHRC__ >/dev/null <<'BASHRC'

# __PROJECT_SHORT__ container locale + docker + java overrides. Sourced AFTER
# SDKMAN's init (which the java:1 feature with version=none drops onto
# interactive shells) so we win when SDKMAN points JAVA_HOME at /usr/local/
# sdkman/candidates/java/current -- a directory that doesn't exist when java
# isn't installed via SDKMAN. Also blocks macOS-Terminal SSH forwarding of
# LC_CTYPE=UTF-8 which glibc can't parse, and ensures DOCKER_API_VERSION is
# set even for IDE-spawned shells that don't go through /etc/profile.
export JAVA_HOME=__JAVA_HOME__
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

# Resolve build dependencies in order (BUILDS / MAVEN_BUILDS in devcontainers-config.json).
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
# MAVEN_BUILD_COMMANDS is multi-line and __HOST_MOUNT_PRUNE__ sits inline inside
# a find(1) expression (and may be empty); splice both literally before sed takes
# over -- see the splice_placeholder comment for why bash's own ${var/pat/repl}
# must not be used here.
splice_placeholder "${WS_DIR}/.devcontainer/post-create.sh" "__MAVEN_BUILD_COMMANDS__" "${MAVEN_BUILD_COMMANDS}"
splice_placeholder "${WS_DIR}/.devcontainer/post-create.sh" "__HOST_MOUNT_PRUNE__" "${HOST_MOUNT_PRUNE}"

# Copy optional initialization hook into the workspace's .devcontainer/.
# post-create.sh runs it before the Maven warmup builds if present. Looked up
# next to devcontainers-config.json first, so each project can ship its own hook.
if _init_hook="$(config_asset initialize.sh)"; then
    cp "${_init_hook}" "${WS_DIR}/.devcontainer/initialize.sh"
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
# (devcontainers-config.json) via 'docker run -p'. Add 2222 to HOST_PORTS so this sshd is
# reachable from the host at 2222+offset. Without that entry sshd still runs
# but is only reachable from inside the container.
if ! [ -x /usr/sbin/sshd ]; then
    echo "note: openssh-server not installed -- skipping the DB-tunnel sshd"
    exit 0
fi

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

# The devcontainer 'vscode' account ships with a locked password (shadow field
# '!', login is via sudo NOPASSWD). With 'UsePAM no' below, sshd's locked-account
# check (platform_locked_account) treats a '!'-prefixed shadow entry as an
# invalid user and refuses EVERY auth method -- including pubkey -- so the DB
# tunnel login fails with "Permission denied (publickey)". Clearing the lock to
# '*' leaves the account without a usable login password (sudo still governs
# access) but no longer flagged locked, so pubkey auth proceeds. Idempotent.
sudo usermod -p '*' vscode 2>/dev/null || true

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

# Step 6: forward container-local 127.0.0.1:8888 to the real corporate proxy.
# Some IDE plugins (observed: GitHub Copilot) don't honour HTTP_PROXY/http_proxy
# and instead hardcode a local proxy port (8888 = the usual Fiddler port on the
# HOST). Inside the container 127.0.0.1:8888 is just empty loopback, so those
# plugins fail silently. We already know the *real* proxy address works (it's
# wired into HTTP_PROXY/http_proxy above), so just relay 8888 to it -- same
# socat pattern as the docker-socket forward in step 3.
_proxy_target="${HTTP_PROXY:-${http_proxy:-}}"
if [[ -n "${_proxy_target}" ]]; then
    _proxy_hostport="${_proxy_target#*://}"
    _proxy_hostport="${_proxy_hostport%%/*}"
    if [[ "${_proxy_hostport}" == *:8888 ]]; then
        echo "note: proxy already lives on port 8888 -- skipping self-forward (would loop)"
    elif (exec 3<>"/dev/tcp/127.0.0.1/8888") 2>/dev/null; then
        exec 3>&- 3<&- 2>/dev/null || true
        echo "127.0.0.1:8888 already has a listener -- leaving it alone"
    elif command -v socat >/dev/null 2>&1; then
        # -d -d makes socat log every accepted connection and its outcome to
        # /tmp/socat-proxy8888.log -- without it the log only ever shows the
        # startup line, which makes it impossible to tell whether a silently
        # failing tool (e.g. the Copilot plugin) even attempted to connect.
        nohup socat -d -d TCP-LISTEN:8888,bind=127.0.0.1,reuseaddr,fork \
                    TCP:"${_proxy_hostport}" \
                    >/tmp/socat-proxy8888.log 2>&1 &
        echo "socat forwarding 127.0.0.1:8888 -> ${_proxy_hostport} (for tools that hardcode a local proxy port)"
        echo "  connection attempts logged to /tmp/socat-proxy8888.log"
    else
        echo "note: socat not installed -- 8888 proxy forward unavailable"
    fi
else
    echo "note: no HTTP_PROXY configured -- skipping 8888 proxy forward"
fi

# Step 7: start a per-container D-Bus session bus + an auto-unlocked gnome-keyring
# at the FIXED address from containerEnv (XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS
# above), so CLI tools that rely on a real Secret Service backend for credential
# storage (observed: GitHub Copilot CLI's login -- it warned there was no secure
# place to store the token) have one. Without this, such a container is "just" a
# minimal Linux userland with no session bus at all, so libsecret-based storage
# fails outright or silently degrades to a plaintext fallback.
#
# A FIXED (not randomly-generated, as dbus-daemon --print-address would produce)
# socket path is what makes this work from every shell/exec session without any
# extra sourcing step: it's the same value containerEnv already put in every
# process's environment at PID 1, so any new terminal/exec just finds the socket
# that's already there.
_runtime_dir="${XDG_RUNTIME_DIR:-/run/user/1000}"
sudo mkdir -p "${_runtime_dir}"
sudo chown "$(id -u):$(id -g)" "${_runtime_dir}"
chmod 700 "${_runtime_dir}"
# /run/user/1000 is NOT guaranteed to be a fresh tmpfs on every container start
# (it can be a plain directory on the container's writable layer), so a `docker
# stop`/`start` cycle can kill the dbus-daemon process while leaving its unix
# socket special file behind. A bare `-S` test only checks "is this a socket
# file", not "is anything listening on it", so it was mistaking that stale file
# for a live bus and skipping the daemon restart -- leaving gnome-keyring (and
# therefore the GitHub Copilot CLI's Secret Service backend) permanently
# unreachable until the container was rebuilt from scratch. Probe the bus with
# a real D-Bus call and only trust it if that call actually succeeds.
_bus_alive=false
if [[ -S "${_runtime_dir}/bus" ]] && command -v dbus-send >/dev/null 2>&1 \
   && DBUS_SESSION_BUS_ADDRESS="unix:path=${_runtime_dir}/bus" dbus-send --session \
        --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
    _bus_alive=true
fi
if $_bus_alive; then
    echo "D-Bus session bus already listening at ${_runtime_dir}/bus"
else
    # Remove a stale/dead socket file before rebinding, otherwise dbus-daemon
    # fails with "Address already in use" instead of starting a fresh bus.
    rm -f "${_runtime_dir}/bus"
    if command -v dbus-daemon >/dev/null 2>&1; then
        nohup dbus-daemon --session --address="unix:path=${_runtime_dir}/bus" --nofork \
                    >/tmp/dbus-session.log 2>&1 &
        # give the daemon a moment to create the socket before anything tries to use it
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            [[ -S "${_runtime_dir}/bus" ]] && break
            sleep 0.2
        done
        echo "D-Bus session bus started at ${_runtime_dir}/bus"
    else
        echo "note: dbus-daemon not installed -- Secret Service backend unavailable"
    fi
fi
if [[ -S "${_runtime_dir}/bus" ]] && command -v gnome-keyring-daemon >/dev/null 2>&1; then
    if pgrep -u "$(id -u)" -f 'gnome-keyring-daemon' >/dev/null 2>&1; then
        echo "gnome-keyring-daemon already running"
    else
        # Empty password unlocks (or, on first run, creates) the "login" keyring
        # non-interactively -- there's no desktop session here to prompt for one,
        # and an unlocked-but-still-encrypted-at-rest keyring is the point: it
        # protects the token from casual reading (e.g. `docker cp`ing the volume
        # out and grepping it) without needing any secret of its own to unlock.
        printf '\n' | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1 || true
        nohup gnome-keyring-daemon --start --components=secrets --foreground \
                    >/tmp/gnome-keyring.log 2>&1 &
        echo "gnome-keyring-daemon started (Secret Service backend for credential storage)"
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

# ============================================================================
# Base-image caching
# ============================================================================
# Everything the Dockerfile does up to this point (repo setup, base tooling,
# JDK/Maven/Node, docker-ce, socat/jq/sshd, git upgrade, chromium, glab, gh) is
# fully determined by devcontainers-config.json plus the certs/rocky-repos files written
# above -- nothing in it depends on the story/branch name. Left alone, the
# IDE's own `docker build` redoes all of that (5-10 min) for every single new
# workspace. Instead we pre-build it ONCE here into a locally tagged image
# (tag keyed by a hash of exactly those inputs) and collapse this workspace's
# own Dockerfile down to a single `FROM <tag>`. Any later workspace whose
# devcontainers-config.json/certs/repo files are unchanged hits the same tag and skips
# straight past "FROM" -- seconds instead of minutes.
DOCKERFILE_PATH="${WS_DIR}/.devcontainer/Dockerfile"
CERTS_DIR="${WS_DIR}/.devcontainer/certs"
ROCKY_REPO_DIR="${WS_DIR}/.devcontainer/rocky-repos"

_hash_input="$(cat "${DOCKERFILE_PATH}")"
for _d in "${CERTS_DIR}" "${ROCKY_REPO_DIR}"; do
    [[ -d "${_d}" ]] || continue
    for _f in "${_d}"/*; do
        [[ -f "${_f}" ]] || continue
        _hash_input="${_hash_input}|file:$(basename "${_f}")|$(cat "${_f}")"
    done
done
BASE_IMAGE_HASH="$(printf '%s' "${_hash_input}" | sha256sum | cut -c1-12)"
BASE_IMAGE_TAG="devcontainer-base:${DISTRO}-${BASE_IMAGE_HASH}"

BASE_EXISTS=0
docker image inspect "${BASE_IMAGE_TAG}" >/dev/null 2>&1 && BASE_EXISTS=1

if (( REBUILD_BASE_IMAGE == 1 || BASE_EXISTS == 0 )); then
    echo ""
    if (( REBUILD_BASE_IMAGE == 1 && BASE_EXISTS == 1 )); then
        echo "rebuilding base image (--rebuild-base-image): ${BASE_IMAGE_TAG}"
    else
        echo "base image cache miss -- building ${BASE_IMAGE_TAG} once (subsequent workspaces reuse it)..."
    fi
    _docker_build_args=(build -t "${BASE_IMAGE_TAG}")
    if (( PROXY_ENABLED == 1 )); then
        _docker_build_args+=(--build-arg "HTTP_PROXY=${_p_http}" --build-arg "HTTPS_PROXY=${_p_https}" \
                              --build-arg "http_proxy=${_p_http}" --build-arg "https_proxy=${_p_https}")
        if [[ -n "${PROXY_NO}" ]]; then
            _docker_build_args+=(--build-arg "NO_PROXY=${PROXY_NO}" --build-arg "no_proxy=${PROXY_NO}")
        fi
    fi
    _docker_build_args+=("${WS_DIR}/.devcontainer")
    if ! docker "${_docker_build_args[@]}"; then
        echo "ERROR: base image build failed (${BASE_IMAGE_TAG}) -- see docker output above" >&2
        exit 1
    fi
    echo "base image ready: ${BASE_IMAGE_TAG}"
else
    echo "base image cache hit: ${BASE_IMAGE_TAG} (skipping the dnf/JDK/Maven/Node/Docker-CE install)"
fi

cat > "${DOCKERFILE_PATH}" <<DOCKERFILEBASE
# Cached base image -- collapsed from the full Rocky/Debian setup Dockerfile
# by spawn-workspace.sh's base-image caching step (see there for the "why").
# The tag below was pre-built and is already local, so this \`docker build\`
# just resolves FROM and finishes in seconds.
#
# Config changed (version bump, new proxy, different certs/repo mirror)? The
# tag's hash covers all of that automatically, so a real change gets a new
# tag and a fresh build on the next spawn. To force a rebuild WITHOUT a
# config change (e.g. the internal mirror's package set moved forward), run:
#   spawn-workspace.sh --rebuild-base-image <branch-name>
# or manually: docker rmi ${BASE_IMAGE_TAG}
FROM ${BASE_IMAGE_TAG}

# Unused now that FROM points at a prebuilt tag (no RUN below consumes them),
# but kept declared so devcontainer.json's build.args don't trigger a
# "build arg not consumed" warning.
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy
DOCKERFILEBASE

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
  dispose-workspace.sh ${DISPOSE_CONFIG_HINT}${BRANCH}
EOF
