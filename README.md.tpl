# __PROJECT_NAME__ — Story Workspace `__LEAF__`

DevContainer workspace with worktrees of all __PROJECT_NAME__ repositories.

## First-time setup (once after the container starts)

1. **Pick a project JDK**
   File → Project Structure → SDK → choose any `21` entry
   (they all point at the same JDK; the auto-pin sometimes misses due to a
   JetBrains remote-dev quirk with symlinked paths).
2. **Maven full reload**
   Maven tool window → **Reload All Maven Projects**.
   Use the entry with the **red** icon (force reload), not the regular one
   above it -- the red variant re-resolves everything from scratch.
3. **Verify the IntelliJ Docker integration** so the gutter Play buttons appear
   in `vanillabp-business-cockpit/development/docker-compose.yaml`.
   IntelliJ 2026.1 auto-detects the
   in-container Docker daemon and registers a "Docker in Docker" connection;
   the other endpoint options (Unix Socket, TCP, SSH) are intentionally
   greyed out in this mode. To confirm it works:
   - `Settings → Build, Execution, Deployment → Docker` → click
     **Docker in Docker**. (The connection-status panel may stay blank --
     that's a 2026.1 cosmetic bug, the connection is fine if the next step
     works.)
   - Open `View → Tool Windows → Services` (`⌘8`) → you should see a
     **Docker** node with the currently running containers under it. If
     yes, the daemon link is alive.

   **If gutter Play buttons in `compose.yaml` are still missing:**
   The Spawn auto-installs the full marketplace **Docker** plus **YAML**
   plugins via `customizations.jetbrains.plugins` -- normally that's
   enough to surface Compose file-type registration + per-service gutter
   actions. If a Marketplace download failed on first backend connect,
   the symptoms below appear; the fixes restore the missing pieces.
   - `Settings → Editor → File Types` → check whether **Docker Compose**
     appears in the "Recognized File Types" list with patterns
     `compose.yml`, `compose.yaml`, `docker-compose.yml`,
     `docker-compose.yaml`. If the entry is missing entirely, the Compose
     subfeature of the Docker plugin isn't active in this backend.
   - Workaround that always works: `Run → Edit Configurations… → + →
     Docker → Docker Compose`, pick `environments/local/compose.yaml`
     as the source file, save. The run-config then appears in the run
     dropdown and via right-click on `compose.yaml`.
   - Last resort: `File → Repair IDE → Rescan project indexes`, or
     `File → Invalidate Caches… → Invalidate and Restart`. This re-runs
     plugin registration on next startup.
4. **Activate Claude**
   Open Claude-Code terminal. Enter command `/login` which shows up an URL. Copy
   that URL into the browser in which you are already logged in and confirm
   the usage. As a result a code is provided which can be copied into the terminal.
   After entering the code, the login must be completed with the "enter" key.
<!-- __GLAB_BLOCK_START__ -->
5. **glab login is shared with the host**
   `spawn-workspace.sh` resolves the host's glab config directory
   (macOS: `~/Library/Application Support/glab-cli`, Linux:
   `~/.config/glab-cli`) and bind-mounts it onto the container's
   `~/.config/glab-cli`. A login on the host is immediately usable inside
   the container and vice versa. If you've never logged in anywhere, run
   once (host or container):
   `glab auth login --hostname __GLAB_HOSTNAME__`.
<!-- __GLAB_BLOCK_END__ -->

## Optional: format-on-save

The spawn deliberately does **not** preconfigure any "Actions on Save" so
that your formatting workflow stays whatever you prefer. The team uses
**Spotless** as the source of truth (run `mvn spotless:apply` before
commit; CI rejects unformatted code). On top of that you can pick one of:

- **IntelliJ built-in reformat + optimize-imports on save** (closest to host
  workflow without a Maven invocation). Open `Settings → Tools → Actions on
  Save`, tick `Reformat code` and `Optimize imports on save`. For
  byte-identical output to Spotless install the **Adapter for Eclipse Code
  Formatter** plugin and point it at `vanillabp-spi-for-java/formatting_conventions.xml`
  in its settings panel.
- **Spotless Applier plugin** (the host workflow): currently broken in the
  ijent-based Dev Container mode used by Gateway 2025.x / 2026.x -- the plugin
  passes Eel virtual paths into the in-container `mvn` and crashes on EDT
  during its on-save listener init. Use the IntelliJ-built-in route above
  for now; an upstream fix is in flight.
