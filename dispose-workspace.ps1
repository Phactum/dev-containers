<#
.SYNOPSIS
    dispose-workspace.ps1 - remove a story workspace and clean up its git
    worktrees. Windows/PowerShell port of dispose-workspace.sh.

.DESCRIPTION
    Functionally identical to dev-containers/dispose-workspace.sh. Both scripts
    read the same project configuration from devcontainers-config.json.

    By default this:
      - refuses to remove worktrees with uncommitted changes (use -Force/--force
        to override)
      - keeps the branch (use --delete-branch to remove the local branch from
        each source repo)
      - removes the Docker container '<projectShort>-<leaf>', all its named
        volumes, and the devcontainer image (use --keep-container to skip all
        Docker cleanup, or --keep-image to remove the container and volumes but
        keep the image layer cache)

    <target> accepts any of:
      feature/FLOW-4711_example-story   full branch name
      FLOW-4711_example-story           branch leaf
      <PROJECT_NAME>-FLOW-4711_foo      workspace directory name
      <PROJECT_SHORT>-FLOW-4711_foo     Docker container name
      a3f2b1c4d5e6                      Docker container ID (hex, >= 12 chars)

    When a container name or ID is given the script resolves the workspace from
    the container name (which embeds the branch leaf) without needing the branch.

.PARAMETER Arguments
    Positional/flag arguments, accepted in the same spelling as the Bash script:
        [-c|--config <path>] [--workspaces-root <path>] [--force] [--delete-branch]
        [--keep-container] [--keep-image] [-y|--yes] [-h|--help] <target>

.EXAMPLE
    # from the project directory (finds .\dev-containers\devcontainers-config.json)
    dispose-workspace.ps1 feature/FLOW-4711_example-story

.EXAMPLE
    dispose-workspace.ps1 --force --delete-branch feature/FLOW-4711_example

.EXAMPLE
    dispose-workspace.ps1 --config D:\work\myproject\dev-containers\devcontainers-config.json a3f2b1c4d5e6

