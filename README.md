# dev-containers

Helper scripts to spin up one **isolated IntelliJ DevContainer per story**
on top of a multi-repo workspace. Project-specific values live in
**`.env.sh`** next to the scripts. Fork this directory into another
project's repo, edit `.env.sh`, done.

Each story gets:

- a sibling workspace directory `~/Developer/workspace/<PROJECT_NAME>-<leaf>/`
- one git worktree per source repo
- a Dev Container (Java 21 + Maven + Node + Docker-in-Docker) with a
  preselected JetBrains backend, pre-wired run configs, port offset to
  run several stories in parallel, and a shared Claude-Code memory mount
- all Maven repos are built to ensure all dependencies are available
- Claude plugin Caveman installed (mode full)

Watch videos showing:
1. [Create the dev-container definition](readme/clone-and-spawn.mov) (00:47)
2. [Build the dev-container](readme/dev-container-build.mov) (05:06)
3. [Open the dev-container, run Claude, use a predefined run-configuration](readme/claude-and-business-cockpit.mov) (01:34)

## Files

| File / Directory          | Purpose                                                          |
|---------------------------|------------------------------------------------------------------|
| `spawn-workspace.sh`      | Create a new story workspace + DevContainer config from a branch |
| `dispose-workspace.sh`    | Tear down a story workspace, its worktrees, and its container    |
| `.env.sh`                 | Project-specific config (names, repos, ports, base image, …)     |
| `README.md.tpl`           | Template for the welcome README placed at each new workspace root |
| `initialize.sh`           | Optional hook run before Maven warmup builds (create if needed)  |
| `runConfigurations/*.xml` | IntelliJ run configs copied verbatim into each new workspace     |

Both scripts source `.env.sh` at startup. To adapt to a new project, fork
this directory into the project's source workspace and edit `.env.sh`.
See the file itself for the full list of variables and what they do.

### GitLab integration is optional

GitLab integration kicks in only when **both** `GLAB_HOSTNAME` **and**
`GLAB_VERSION` are non-empty in `.env.sh`. With either left empty the
spawn script:

- skips the `glab` install in the Dockerfile,
- skips the bind-mount of the host's glab-cli config,
- skips the git credential helper setup for the GitLab host,
- skips the glab-related section in the generated workspace README.

The mechanism is `__GLAB_BLOCK_START__` / `__GLAB_BLOCK_END__` marker
pairs in the heredoc templates inside `spawn-workspace.sh`. When enabled
just the marker lines are stripped (content stays); when disabled both
the markers and the content between them are dropped.

### IntelliJ run configurations

`runConfigurations/` holds the XMLs that end up in
`<new-workspace>/.idea/runConfigurations/`. The `RUN_CONFIGS` array in
`.env.sh` lists which files get copied (in order). The XMLs may use the
placeholders for host ports defined in `.env.sh`
(e.g. `__PORT_4200__`, `__PORT_8080__`) — `spawn-workspace.sh` substitutes them
to the actual port-offsetted host ports when copying.

To add/change run configs:
1. Drop a new XML into `runConfigurations/` (or edit an existing one).
2. Add its filename to `RUN_CONFIGS` in `.env.sh`.

*Hint:* To get an XML from an existing run configuration one can use the
`store as project file` feature:

![store as project file](readme/run-configuration-store-as-project-file.png)

**Avoid `$PROJECT_DIR$` in run config fields passed to external processes.**
In JetBrains Gateway's ijent/Eel mode (2025.x+), `$PROJECT_DIR$` expands to
a virtual Eel path (`/$devcontainer.ij/<hash>@/…`) which IntelliJ uses
internally but which real processes (JVM, shell) cannot resolve. Use
`__WORKSPACE_PATH__` instead — `spawn-workspace.sh` substitutes it to the
literal container path `/workspaces/<PROJECT_NAME>` when copying the XML.

### Optional initialization hook

If `dev-containers/initialize.sh` exists, `spawn-workspace.sh` copies it into
the new workspace's `.devcontainer/` and `post-create.sh` runs it **before**
the Maven warmup builds, with the workspace root as the working directory.

