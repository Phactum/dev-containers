# CLAUDE.md

Guidance for working on this repository. Read `README.md` first for user-facing
usage; this file captures the internal structure and conventions you need before
editing anything.

## What this repo is

Tooling that spins up **one isolated IntelliJ DevContainer per story** on
top of a multi-repo workspace. `spawn-workspace.sh` creates a sibling workspace
directory (`<workspaces-root>/<PROJECT_NAME>-<branch-leaf>/`) containing one git
worktree per source repo plus a fully generated `.devcontainer/`, `.idea/`,
`.claude/` and a welcome `README.md`. `dispose-workspace.sh` tears it all down.

`spawn-workspace.ps1` / `dispose-workspace.ps1` are the Windows PowerShell ports
of those two scripts: same CLI, same behaviour, same generated artifacts, same
`devcontainers-config.json`. **Any behaviour change must be applied to both implementations**
â€” they are expected to stay in lockstep.

This repository is **cloned once and put on the PATH**; it is NOT copied into
each project. Everything project-specific lives in that project's own
`dev-containers/devcontainers-config.json` inside its source workspace. Consequently there are
two distinct base directories, and confusing them is the single most likely way
to break the PATH-install:

| Variable                          | Meaning |
|-----------------------------------|---------|
| `SCRIPT_DIR` / `$PSScriptRoot`    | where the scripts live (anywhere on the PATH). Only the sibling loaders (`env-config.sh`, `EnvConfig.ps1`, `Common.ps1`) and the *fallback* asset copies may be read from here. |
| `CONFIG_DIR` / `$ConfigDir`       | the directory of the resolved `devcontainers-config.json`. The project's base directory: assets and the workspaces-root auto-detect derive from it. |

Rules that follow from that:

- Never derive the workspaces root, or any project path, from `SCRIPT_DIR`.
- Read project assets through `config_asset` (Bash) / `Get-ConfigAsset`
  (PowerShell): `CONFIG_DIR` first, `SCRIPT_DIR` as fallback.
- The Bash scripts resolve `$0` through symlinks before computing `SCRIPT_DIR`,
  because a PATH install typically symlinks them into `/usr/local/bin`.

## Conditional blocks in the templates

Nine marker pairs drive optional content in the generated files. Each is
independent, and `substitute_placeholders` / `Update-Placeholders` either strips
just the markers (feature on) or the markers **and** everything between them
(feature off):

| Marker | Driven by |
|---|---|
| `__GLAB_BLOCK_*__` | `glabHostname` + `glabVersion` |
| `__GH_BLOCK_*__` | `ghVersion` |
| `__SSHAGENT_BLOCK_*__` | PowerShell only: the Windows `ssh-agent` service is running |
| `__PROXY_BLOCK_*__` | `proxy.http` / `proxy.https` |
| `__CA_BLOCK_*__` | `proxy.caCertificates` |
| `__APT_HTTPS_BLOCK_*__` | `proxy.debianUseHttps` / `proxy.useHttpsRepos` |
| `__APT_PKGS_BLOCK_*__` | `imageBuild.aptPackages` / `imageBuild.packages` |
| `__RECENT_GIT_BLOCK_*__` | `imageBuild.recentGit` |
| `__CHROMIUM_BLOCK_*__` | `imageBuild.chromium` (Dockerfile **and** the bpmn-to-image install in post-create.sh) |
| `__DEB_BLOCK_*__` / `__RPM_BLOCK_*__` | `distro` (`debian` \| `rocky`) â€” exactly one of the two survives |

When adding optional content, wrap it in a marker pair rather than branching in
the generating script â€” that keeps the templates readable and the two language
ports in sync.

**`__DEB__` / `__RPM__` are nested inside other blocks and must therefore be
resolved LAST.** Neither remover carries a nesting depth counter:
`Remove-ConditionalBlock` toggles a flag on the first start marker it sees, and
the Bash `strip_block` uses a `sed` range that ends at the first END marker.
That works for nesting only as long as the *outer* block is processed first â€” a
disabled outer block then drops the inner markers along with its content, and an
enabled one leaves a clean, balanced inner pair behind. Keep the distro pass at
the end of `Update-Placeholders` / `substitute_placeholders` and never nest two
blocks that are resolved in the wrong order.