.NOTES
    INSTALLATION
      Clone this directory ONCE and add it to your PATH; see the header of
      spawn-workspace.ps1 for the details.

    The devcontainers-config.json is located in this order:
      1. --config <path>   file, or a directory containing devcontainers-config.json
      2. .\dev-containers\devcontainers-config.json, relative to the CURRENT WORKING DIRECTORY
      3. .\devcontainers-config.json,                relative to the CURRENT WORKING DIRECTORY

    The <workspaces-root> directory is resolved in this order:
      1. --workspaces-root <path>              CLI flag (highest priority)
      2. $env:<PROJECTSHORT>_WORKSPACES_ROOT   environment variable
      3. "workspacesRoot" in devcontainers-config.json       (relative to the config's directory)
      4. auto-detect: walk up from the config's directory to the directory named
         <PROJECT_NAME> and take its parent; falling back to two levels up
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Arguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\EnvConfig.ps1"

# Abort with a readable one-line message instead of a PowerShell exception dump
# when a step fails (git returning non-zero, a missing file, ...). Mirrors the
# `set -e` behaviour of the Bash scripts.
trap {
    Write-Err $_.Exception.Message
    exit 1
}
$Usage = @'
usage: dispose-workspace.ps1 [--config <path>] [--workspaces-root <path>] [--force]
                             [--delete-branch] [--keep-container] [--keep-image] [--yes] <target>

  -c, --config <path>       devcontainers-config.json to use, or a directory containing it
                            (default: .\dev-containers\devcontainers-config.json, relative to
                            the current directory)
  --workspaces-root <path>  directory holding <PROJECT_NAME> and the story
                            workspaces (default: from "workspacesRoot" in devcontainers-config.json, else auto-detected)
  --force                   discard uncommitted changes in the worktrees
  --delete-branch           also delete the local branch in each source repo
  --keep-container          skip all Docker cleanup
  --keep-image              remove container + volumes but keep the image
  -y, --yes                 skip the confirmation prompt
  -h, --help                show this help

<target> may be a branch name, a branch leaf, a workspace directory name, a
Docker container name, or a Docker container ID.
'@

$Force = $false
$DeleteBranch = $false
$KeepContainer = $false
$KeepImage = $false
$WorkspacesRootCli = ''
$ConfigCli = ''
$AssumeYes = $false
$Target = ''

for ($i = 0; $i -lt $Arguments.Count; $i++) {
    $a = $Arguments[$i]
    switch -Regex ($a) {
        '^--force$'           { $Force = $true; continue }
        '^--delete-branch$'   { $DeleteBranch = $true; continue }
        '^--keep-container$'  { $KeepContainer = $true; continue }
        '^--keep-image$'      { $KeepImage = $true; continue }
        '^(-c|--config)$' {
            if ($i + 1 -ge $Arguments.Count) { Fail '--config needs an argument' 2 }
            $ConfigCli = $Arguments[$i + 1]
            $i++
            continue
        }
        '^--config='          { $ConfigCli = $a.Substring('--config='.Length); continue }
        '^--workspaces-root$' {
            if ($i + 1 -ge $Arguments.Count) { Fail '--workspaces-root needs an argument' 2 }
            $WorkspacesRootCli = $Arguments[$i + 1]
            $i++
            continue
        }
        '^--workspaces-root=' { $WorkspacesRootCli = $a.Substring('--workspaces-root='.Length); continue }
        '^(-y|--yes)$'        { $AssumeYes = $true; continue }
        '^(-h|--help|-\?)$'   { Write-Output $Usage; exit 0 }
        '^-'                  { Fail "unknown option: $a" 2 }
        default {
            if ($Target) { Fail "unexpected argument: $a" 2 }
            $Target = $a
        }
    }
}

if (-not $Target) {
    Write-Err $Usage
    exit 2
}

# ============================================================================
# Project configuration + paths
# ============================================================================

# --config wins; otherwise .\dev-containers\devcontainers-config.json or .\devcontainers-config.json,
# relative to the current directory.
$ConfigPath = Resolve-DevContainerConfigPath -ConfigPath $ConfigCli
$cfg = Get-DevContainerConfig -Path $ConfigPath
$ConfigDir = $cfg.Dir
$ProjectName = $cfg.ProjectName
$ProjectShort = $cfg.ProjectShort
$EnvVarWorkspacesRoot = ($ProjectShort -replace '[^A-Za-z0-9]', '_').ToUpperInvariant() + '_WORKSPACES_ROOT'

# Resolve the workspaces root. Priority (see Resolve-WorkspacesRoot in
# EnvConfig.ps1): --workspaces-root flag, env var, "workspacesRoot" in
# devcontainers-config.json, then auto-detect from the config location.
$WorkspacesRoot = Resolve-WorkspacesRoot -Config $cfg -Cli $WorkspacesRootCli -EnvVarName $EnvVarWorkspacesRoot
$SourceWs = Join-Path $WorkspacesRoot $ProjectName

$DockerAvailable = $null -ne (Get-Command docker -ErrorAction SilentlyContinue)

# If the target is a Docker container ID (hex string >= 12 chars), resolve it to
# the container name so the leaf extraction below works the same as for a name.
if ($Target -match '^[0-9a-f]{12,}$' -and $DockerAvailable) {
    $inspect = Invoke-Docker @('inspect', '--format', '{{.Name}}', $Target)
    $resolved = $inspect.StdOut.Trim().TrimStart('/')   # docker prepends a leading /
    if ($inspect.ExitCode -eq 0 -and $resolved) {
        Write-Output "resolved container ID '$Target' -> '$resolved'"
        $Target = $resolved
    }
}

# Accept "feature/FLOW-1234_foo", "FLOW-1234_foo", "<PROJECT_NAME>-FLOW-1234_foo",
# or "<PROJECT_SHORT>-FLOW-1234_foo" (Docker container name).
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
$RawLeaf = ($Target -split '/')[-1]
$LeafCandidates = @($RawLeaf)
if ($RawLeaf.StartsWith("$ProjectName-")) { $LeafCandidates += $RawLeaf.Substring("$ProjectName-".Length) }
if ($RawLeaf.StartsWith("$ProjectShort-")) { $LeafCandidates += $RawLeaf.Substring("$ProjectShort-".Length) }

$Leaf = $RawLeaf
foreach ($cand in $LeafCandidates) {
    if (Test-Path -LiteralPath (Join-Path $WorkspacesRoot "$ProjectName-$cand") -PathType Container) {
        $Leaf = $cand
        break
    }
}
$WsName = "$ProjectName-$Leaf"
$WsDir = Join-Path $WorkspacesRoot $WsName

if (-not (Test-Path -LiteralPath $WsDir -PathType Container)) {
    Write-Err "Workspace not found: $WsDir"
    if ($LeafCandidates.Count -gt 1) {
        Write-Err "(also tried: $(($LeafCandidates | Select-Object -Skip 1) -join ' '))"
    }
    Write-Err 'If your workspaces live elsewhere, pass --workspaces-root <path>'
    Fail "or set `$env:$EnvVarWorkspacesRoot."
}

# Refuse to dispose the source workspace by accident.
if ($WsDir.TrimEnd('\') -eq $SourceWs.TrimEnd('\')) {
    Fail "Refusing to dispose the source workspace: $SourceWs"
}

Write-Output 'About to dispose story workspace:'
Write-Output "  target:        $WsDir"
Write-Output "  delete-branch: $([int]$DeleteBranch)"
Write-Output "  force:         $([int]$Force)"
Write-Output "  keep-container:$([int]$KeepContainer)"
Write-Output "  keep-image:    $([int]$KeepImage)"
if (-not $AssumeYes) {
    $reply = Read-Host 'Proceed? [Y/n]'
    if ($reply -match '^[Nn]') {
        Write-Err "aborted. Pass --workspaces-root <path> or set `$env:$EnvVarWorkspacesRoot"
        Write-Err 'to point the script at a different workspaces directory.'
        exit 0
    }
}

# Mono-repo mode: an empty "repos" list in devcontainers-config.json signals that the source
# workspace IS the git repo. Synthesise a single virtual entry so all downstream
# loops work without special-casing each one (mirrors the spawn script).
$MonoRepo = $cfg.MonoRepo
$RepoNames = if ($MonoRepo) { @($ProjectName) } else { @($cfg.Repos | ForEach-Object { $_.Name }) }

function Get-SourceRepoDir {
    param([Parameter(Mandatory = $true)][string] $Repo)
    if ($MonoRepo) { return $SourceWs }
    return (Join-Path $SourceWs $Repo)
}

# ============================================================================
# 1. Dirty check
# ============================================================================
#
# Done up front, so we either remove everything or nothing. The check always
# runs; --force only changes whether dirtiness aborts or just warns. Warning
# loudly when forcing keeps the user from silently discarding work they didn't
# realise was there.
$Dirty = @()
foreach ($repo in $RepoNames) {
    $wt = Join-Path $WsDir $repo
    # -PathType is deliberately unset: a worktree carries a .git *file*, a plain
    # clone a .git directory.
    if (-not (Test-Path -LiteralPath (Join-Path $wt '.git'))) { continue }
    $status = Invoke-Git -RepoDir $wt -GitArgs @('status', '--porcelain') -AllowFailure -Quiet
    if ($status) { $Dirty += $repo }
}
if ($Dirty.Count -gt 0) {
    if (-not $Force) {
        Write-Err 'Worktrees with uncommitted changes:'
        $Dirty | ForEach-Object { Write-Err "  $_" }
        Fail 'Commit/stash them first, or rerun with --force to discard.'
    }
    Write-Err '--force will discard uncommitted changes in:'
    $Dirty | ForEach-Object { Write-Err "  $_" }
    Write-Err '         continuing in 3s, Ctrl-C to abort...'
    Start-Sleep -Seconds 3
}

# ============================================================================
# 2. Docker container, volumes and image
# ============================================================================
#
# Done FIRST -- before any filesystem removal below.
#
# The per-module node_modules are Docker named volumes mounted INTO the
# bind-mounted workspace (see the spawn script). While the container runs, those
# mount-points are live and the host cannot delete them, which would leave a
# running container AND a half-deleted workspace. Removing the container releases
# the mounts, turning those node_modules back into ordinary empty dirs.
#
# The spawn script names the container '<projectShort>-<leaf>' via runArgs. Named
# volumes (including the per-story Claude project volume whose name embeds a
# JetBrains devcontainerId hash) are discovered from the container at runtime.
$Container = "$ProjectShort-$Leaf"
if (-not $KeepContainer) {
    if ($DockerAvailable) {
        if ((Invoke-Docker @('inspect', $Container)).ExitCode -eq 0) {
            Write-Output ''
            Write-Output "removing docker container '$Container'"
            $imageId = (Invoke-Docker @('inspect', '--format', '{{.Image}}', $Container)).StdOut.Trim()
            $volTpl = '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}'
            $volumes = @((Invoke-Docker @('inspect', '--format', $volTpl, $Container)).StdOut -split "`r?`n" |
                         ForEach-Object { $_.Trim() } | Where-Object { $_ })
            Invoke-Docker @('rm', '-f', $Container) | Out-Null
            foreach ($v in $volumes) {
                Write-Output "removing docker volume '$v'"
                if ((Invoke-Docker @('volume', 'rm', $v)).ExitCode -ne 0) {
                    Write-Output "  (volume $v : already gone or in use)"
                }
            }
            if (-not $KeepImage -and $imageId) {
                Write-Output "removing devcontainer image $imageId"
                if ((Invoke-Docker @('rmi', $imageId)).ExitCode -ne 0) {
                    Write-Output '  (image not removed: still referenced by another container)'
                }
            }
        }
    } else {
        Write-Err 'docker not on PATH, skipping container cleanup'
    }
}

# ============================================================================
# 3. Remove the worktrees from each source repo
# ============================================================================
#
# We look up the *actual* registered path via `git worktree list` rather than
# only checking the expected path. A previous mis-pathed spawn (e.g. with a
# relative --workspaces-root) may have registered the worktree at a completely
# different location; checking only the expected path would silently skip it,
# leaving stale git metadata that makes the next spawn fail with
# "already used by worktree".
$Branch = ''   # remembered once read from a worktree (all repos share the name)

foreach ($repo in $RepoNames) {
    $src = Get-SourceRepoDir -Repo $repo
    $wt = Join-Path $WsDir $repo
    if (-not (Test-Path -LiteralPath (Join-Path $src '.git'))) { continue }

    # Capture the branch name from the expected worktree path (for the optional
    # branch deletion later). Falls back gracefully if the path doesn't exist.
    if (-not $Branch -and (Test-Path -LiteralPath $wt)) {
        $Branch = Invoke-Git -RepoDir $wt -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD') -AllowFailure -Quiet
    }

    # Find any worktree whose path contains the workspace name -- matches both
    # the correct path and mis-pathed registrations from earlier broken spawns.
    $listing = Invoke-Git -RepoDir $src -GitArgs @('worktree', 'list', '--porcelain') -AllowFailure -Quiet
    $actual = @()
    foreach ($line in ($listing -split "`r?`n")) {
        if ($line -match '^worktree\s+(.+)$') {
            $p = $Matches[1].Trim()
            if ($p -like "*$WsName*") { $actual += $p }
        }
    }

    foreach ($path in $actual) {
        Write-Output "remove worktree: $repo (at $path)"
        Invoke-Git -RepoDir $src -GitArgs @('worktree', 'remove', '--force', $path) -AllowFailure -Quiet | Out-Null
        if ($script:LastGitExitCode -ne 0) { Remove-TreeForce -Path ($path -replace '/', '\') }
    }
    # Prune any remaining stale entries (e.g. directory already deleted on disk).
    Invoke-Git -RepoDir $src -GitArgs @('worktree', 'prune') -AllowFailure -Quiet | Out-Null
    # Belt-and-suspenders: remove the expected path if it still exists but wasn't
    # registered.
    if (Test-Path -LiteralPath $wt) { Remove-TreeForce -Path $wt }
}

# ============================================================================
# 4. Remove the workspace directory itself
# ============================================================================
#
# Guard: if the container still exists, its per-module node_modules named volumes
# are still mounted into the workspace (see step 2). The host cannot delete a
# live mount-point, so the removal would fail with a confusing error on every
# .../node_modules. This happens when --keep-container was passed, or when step 2
# couldn't reach Docker. Detect it and print an actionable message instead.
if (Test-Path -LiteralPath $WsDir) {
    $containerStillThere = $false
    if ($DockerAvailable) {
        $containerStillThere = ((Invoke-Docker @('inspect', $Container)).ExitCode -eq 0)
    }
    if ($containerStillThere) {
        Write-Err ''
        Write-Err "Container '$Container' still exists and holds node_modules volume mounts"
        Write-Err "inside $WsDir; the workspace directory cannot be removed while those"
        Write-Err 'mounts are live.'
        if ($KeepContainer) {
            Write-Err 'You passed --keep-container. Close it in IntelliJ/Gateway, then rerun'
            Write-Err 'without --keep-container to also remove the workspace directory.'
        } else {
            Write-Err "Remove it manually with 'docker rm -f $Container' and rerun dispose."
        }
        Write-Err "Left $WsDir in place."
    } else {
        Remove-TreeForce -Path $WsDir
        Write-Output "removed: $WsDir"
    }
}

# ============================================================================
# 5. Optional: delete the local branch in each source repo
# ============================================================================
if ($DeleteBranch -and $Branch) {
    Write-Output ''
    Write-Output "deleting local branch '$Branch' in source repos:"
    foreach ($repo in $RepoNames) {
        $src = Get-SourceRepoDir -Repo $repo
        if (-not (Test-Path -LiteralPath (Join-Path $src '.git'))) { continue }
        if (-not (Test-GitSucceeded -RepoDir $src -GitArgs @('show-ref', '--verify', '--quiet', "refs/heads/$Branch"))) {
            continue
        }
        $flag = if ($Force) { '-D' } else { '-d' }
        $out = Invoke-Git -RepoDir $src -GitArgs @('branch', $flag, $Branch) -AllowFailure
        if ($script:LastGitExitCode -ne 0) {
            Write-Err "  ${repo}: branch not fully merged, keep or rerun with --force"
        } elseif ($out) {
            Write-Output "  $out"
        }
    }
}

Write-Output ''
Write-Output 'done.'