- **Manual only**: keep saves untouched, run `mvn spotless:apply` before
  commit. CI applies the same check, so as long as it passes there your
  workflow is fine.

If you don't care, do nothing -- the workspace works without any of these.

## Running the stack locally

Order matters; later steps depend on earlier services being up:

2. Start **MongoDB**:
   ```shell
   cd vanillabp-business-cockpit/development
   docker compose up -d
   ```
3. Run **BusinessCockpitSimulator**.
4. Run **BusinessCockpit**.

## Graphical browsing -- IntelliJ Database tool (SSH tunnel)

IntelliJ's Database tool can't introspect the in-container DB directly in
ijent Dev Container mode (it execs the host JBR path inside the container ->
ENOENT). Route it through the sshd this container runs instead:

1. Make sure `2222` is in `HOST_PORTS` in `dev-containers/.env.sh` and
   you spawned the workspace after adding it (so `2222+offset` is published
   to the host). This workspace's host SSH port is **2222+__PORT_OFFSET__ =
   __SSH_HOST_PORT__**.
3. **SSH/SSL** tab → `Use SSH tunnel`:
   - Host `localhost`, Port `__SSH_HOST_PORT__`, User `vscode`
   - Auth type `Key pair` → your host private key (e.g.
     `~/.ssh/id_ed25519`), or `OpenSSH config and authentication agent`.
4. **General** tab → Host `127.0.0.1`, Port `27017`, User/Password
   `business-cockpit`, Database `business-cockpit`. The host/port here are
   resolved **from the container's side of the tunnel**, so `127.0.0.1`
   means the dev container.
5. `Test Connection` while a run with the DB is active.

Auth uses your existing host SSH keys (the container's `authorized_keys` is
rebuilt from `~/.ssh/*.pub` on every start), so no new credentials.

## Browser access

Port offset for this workspace: **+__PORT_OFFSET__**
(With `0` the host ports match the container ports.)

| Host | Container | Service |
|------|-----------|---------|
__PORT_TABLE_ROWS__

When parallel story containers run, `spawn-workspace.sh` automatically picks
the next free multiple of 10000 as the offset. The run configs for this
workspace are pre-wired with the offset URLs:
`vanillabp.cockpit.application-uri`, OAuth redirect URIs, and the issuer URI
are passed as JVM system properties, so OAuth callbacks between cockpit and
auth server (see the table above) line up.

## Useful container commands

| Command       | Purpose                                                         |
|---------------|-----------------------------------------------------------------|
| `branches`  | List the current branch of every worktree                       |
| `docker ps` | Running Testcontainers / compose stacks                         |
| `mvn …`     | Works in every repo directly (symlinked into /usr/local/bin)    |
| `claude`    | Claude Code with shared memory across all story containers      |
<!-- __GLAB_BLOCK_START__ -->
| `glab …`    | GitLab CLI for __GLAB_HOSTNAME__ (config shared with host)       |
<!-- __GLAB_BLOCK_END__ -->

## Workspace shortcuts

The workspace root `__WORKSPACE_PATH__` is exposed three ways so you
rarely need to type the absolute path:

| Shortcut                   | Example                                  | What happens                                                                              |
|----------------------------|------------------------------------------|-------------------------------------------------------------------------------------------|
| `$WS`                       | `cat $WS/README.md`                       | Plain env var. Works in scripts too.                                                      |
| `~/ws`                     | `vim ~/ws/__FIRST_REPO__/pom.xml`         | Symlink in your home dir, plays nice with Tab-completion.                                 |
| `CDPATH`                   | `cd application` from anywhere           | `cd <name>` first tries the current directory, then `__WORKSPACE_PATH__/<name>`.       |

Set up in `/etc/profile.d/zz-__PROJECT_SHORT__-env.sh` and `/etc/bash.bashrc` so every
shell (login, non-login, IDE terminal) picks them up automatically.

## Disposing the workspace

Run on the **host** (not in the container):

```sh
dev-containers/dispose-workspace.sh feature/__LEAF__
```

This removes the worktrees, the workspace directory, and the Docker container.
`--delete-branch` also deletes the local branch in the source repos.
`--force` skips the dirty-check (and discards any uncommitted work).
