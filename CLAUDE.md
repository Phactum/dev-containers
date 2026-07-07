# CLAUDE.md

Guidance for working on this repository. Read `README.md` first for user-facing
usage; this file captures the internal structure and conventions you need before
editing anything.

## What this repo is

Bash tooling that spins up **one isolated IntelliJ DevContainer per story** on
top of a multi-repo workspace. `spawn-workspace.sh` creates a sibling workspace
directory (`<workspaces-root>/<PROJECT_NAME>-<branch-leaf>/`) containing one git
worktree per source repo plus a fully generated `.devcontainer/`, `.idea/`,
`.claude/` and a welcome `README.md`. `dispose-workspace.sh` tears it all down.

This directory (`dev-containers/`) lives **inside** the source workspace it
operates on. To retarget another project you fork this directory into that
project's repo and edit `.env.sh` — nothing else.

## Files

| File / Dir                | Role |
|---------------------------|------|
| `spawn-workspace.sh`      | Creates a story workspace + DevContainer. ~1900 lines, all generation logic. |
| `dispose-workspace.sh`    | Tears down a workspace: worktrees, container, volumes, image, dir. |
| `.env.sh`                 | **The only place project-specific values belong.** Sourced by both scripts. |
| `README.md.tpl`           | Template for the welcome README written to each new workspace root (NOT this repo's README). |
| `initialize.sh`           | Optional opt-in hook copied into the workspace; runs before the Maven warmup build. |
| `runConfigurations/*.xml` | IntelliJ run configs copied verbatim into new workspaces (listed in `RUN_CONFIGS`). |
| `readme/`                 | Screenshots + demo videos referenced by `README.md`. |
| `README.md` / `README.md.tpl` are distinct — see the "Two READMEs" gotcha below. |

## Core design rules

- **Scripts are project-agnostic; config lives in `.env.sh`.** Never hardcode a
  project name, repo, port, or version into `spawn-workspace.sh` /
  `dispose-workspace.sh`. If a new value is project-specific, add a variable to
  `.env.sh` and read it in the script. The scripts must run unchanged when
  forked into another project.

- **The header comments are authoritative.** `spawn-workspace.sh` opens with a
  numbered FEATURE OVERVIEW (features 1–12) documenting every design decision
  (memory-mount layering, port-offset probing, DinD startup, npmrc resolution,
  why there's no aggregator pom, etc.). Read the relevant feature note before
  changing behavior, and update it when you change the behavior it describes.

- **Bash 3.2 compatibility.** macOS ships bash 3.2, which the spawn script must
  run under. No associative arrays: `REPOS`, `BUILDS` and `MAVEN_BUILDS` are
  plain arrays of `"<key>:<value>"` strings, split on `:` at use sites. Keep that
  style for any new map-like config. Guard every array read with a length check
  before expanding (`(( ${#arr[@]} > 0 ))`) — bash 3.2 + `set -u` error on empty
  `"${arr[@]}"`. To detect whether a config var is defined at all, use
  `declare -p NAME >/dev/null 2>&1` (as the `BUILDS`/`MAVEN_BUILDS` selection does).

- **`set -euo pipefail`** is active in both scripts. Guard optional vars with
  `${VAR:-}` and unset-array reads accordingly.

## How generation works (templating)

Generated files are produced by heredocs inside `spawn-workspace.sh`, then
patched by `substitute_placeholders()` (at `spawn-workspace.sh:1315`):

- **Quoted heredoc** (`<<'JSON'`, `<<'DOCKERFILE'`) → written literally, then
  `substitute_placeholders` replaces `__PLACEHOLDER__` tokens via `sed`.
- **Unquoted heredoc** (`<<XML`, `<<SSHDCONF`) → shell-expanded inline as it's
  written (variables interpolate directly).

Placeholders substituted into copied files:
- `__PORT_<NNNN>__` → the port-offsetted host port (e.g. `__PORT_8080__`).
- `__WORKSPACE_PATH__` → `/workspaces/<PROJECT_NAME>` (the container path).
- `__GLAB_BLOCK_START__` / `__GLAB_BLOCK_END__` → conditional block markers.

**Placeholder discipline for run configs:** use `__PORT_*__` for ports and
`__WORKSPACE_PATH__` for paths. **Do not use `$PROJECT_DIR$`** in fields passed
to external processes — under JetBrains Gateway ijent/Eel mode it expands to a
virtual path a real JVM/shell can't resolve.

## Optional GitLab integration

Active only when **both** `GLAB_HOSTNAME` and `GLAB_VERSION` are non-empty in
`.env.sh` (sets `GLAB_ENABLED=1` at the top of the spawn script). The
`__GLAB_BLOCK_START__`/`__GLAB_BLOCK_END__` marker pairs in the heredoc
templates wrap glab-only content: when enabled only the marker lines are
stripped; when disabled the markers **and** everything between them are dropped.
When adding glab-dependent output, wrap it in a marker pair — never assume glab
is present.

## Key locations in spawn-workspace.sh

- Arg parsing / workspaces-root resolution (CLI flag → `<PROJECT_SHORT>_WORKSPACES_ROOT` env var → auto-detect two dirs up): near the top.
- `is_port_in_use()` (line ~375), port-offset probing logic — checks live listeners **and** ports statically reserved by other workspaces' `devcontainer.json`.
- `resolve_base()` / `create_worktree()` (~488/499) — per-repo worktree strategy (reuse / track / fork from base ref).
- Generated artifacts, in order: `.claude/settings.local.json`, `.idea/*` (workspace/misc/compiler xml), `.devcontainer/Dockerfile`, `devcontainer.json`, `post-create.sh`, `post-start.sh`, run-config XMLs, sshd config.
- `substitute_placeholders()` (~1315), `detect_java_home()` (~1396).

## Gotchas

- **Two READMEs.** `README.md` documents this repo and is hand-maintained.
  `README.md.tpl` is the template for the welcome README placed at each spawned
  workspace root — edit the `.tpl` for workspace-facing docs, not `README.md`.
- **Stale `bin/…` self-references.** Some comments/messages inside the scripts
  refer to an old `bin/…` path. Informational only; invocation works from any
  path. Don't "fix" them into breakage.
- **DinD startup.** JetBrains Gateway overrides the container entrypoint, so
  `dockerd` is (re)started idempotently by the generated `post-start.sh`, not by
  the DinD feature's own entrypoint.
- **No aggregator `pom.xml`** is written at the workspace root (it would be
  falsely picked up as a Maven parent). Each subproject pom is registered
  individually in `.idea/misc.xml`; `post-create.sh` builds them in the
  dependency order given by the build list (`BUILDS` / `MAVEN_BUILDS`).
- **Build-list config: `BUILDS` vs `MAVEN_BUILDS`.** Both are `"<repo>:<value>"`
  arrays; whichever is *defined* first wins (`MAVEN_BUILDS` > legacy alias
  `MAVEN_REPOS` > `BUILDS`). Near `spawn-workspace.sh:~305` they are normalised
  into `BUILD_ENTRIES` + a `BUILD_MODE` flag that the generation loop
  (`~800`) reads:
  - `BUILD_MODE=raw` (`BUILDS`): `<value>` is ALWAYS a raw bash command run
    verbatim as `cd <repo> && <value>` — no `mvn`/`MVN_FLAGS` injection, no `$`.
  - `BUILD_MODE=maven` (`MAVEN_BUILDS`/`MAVEN_REPOS`): `<value>` is an `mvn`
    goal run as `cd <repo> && mvn ${MVN_FLAGS} <value>`; a `$`-prefixed value is
    instead a raw command (remainder after `$`, whitespace trimmed).
  Repos with no root `pom.xml` contribute nothing to `MAVEN_POMS_LIST` /
  IntelliJ's import list regardless of mode.
- **node_modules on named volumes.** Each npm module's `node_modules` is
  mounted as a Docker named volume (`NPM_NM_VOLUME_MOUNTS`) for speed on macOS.
  Fresh named volumes are `root:root`, so `post-create.sh` must `chown` each
  mount-point to `vscode` before any npm/Maven step — otherwise npm dies with
  `EACCES … mkdir node_modules/@types`. Keep that chown in sync with the
  module-discovery `find` if you touch either.
- **Mono-repo mode:** `REPOS=()` switches spawn to single-worktree mode; if no
  build list is configured too and a root `pom.xml` exists it auto-populates a
  single `<PROJECT_NAME>:install` Maven build (`BUILD_MODE=maven`).
- **Host-mount repos (empty base-ref).** A `REPOS` entry with an empty value
  (e.g. `"hal-npm-packages:"`) is not a git repo: the worktree loop
  (`spawn-workspace.sh:~660`) skips `create_worktree`, collects it into
  `HOST_MOUNT_REPOS`, and emits a bind mount (`HOST_MOUNT_BINDS`, injected into
  `devcontainer.json` via the same awk pattern as `NPM_NM_VOLUME_MOUNTS`) from
  `${SOURCE_WS}/<repo>` to its workspace path. An empty placeholder dir is
  created in `WS_DIR` as the mountpoint; it stays empty on the host, so dispose's
  `rm -rf` never touches the source. `dispose-workspace.sh` needs no special
  case — its worktree/branch loops are already `.git`-guarded and skip non-git
  dirs. Guarded by `MONO_REPO == 0` so mono-repo's synthetic empty-value entry
  still builds a worktree.

## Running / testing changes

There is no dry-run. Both scripts print the resolved target directory and prompt
for confirmation before doing anything (Enter to accept, `n` to abort); pass
`--yes`/`-y` to skip in scripted runs. Prefer testing spawn against a throwaway
branch, then `dispose-workspace.sh <branch>` (add `--delete-branch` to also
remove the local branch). `bash -n spawn-workspace.sh` and `shellcheck` catch
syntax/lint issues before a live run.