Use it for one-time setup that must precede Maven dependency resolution —
for example starting a Docker service that hosts an artifact proxy, seeding a
local registry, or pulling Docker images while the network is still available.

The file is opt-in: it is not created by default. Just add `initialize.sh`
next to `spawn-workspace.sh` to activate the hook for all future spawns.

### Workspace welcome README

The README placed at each new workspace root (the "First-time setup" /
"Running the stack locally" steps) lives in `README.md.tpl` next to this
script. Edit it freely when porting — no changes to `spawn-workspace.sh`
needed. It uses the same `__PLACEHOLDER__` / `__GLAB_BLOCK__` mechanism as
the other templates (see `spawn-workspace.sh:substitute_placeholders`).

## Prerequisites

### Host machine

- **macOS** (tested) or Linux. Docker Desktop on macOS provides the
  bind-mount / ssh-agent forwarding magic the scripts rely on.
- **Docker Desktop** (or `docker` + `docker compose` plugin) running.
- **IntelliJ IDEA Ultimate** (≥ 2025.3) with **JetBrains Gateway** enabled
  for Dev Container connections.
- **Bash 4+** (macOS' default `/bin/bash` 3.2 is fine for the spawn script;
  newer is not required).
- **Git** with worktree support (any modern version).
- **`~/.ssh`** populated and (optionally) an ssh-agent running on the host —
  the container forwards the agent socket so passphrase-protected keys work
  without prompting.
- **`glab` login** (only needed when GitLab integration is enabled in
  `.env.sh`): `glab auth login --hostname <GLAB_HOSTNAME>`. The config is
  bind-mounted into the container so the login flows in both directions.

### Workspace layout the scripts assume

```
<workspaces-root>/
├── <PROJECT_NAME>/                         ← source workspace (READ by spawn)
│   ├── dev-containers/                     ← this directory (lives in the source workspace)
│   ├── project-a/                    .git  ← each is a normal git repo
│   ├── project-b/                    .git
└── <PROJECT_NAME>-<branch-leaf>            ← created by spawn-workspace.sh
    ├── project-a/                    .git  (worktree of source)
    ├── …
    └── .devcontainer/                      DevContainer build + config
```

If any source repo is missing, the corresponding worktree is silently
skipped — the workspace still spawns with the rest.

### Resolving `<workspaces-root>`

Both scripts pick the workspaces root in this priority order:

1. **`--workspaces-root <path>`** CLI flag — highest priority, overrides everything.
2. **`$<PROJECT_SHORT>_WORKSPACES_ROOT`** environment variable — recommended for
   daily use (export once in your shell profile).
3. **Auto-detect** — the parent of the directory holding this script. Since
   `dev-containers/` lives inside the source workspace, two directory levels
   up gives the workspaces root.

Each invocation prints the resolved target directory and asks for
confirmation before doing anything. Press Enter to accept, type `n` to
abort. Pass `--yes` (or `-y`) to skip the prompt in scripted runs.

## Usage

### Create a workspace

```sh
dev-containers/spawn-workspace.sh [--workspaces-root <path>] [--yes] <branch-name>
```

Base refs for new branches are not on the CLI — each repo brings its own
in the `REPOS` map (`<repo>:<base-ref>`) in `.env.sh`.

Examples:

```sh
# Branch already exists locally or on origin -> reuses / tracks it
dev-containers/spawn-workspace.sh feature/PRJ-4711_example-story

# Brand-new branch: each repo forks from its own configured base ref
dev-containers/spawn-workspace.sh feature/PRJ-4711_new-story

# Point at a non-default workspaces directory (one-shot override)
dev-containers/spawn-workspace.sh --workspaces-root /opt/dev feature/PRJ-4711_new-story

# Same, but via env var (set it once in your shell profile)
export PRJ_WORKSPACES_ROOT=/opt/dev # PRJ is <PROJECT_SHORT>
dev-containers/spawn-workspace.sh feature/PRJ-4711_new-story

# Skip the confirmation prompt (CI / batch use)
dev-containers/spawn-workspace.sh --yes feature/PRJ-4711_new-story
```

