# Known issue: Container startet nicht — fehlender Memory-Bind-Mount

## Symptom

- Ein zuvor funktionierender Story-Container **startet beim Reconnect nicht mehr**
  (`docker start` bzw. Gateway-Reconnect schlägt fehl).
- Weil der Container nicht hochkommt, **operiert das IntelliJ-/Gateway-Fenster am
  Host** statt im Container — sichtbar daran, dass im Terminal die **zsh**
  (macOS-Default) erscheint statt der im Container erwarteten bash.
- Der Fehler tritt **wiederholt** auf (z. B. nach IDE-Reconnect, Docker-Desktop-
  Neustart oder Mac-Reboot), nicht bei jedem Spawn.

Konkreter Docker-Fehler beim Start:

```
Error response from daemon: invalid mount config for type "bind":
bind source path does not exist:
/host_mnt/Users/<user>/.claude/projects/-workspaces-<PROJECT_NAME>/memory
failed to start containers: <PROJECT_SHORT>-<leaf>
```

## Ursache (verifiziert)

Der Container hat einen Bind-Mount des **geteilten Claude-Memory-Ordners**
(devcontainer.json):

```
source=${localEnv:HOME}/.claude/projects/-workspaces-<PROJECT_NAME>/memory
target=/home/vscode/.claude/projects/-workspaces-<PROJECT_NAME>/memory
type=bind
```

Docker verweigert den Start, wenn die **Bind-Quelle auf dem Host nicht
existiert**. Entscheidend:

1. Angelegt wird der Ordner nur vom devcontainer-**`initializeCommand`**
   (`mkdir -p ~/.claude/projects/-workspaces-<PROJECT_NAME>/memory`). Der läuft
   bei **Create / „Rebuild and Reopen in Container"** — **nicht** bei einem
   bloßen **Restart** (`docker start` / Gateway-Reconnect).
2. `docker start` legt fehlende Bind-Quellen — anders als `docker run -v` —
   **nicht** automatisch an.

Ist der Ordner beim Neustart also gerade weg, scheitert der Start still.

**Nicht die Ursache:** `dispose-workspace.sh` — geprüft, es entfernt
`~/.claude/.../memory` nicht (nur den workspace-eigenen `.claude`-Copy in
`WS_DIR`). Der Ordner ist leer und wird von mehreren HAL-Story-Containern
geteilt (gleicher `MEMORY_KEY`). Offen: **welcher Host-Prozess die leeren
`~/.claude/projects/-*/memory`-Ordner zwischen Sessions entfernt** (Verdacht:
Host-seitiges Aufräumen leerer Projekt-Verzeichnisse).

## Sofort-Workaround

```sh
mkdir -p ~/.claude/projects/-workspaces-<PROJECT_NAME>/memory
docker start <PROJECT_SHORT>-<leaf>
```

oder in Gateway **„Rebuild and Reopen in Container"** (führt `initializeCommand`
aus und legt den Ordner neu an).

## Prompt für den dauerhaften Fix

> Im dev-containers-Tooling scheitert der reine Container-**Restart**, wenn der
> Host-Bind-Quellpfad `~/.claude/projects/-workspaces-<PROJECT_NAME>/memory`
> fehlt (Details siehe `KNOWN-ISSUE-container-start-memory-mount.md`). Der
> `initializeCommand` legt ihn nur bei Create/Rebuild an, `docker start` legt
> fehlende Bind-Quellen nicht an, und der leere Ordner verschwindet zwischen
> Sessions.
>
> Bitte in **beiden Ports** (`spawn-workspace.sh` **und** `spawn-workspace.ps1`)
> absichern, im Lockstep, und `CLAUDE.md`/`README` bei Bedarf ergänzen:
>
> 1. Beim Spawn eine **Marker-Datei** (z. B. `.keep`) in den geteilten
>    Memory-Ordner schreiben, damit er nicht als „leer" weggeräumt wird und über
>    Restarts hinweg bestehen bleibt. `spawn-workspace.sh` legt
>    `SHARED_MEMORY_DIR` bereits an — dort die Markerdatei ergänzen; im
>    PowerShell-Port an der entsprechenden Stelle spiegeln.
> 2. Prüfen, ob der Marker den Zweck des Ordners (geteiltes Claude-Memory)
>    stört — er darf die Memory-Nutzung nicht beeinflussen.
> 3. Optional: nachforschen, **welcher Host-Prozess** die leeren
>    `~/.claude/projects/-*/memory`-Ordner löscht, und die Quelle statt des
>    Symptoms fixen.
> 4. Testen: `bash -n`, PowerShell-`ParseFile`, und einen Spawn→stop→`docker
>    start`-Zyklus, der ohne vorheriges `mkdir` durchläuft.