**jq booleans: never use `//`.** `.x // true` returns `true` when `.x` is null
*or false*, so an explicit `false` in the config silently becomes the default.
`env-config.sh` therefore has a dedicated `_env_bool` helper; `_env_scalar`'s
`// ""` fallback has the same flaw and must not be used for booleans either.
This bit once, and it fails silently â€” the config looks respected but isn't.

## Distro split (`distro`: `debian` | `rocky`)

PowerShell and Bash both support it. `spawn-workspace.ps1` sets `$IsRocky` /
`$DebianEnabled`, `spawn-workspace.sh` sets `IS_ROCKY` / `DEBIAN_ENABLED` from
the config key, and both resolve `__JAVA_HOME__`, `__SYSTEM_BASHRC__`,
`__JAVA_VERSION__` and `__MAVEN_VERSION__` accordingly. What the rocky path has
to reproduce by hand, because the devcontainer features are Debian/Ubuntu-only
(their `install.sh` calls `apt-get` and aborts elsewhere):

| Feature it replaces | Dockerfile step |
|---|---|
| base image's user | `vscode` (uid/gid 1000) + `sudoers.d` drop-in with a widened `secure_path` |
| `java:1` | `java-<javaVersion>-openjdk-devel` from dnf, plus a `/usr/lib/jvm/devcontainer-java` symlink so `JAVA_HOME` has one stable value |
| `java:1` (`installMaven`) | Apache binary tarball into `/opt/maven`, `mvn` linked into `/usr/local/bin` |
| `node:1` | NodeSource `setup_<major>.x`, AppStream module as fallback; npm's global prefix moved to `/usr/local` and chowned to `vscode` so `npm install -g` needs no sudo |
| `docker-in-docker:2` | `docker-ce` from Docker's RHEL repo; `--privileged`, `--init` and the `/var/lib/docker` volume are declared in `devcontainer.json` instead of coming from feature metadata |

Anything that is *not* optional must stay outside the `__APT_PKGS_BLOCK_*__`
switch â€” turning that off has to cost convenience (socat/jq/sshd), never a
working container.



Three independent switches in `devcontainers-config.json`'s optional `proxy` block, each
driving a conditional block in the generated files (`__PROXY_BLOCK_*__`,
`__CA_BLOCK_*__`, `__APT_HTTPS_BLOCK_*__`). All default to off, so a project
without a `proxy` block produces byte-identical output to before.

| Switch | Bash / PowerShell flag | Effect |
|---|---|---|
| proxy URLs | `PROXY_ENABLED` / `$ProxyEnabled` | `build.args` + `containerEnv` entries, `ARG` declarations in the Dockerfile |
| CA certs | `CA_ENABLED` / `$CaEnabled` | certs copied to `.devcontainer/certs/`, installed into three trust stores |
| apt/dnf over https | `PROXY_DEBIAN_HTTPS_ENABLED` / `$AptHttpsEnabled` | rewrites the apt sources before the first `apt-get`; on `distro=rocky` it disables the mirrorlist and pins the https baseurl instead |

Things to keep in mind when touching this:

- **Three trust stores, not one.** The OS bundle (`update-ca-certificates` on
  Debian, `update-ca-trust` on Rocky) covers curl/apt/dnf/git. Maven ignores it
  and needs the CA in `$JAVA_HOME/lib/security/cacerts` (`keytool` â€” on Rocky
  that file is a symlink into the extracted ca-trust store, so `update-ca-trust`
  is enough). Node ignores it too and needs `NODE_EXTRA_CA_CERTS`. Dropping any
  of the three breaks a real workflow.
- **Both spellings of the proxy variables** are emitted (`HTTP_PROXY` *and*
  `http_proxy`, ...). Tools disagree about which they read; apt in particular
  wants the lowercase ones. In PowerShell this cannot be built from a hashtable
  â€” its keys are case-insensitive, so the two spellings collide. Use the list of
  pairs that is already there.
- **`host.docker.internal`, never `127.0.0.1`**, for a proxy running on the
  host. This is worth repeating in any error message or doc you add.
- The CA files are copied into `.devcontainer/certs/` because a Docker build
  context cannot reference anything outside its own directory.

## Config lookup

Both implementations resolve `devcontainers-config.json` identically:

1. `--config <path>` â€” the file itself, or a directory containing `devcontainers-config.json`
2. `./dev-containers/devcontainers-config.json`, relative to the **current working directory**
3. `./devcontainers-config.json`, relative to the **current working directory**