Open the new workspace in IntelliJ via **JetBrains Gateway → Dev Containers →
From local project** and point it at the workspace's `.devcontainer/`
directory. Step-by-step first-time setup is in the generated workspace's
own `README.md`.

What it does:

1. Resolves the workspaces root (CLI flag → env var → auto-detect), then
   prints the target directory and prompts for confirmation. Aborts if you
   answer `n` or if the target already exists.
2. Computes the branch leaf (strips `feature/` etc.) → workspace name
   `<PROJECT_NAME>-<leaf>`.
3. Probes host ports and picks the lowest free
   multiple of 10000 as the **port offset** (so parallel stories never
   collide on host ports).
4. Creates one git worktree per source repo with the requested branch
   (reused, tracked, or — for brand-new branches — forked from the
   per-repo base ref defined in `REPOS`).
5. Writes a `.devcontainer/` (Dockerfile + devcontainer.json + post-create
   hooks) into the new workspace, plus `.idea/` (project name, JDK,
   run configs, README.md) and a per-story `.claude/` overlay. Read it
   to learn about host mounts and other details.
6. Sets `core.fileMode=false`, `core.autocrlf=input`, `core.checkStat=minimal`
   and `core.trustctime=false` in each source repo so the bind-mounted
   worktree doesn't trigger stale-stat rebase failures inside the container.

*Hint:* Read the head of the script for a detailed list of features and 
their documentation.

### Dispose a workspace

```sh
dev-containers/dispose-workspace.sh [--workspaces-root <path>] [--force] [--delete-branch] [--keep-container] [--keep-image] [--yes] <target>
```

Examples:

```sh
# Default: refuse if any worktree is dirty, keep branch, remove container + volumes + image
dev-containers/dispose-workspace.sh feature/PRJ-4711_example-story

# Also delete the local branch from each source repo
dev-containers/dispose-workspace.sh --delete-branch feature/PRJ-4711_example-story

# Force-remove despite uncommitted changes (you lose them)
dev-containers/dispose-workspace.sh --force feature/PRJ-4711_example-story

# Leave the Docker container alone (IntelliJ still has it open)
dev-containers/dispose-workspace.sh --keep-container feature/FLOW-4711_example-story

# Remove container and volumes but keep the image layer cache for a faster next rebuild
dev-containers/dispose-workspace.sh --keep-image feature/FLOW-4711_example-story

# Use the Docker container name or ID instead of the branch
dev-containers/dispose-workspace.sh PRJ-FLOW-4711_example-story
dev-containers/dispose-workspace.sh a3f2b1c4d5e6

# Non-default workspaces root via flag or env var
dev-containers/dispose-workspace.sh --workspaces-root /opt/dev feature/FLOW-4711_example-story
PRJ_WORKSPACES_ROOT=/opt/dev dev-containers/dispose-workspace.sh feature/FLOW-4711_example-story  # PRJ = <PROJECT_SHORT>

# Skip the confirmation prompt
dev-containers/dispose-workspace.sh --yes feature/FLOW-4711_example-story
```

Accepts any of: full branch name (`feature/PRJ-…`), branch leaf (`PRJ-…`),
workspace directory name (`<PROJECT_NAME>-PRJ-…`), Docker container name
(`<PROJECT_SHORT>-PRJ-…`), or Docker container ID (hex, ≥12 chars).

What it does:

1. Checks every worktree for uncommitted changes. Aborts unless `--force`.
2. Removes each git worktree from its source repo's metadata.
3. Optionally deletes the local branch from each source repo.
4. Removes the Docker container `<PROJECT_SHORT>-<leaf>`, all its named
   volumes, and the devcontainer image (unless `--keep-container`; use
   `--keep-image` to skip only the image removal).
5. Removes the workspace directory.

*Hint:* Read the head of the script for a detailed list of features and
their documentation.

## Troubleshooting

| Symptom                                                                                                                                           | Likely cause                                                                                                                                                                                                                                                                                                                     | Fix                                                                                                                                                                                                                                                                                                                                                  |
|---------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Spawn aborts: "Workspace already exists"                                                                                                          | Previous spawn for the same branch                                                                                                                                                                                                                                                                                               | Dispose first, or pick a different branch                                                                                                                                                                                                                                                                                                            |
| Container starts but Maven fails with `401 Unauthorized`                                                                                          | `~/.m2/setting.xml` does not include password for host or uses a variable not passed                                                                                                                                                                                                                                             | Export the tokens variable (or `direnv allow`), then re-spawn                                                                                                                                                                                                                                                                                        |
| `git push` keeps prompting for username/password                                                                                                  | `glab` not logged in on the host                                                                                                                                                                                                                                                                                                 | `glab auth login --hostname XXXXXX` (host or container)                                                                                                                                                                                                                                                                                              |
| `git` keeps prompting for password *despite* `glab` being logged in and the helper printed via `git config` looking correct                       | Three glab × git × GitLab quirks stack: (1) container's `git` < 2.46 ignores the `authtype` capability glab advertises; (2) glab rejects `get` requests where `username=<x>` doesn't match its (empty) OAuth-login username; (3) GitLab expects `oauth2` as the HTTP Basic username for OAuth tokens, not the URL-embedded user. | New spawns: Dockerfile installs git ≥ 2.46 (Debian backports / Ubuntu PPA), and `post-create.sh` installs a small `glab-creds.sh` wrapper that strips the input `username=`, drops the misleading `capability` line, and rewrites the output username to `oauth2`. Old containers: rebuild via "Rebuild Container" in Gateway, or run a fresh spawn. |
| `git rebase -i` aborts with "Your local changes would be …"                                                                                       | bind-mount stat drift in an existing source repo                                                                                                                                                                                                                                                                                 | `git config core.checkStat minimal && git config core.trustctime false` in the offending repo (new spawns get this automatically)                                                                                                                                                                                                                    |
| Project dropdown shows `<PROJECT_NAME> (Devcontainer: <id>)` after IDE restart                                                                    | JetBrains Gateway 2026.1 ignores `frameTitle` pre-connect                                                                                                                                                                                                                                                                        | Open the container once; the proper name is restored until the next restart                                                                                                                                                                                                                                                                          |
| "Datei wurde extern geändert"-Dialog right after IDE save                                                                                         | bind-mount stat drift triggered by safe-write rename pattern                                                                                                                                                                                                                                                                     | **HOST IntelliJ (ijent Dev Container mode):** Settings → Appearance & Behavior → System Settings → uncheck "Use 'safe write'", restart the IDE. Global, one-time, applies to every project. The `post-start.sh` block is a no-op in ijent mode and a fallback for classic-Gateway-backend mode.                                                      |
| `IllegalStateException` on EDT on first save (MavenUtil/EelProvider stack), then "Spotless applied" notification but file unchanged               | Spotless Applier (Lipiridi 1.2.3) is not Eel-aware — its on-save service init calls Maven resolution on EDT, and its `-DspotlessIdeHook` argument leaks the `//$devcontainer.ij/...` virtual scheme into the in-container `mvn` process                                                                                          | Disable "Actions on Save → Run Spotless" for the remote project (don't create `.idea/spotless-applier.xml`). Use IntelliJ's built-in Reformat / Optimize-imports on save and `mvn spotless:apply` before commit. Open question upstream; works fine on host because no Eel layer.                                                                    |
| IntelliJ Database "Test Connection" fails with `RemoteJdbcServer … No such file or directory (os error 2)`, host JBR path + `/workspaces/...` cwd | ijent Dev Container mode: the Database plugin execs the **host** JBR path inside the container to introspect, but a macOS binary can't run on Linux → ENOENT. The DB is a docker-in-docker Testcontainer only reachable from inside the container.                                                                               | Don't introspect in-container. Create an **SSH-tunnel data source** (tunnel → `localhost:<2222+offset>` user `vscode`; DB host `127.0.0.1:3307`). ; add `2222` to `HOST_PORTS` in `.env.sh` to publish the tunnel port. See the generated workspace README "Database access".                                                                        |

## Notes

- The scripts contain long header comments documenting every design decision
  (`spawn-workspace.sh` has the most). Read them when something surprises you.
- Self-references inside the scripts still use the old `bin/…` path. They
  are informational only — invocation works fine from any path.