Resolving against the working directory (not the script location) is what makes
one clone serve every project. Argument parsing therefore happens **before** the
config is loaded â€” `--config` decides what to load, so it cannot depend on it.

Because every other project asset falls back to the copy in this clone, a lone
`devcontainers-config.json` in the project directory is a complete setup. Keep that property
in mind when adding a new asset: always go through the fallback helper, never
require a file to exist next to the config.

## Workspaces-root resolution

Implemented **once per language** â€” `resolve_workspaces_root` in
`env-config.sh`, `Resolve-WorkspacesRoot` in `EnvConfig.ps1` â€” and called by
both the spawn and the dispose script, so the two can never disagree about
where a workspace lives. Priority:

1. `--workspaces-root` flag
2. `$<PROJECT_SHORT>_WORKSPACES_ROOT` env var
3. `"workspacesRoot"` in `devcontainers-config.json` (relative â†’ resolved against `CONFIG_DIR`)
4. auto-detect: walk up from `CONFIG_DIR` to the directory named `projectName`
   (the source workspace) and take its parent; fall back to two levels above
   `CONFIG_DIR` (the historical rule) when no such directory is found

The walk-up is what makes both `<root>/<PROJECT>/devcontainers-config.json` and
`<root>/<PROJECT>/dev-containers/devcontainers-config.json` resolve to `<root>` without any
configuration. Note that the Bash function `return`s (rather than `exit`s) on
error because it runs inside a command substitution; callers append `|| exit 1`.

## Files

| File / Dir                | Role |
|---------------------------|------|
| `spawn-workspace.sh`      | Creates a story workspace + DevContainer (macOS/Linux). ~2000 lines, all generation logic. |
| `dispose-workspace.sh`    | Tears down a workspace: worktrees, container, volumes, image, dir (macOS/Linux). |
| `spawn-workspace.ps1`     | Windows port of `spawn-workspace.sh`. Its header documents the platform deltas. |
| `dispose-workspace.ps1`   | Windows port of `dispose-workspace.sh`. |
| `env-config.sh`           | Bash loader for `devcontainers-config.json` (uses `jq`); expects `CONFIG_JSON` to be set by the caller. |
| `EnvConfig.ps1`           | PowerShell loader (`ConvertFrom-Json`, no module needed) + `Resolve-DevContainerConfigPath`. |
| `Common.ps1`              | Shared PowerShell helpers (LF/no-BOM file writing, git/docker wrappers, path math). |
| `devcontainers-config.json`             | **Per project**, in that project's `dev-containers/`. The copy in this repo is the reference/example. |
| `README.md.tpl`           | DEFAULT template for the welcome README written to each new workspace root (NOT this repo's README). Overridable per project. |
| `initialize.sh`           | Optional opt-in hook copied into the workspace; runs before the Maven warmup build. Overridable per project. |
| `runConfigurations/*.xml` | DEFAULT IntelliJ run configs copied into new workspaces (listed in `runConfigs`). Overridable per project. |
| `readme/`                 | Screenshots + demo videos referenced by `README.md`. |
| `README.md` / `README.md.tpl` are distinct â€” see the "Two READMEs" gotcha below. |

## Configuration format

`devcontainers-config.json` is **JSONC**: plain JSON plus full-line `//` comments. Both loaders
blank out lines whose first non-whitespace characters are `//` before parsing,
so a `//` inside a string value (a URL) survives. Trailing comments after a
value are NOT supported.

Optional settings are disabled by **omitting the key** (or setting it to `null`
/ `""`). `mavenBuilds` and `builds` are mutually exclusive and the *presence* of
the key â€” not its content â€” selects the build mode, so an explicit `[]` still
selects that style and disables all warmup builds.

When adding a setting: extend `devcontainers-config.json` (with a comment), map it in
`env-config.sh` **and** `EnvConfig.ps1`, then read it in both spawn scripts.

## Core design rules

- **Scripts are project-agnostic; config lives in `devcontainers-config.json`.** Never hardcode a
  project name, repo, port, or version into `spawn-workspace.sh` /
  `dispose-workspace.sh`. If a new value is project-specific, add a variable to
  `devcontainers-config.json` and read it in the script. One clone of these scripts serves
  every project unchanged.

- **The header comments are authoritative.** `spawn-workspace.sh` opens with a
  numbered FEATURE OVERVIEW (features 1â€“12) documenting every design decision
  (memory-mount layering, port-offset probing, DinD startup, npmrc resolution,
  why there's no aggregator pom, etc.). Read the relevant feature note before
  changing behavior, and update it when you change the behavior it describes.

- **Bash 3.2 compatibility.** macOS ships bash 3.2, which the spawn script must
  run under. No associative arrays: `repos`, `builds` and `mavenBuilds` arrive
  from `env-config.sh` as plain arrays of `"<key>:<value>"` strings, split on
  `:` at use sites. Keep that style for any new map-like config. Guard every
  array read with a length check before expanding (`(( ${#arr[@]} > 0 ))`) â€”
  bash 3.2 + `set -u` error on empty `"${arr[@]}"`. To detect whether a config
  var is defined at all, use `declare -p NAME >/dev/null 2>&1` (as the
  `builds`/`mavenBuilds` selection does).

- **`set -euo pipefail`** is active in both Bash scripts. Guard optional vars
  with `${VAR:-}` and unset-array reads accordingly.

- **PowerShell equivalents of those rules.** Both `.ps1` scripts run
  `Set-StrictMode -Version Latest` + `$ErrorActionPreference = 'Stop'` and
  install a top-level `trap` that prints a one-line message and exits 1 (the
  `set -e` analogue). Native commands never raise on a non-zero exit, so **all**
  git/docker calls must go through `Invoke-Git` / `Invoke-Docker` in
  `Common.ps1`: they capture stdout/stderr separately and keep a process writing
  to stderr from being turned into a terminating `NativeCommandError`.

- **Generated files must be UTF-8 without BOM and LF-terminated** â€” they are
  consumed by a Linux container. In PowerShell always write them through
  `Write-LfFile`, never `Set-Content`/`Out-File`.

## Windows port specifics

`spawn-workspace.ps1`'s header comment is the authoritative list; the two that
affect behaviour visible elsewhere:

- **Relative git worktree links.** Git for Windows writes `gitdir: C:/...` into
  `<worktree>/.git`, which Linux does not treat as absolute. The spawn script
  rewrites that file to a path relative to the worktree
  (`Convert-WorktreeLinkToRelative`) and the container mounts the story
  workspace at `/workspaces/<PROJECT_NAME>-<leaf>` and the source workspace at
  `/workspaces/<PROJECT_NAME>` â€” siblings, mirroring the host layout â€” so the
  same link resolves on both sides. The *reverse* link
  (`<src>/.git/worktrees/<id>/gitdir`) is deliberately left absolute: git only
  learned to read a relative path there in 2.48, and older versions mark the
  worktree "prunable" and drop its metadata on the next `git worktree prune`.
- **Per-story container workspace path** (a consequence of the above) makes the
  Claude project key story-specific (`-workspaces-<PROJECT_NAME>-<leaf>`). The
  shared-memory bind still points at the single host folder
  `~/.claude/projects/-workspaces-<PROJECT_NAME>/memory`, so memory stays shared
  with containers spawned from macOS/Linux.

## How generation works (templating)

Generated files are produced by heredocs inside `spawn-workspace.sh` (and by
single-quoted here-strings inside `spawn-workspace.ps1`), then patched by
`substitute_placeholders()` / `Update-Placeholders`:

- **Quoted heredoc** (`<<'JSON'`, `<<'DOCKERFILE'`) â†’ written literally, then
  `substitute_placeholders` replaces `__PLACEHOLDER__` tokens via `sed`.
- **Unquoted heredoc** (`<<XML`, `<<SSHDCONF`) â†’ shell-expanded inline as it's
  written (variables interpolate directly).
- PowerShell mirrors this with `@'...'@` (literal) vs `@"..."@` (interpolating)
  here-strings; the token pass is a plain `String.Replace` over an ordered
  hashtable, so no escaping rules apply to the replacement values.

Placeholders substituted into copied files:
- `__PORT_<NNNN>__` â†’ the port-offsetted host port (e.g. `__PORT_8080__`).
- `__WORKSPACE_PATH__` â†’ the container workspace path
  (`/workspaces/<PROJECT_NAME>` on macOS/Linux,
  `/workspaces/<PROJECT_NAME>-<leaf>` on Windows).
- `__SPAWN_CMD__` / `__DISPOSE_CMD__` â†’ the platform-correct invocation shown in
  the generated workspace README.
- `__GLAB_BLOCK_START__` / `__GLAB_BLOCK_END__` â†’ conditional block markers
  (`__GH_BLOCK_*__` likewise; the PowerShell port adds `__SSHAGENT_BLOCK_*__`).

**Placeholder discipline for run configs:** use `__PORT_*__` for ports and
`__WORKSPACE_PATH__` for paths. **Do not use `$PROJECT_DIR$`** in fields passed
to external processes â€” under JetBrains Gateway ijent/Eel mode it expands to a
virtual path a real JVM/shell can't resolve.

## Optional GitLab integration

Active only when **both** `glabHostname` and `glabVersion` are non-empty in
`devcontainers-config.json` (sets `GLAB_ENABLED=1` at the top of the spawn script). The
`__GLAB_BLOCK_START__`/`__GLAB_BLOCK_END__` marker pairs in the heredoc
templates wrap glab-only content: when enabled only the marker lines are
stripped; when disabled the markers **and** everything between them are dropped.
When adding glab-dependent output, wrap it in a marker pair â€” never assume glab
is present.

## Key locations

Bash (`spawn-workspace.sh`) â€” the PowerShell port keeps the same order and
function names in `PascalCase-Verb` form, so the two read side by side:

- Arg parsing (runs FIRST, before the config is loaded), then config lookup
  (`--config` â†’ `./dev-containers/devcontainers-config.json` â†’ `./devcontainers-config.json`), then
  workspaces-root resolution via `resolve_workspaces_root` /
  `Resolve-WorkspacesRoot`: all near the top.
- `config_asset()` / `Get-ConfigAsset` â€” project asset lookup with
  `CONFIG_DIR` â†’ `SCRIPT_DIR` fallback.
- `is_port_in_use()` / `Test-PortInUse`, port-offset probing logic â€” checks live listeners, ports statically reserved by other workspaces' `devcontainer.json`, **and** ports bound by any docker container (`docker inspect` over `docker ps -a`, catching stopped/other-project containers). Offset step is configurable via `portOffsetStep` in `devcontainers-config.json` (default 10000, valid range 500..10000; the scripts abort outside it).
- `resolve_base()` / `create_worktree()` â€” `Resolve-BaseRef` / `New-Worktree` â€” per-repo worktree strategy (reuse / track / fork from base ref). The PowerShell version additionally calls `Convert-WorktreeLinkToRelative`.
- Generated artifacts, in order: `.claude/settings.local.json`, `.idea/*` (workspace/misc/compiler xml), `.devcontainer/Dockerfile`, `devcontainer.json`, `post-create.sh`, `post-start.sh`, run-config XMLs, sshd config.
- `substitute_placeholders()` / `Update-Placeholders`, `detect_java_home()` (inside the generated `post-create.sh`).

## Gotchas

- **Dispose target resolution.** `<target>` may be a branch, a branch leaf, a
  workspace directory name, a container name or a container ID. The
  `<PROJECT_NAME>-` / `<PROJECT_SHORT>-` prefixes must only be stripped when the
  result names an existing workspace â€” branch leaves legitimately start with the
  project's issue key (project `FLOW`, branch `feature/FLOW-4711`, workspace
  `FLOW-FLOW-4711`). Both scripts therefore build the candidate leaves and pick the
  first whose directory exists. Don't "simplify" that back to unconditional
  stripping.
- **Two READMEs.** `README.md` documents this repo and is hand-maintained.
  `README.md.tpl` is the template for the welcome README placed at each spawned
  workspace root â€” edit the `.tpl` for workspace-facing docs, not `README.md`.
- **`devcontainers-config.json` in this repo is the reference copy**, not the config any real
  run uses (a project supplies its own). Keep it complete and commented; it
  doubles as the settings documentation.
- **Stale `bin/â€¦` self-references.** Some comments/messages inside the scripts
  refer to an old `bin/â€¦` path. Informational only; invocation works from any
  path. Don't "fix" them into breakage.
- **DinD startup.** JetBrains Gateway overrides the container entrypoint, so
  `dockerd` is (re)started idempotently by the generated `post-start.sh`, not by
  the DinD feature's own entrypoint.
- **No aggregator `pom.xml`** is written at the workspace root (it would be
  falsely picked up as a Maven parent). Each subproject pom is registered
  individually in `.idea/misc.xml`; `post-create.sh` builds them in the
  dependency order given by the build list (`builds` / `mavenBuilds`).
- **Build-list config: `builds` vs `mavenBuilds`.** Whichever key is *present*
  in `devcontainers-config.json` wins (`mavenBuilds` > `builds`); `env-config.sh` declares only
  that one so the Bash `declare -p` probe picks the intended mode, and
  `EnvConfig.ps1` sets `BuildMode` accordingly. Both normalise into
  `BUILD_ENTRIES` / `$BuildEntries` + a mode flag that the generation loop reads:
  - raw mode (`builds`): the value is ALWAYS a raw bash command run
    verbatim as `cd <repo> && <command>` â€” no `mvn`/`MVN_FLAGS` injection, no `$`.
  - maven mode (`mavenBuilds`): the value is an `mvn`
    goal run as `cd <repo> && mvn ${MVN_FLAGS} <goal>`; a `$`-prefixed goal is
    instead a raw command (remainder after `$`, whitespace trimmed).
  Repos with no root `pom.xml` contribute nothing to `MAVEN_POMS_LIST` /
  IntelliJ's import list regardless of mode.
- **node_modules on named volumes.** Each npm module's `node_modules` is
  mounted as a Docker named volume (`NPM_NM_VOLUME_MOUNTS` / `$NpmVolumeMounts`)
  to bypass the slow hostâ†”VM bind-mount bridge.
  Fresh named volumes are `root:root`, so `post-create.sh` must `chown` each
  mount-point to `vscode` before any npm/Maven step â€” otherwise npm dies with
  `EACCES â€¦ mkdir node_modules/@types`. Keep that chown in sync with the
  module-discovery `find` if you touch either.
- **Mono-repo mode:** `"repos": []` switches spawn to single-worktree mode; if no
  build list is configured too and a root `pom.xml` exists it auto-populates a
  single `install` Maven build in maven mode.
- **Host-mount repos (empty base ref).** A `repos` entry with an empty `baseRef`
  is not a git repo: the worktree loop skips worktree creation, collects it into
  `HOST_MOUNT_REPOS` / `$HostMountRepos`, and emits a bind mount
  (`HOST_MOUNT_BINDS` / `$HostMountBinds`, spliced into `devcontainer.json` the
  same way as the node_modules volumes) from
  `<SOURCE_WS>/<repo>` to its workspace path. An empty placeholder dir is
  created in the story workspace as the mountpoint; it stays empty on the host,
  so the dispose scripts' recursive delete never touches the source. Dispose
  needs no special case â€” its worktree/branch loops are already `.git`-guarded
  and skip non-git dirs. Guarded by the mono-repo flag so mono-repo's synthetic
  empty-base-ref entry still builds a worktree.

## Running / testing changes

There is no dry-run. All four scripts print the resolved target directory and
prompt for confirmation before doing anything (Enter to accept, `n` to abort);
pass `--yes`/`-y` to skip in scripted runs. Prefer testing spawn against a
throwaway branch, then dispose it (add `--delete-branch` to also remove the
local branch).

- Bash: `bash -n spawn-workspace.sh` and `shellcheck` catch syntax/lint issues
  before a live run.
- PowerShell: parse-check without executing via
  `[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e)`.
- A throwaway sandbox is the fastest full test, and it should mimic the real
  split: put the scripts in `<tmp>/tools` (the "clone on PATH", with no
  `devcontainers-config.json`), the project in `<tmp>/work/<PROJECT>/<repo>` plus
  `<tmp>/work/<PROJECT>/dev-containers/devcontainers-config.json`, then run spawn/dispose both
  ways â€” from the project directory (default lookup) and from an unrelated cwd
  with `--config`.
- To verify the container side of the worktree links without building the real
  image, mount both workspaces into any git image and run `git status`:
  `docker run --rm -v <tmp>/<PROJECT>:/workspaces/<PROJECT> -v <tmp>/<PROJECT>-<leaf>:/workspaces/<PROJECT>-<leaf> -w /workspaces/<PROJECT>-<leaf>/<repo> alpine/git status`
- The Bash scripts can be exercised on Windows inside a container: any image
  with `bash`, `git` and `jq` will do (mount the scripts read-only). That also
  covers the symlink-on-PATH path (`ln -s â€¦ /usr/local/bin`), which cannot be
  tested from PowerShell.
