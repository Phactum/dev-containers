<#
.SYNOPSIS
    spawn-workspace.ps1 - create an isolated, devcontainer-ready workspace for
    one story. Windows/PowerShell port of spawn-workspace.sh.

.DESCRIPTION
    Functionally identical to dev-containers/spawn-workspace.sh; read that
    script's header for the full feature rationale (branch-driven layout, git
    worktrees, per-repo base refs, no aggregator pom, Claude state layering,
    node_modules named volumes, port offsets, lifecycle hooks, ...). Both
    scripts read the same project configuration from devcontainers-config.json.

    WINDOWS-SPECIFIC DIFFERENCES (everything else behaves the same):

    1. Git worktree path resolution
       Git for Windows writes ABSOLUTE paths into the two files that link a
       worktree to its source repo:
           <workspace>/<repo>/.git                       -> "gitdir: C:/..."
           <src>/<repo>/.git/worktrees/<ws>/gitdir       -> "C:/.../.git"
       A "C:/..." path is not absolute for Linux, so git inside the container
       would report "not a git repository" for every worktree. This script
       therefore rewrites both files to RELATIVE paths after `git worktree
       add`, and the container mirrors the host's sibling layout:
           story workspace  -> /workspaces/<PROJECT_NAME>-<leaf>   (workspaceFolder)
           source workspace -> /workspaces/<PROJECT_NAME>
       With that, the same relative links resolve correctly on the Windows host
       AND inside the Linux container - no path rewriting at container start, no
       loss of host-side git usability in the story workspace.

    2. Claude memory key
       Because the in-container workspace path is no longer constant across
       stories, the Claude project key is "-workspaces-<PROJECT_NAME>-<leaf>".
       Shared memory is preserved regardless: the single host directory
       ~/.claude/projects/-workspaces-<PROJECT_NAME>/memory is bind-mounted onto
       the story-specific key inside the container, exactly like the Bash
       version does - memory shared, conversation history isolated.

    3. No initializeCommand
       The Bash version prepares host-side bind targets with a POSIX shell
       one-liner. On Windows that command would run through cmd.exe, so this
       script creates the directories itself before writing devcontainer.json.

    4. Resolved host paths instead of ${localEnv:HOME} / ${localWorkspaceFolder}
       Every bind source is written as a fully resolved Windows path in
       Docker-friendly forward-slash form (C:/Users/...), which avoids
       ambiguity in how a devcontainer tool expands those variables on Windows.

    5. SSH agent forwarding is conditional
       The mount of Docker Desktop's ssh-auth socket (and SSH_AUTH_SOCK) is only
       emitted when the Windows "OpenSSH Authentication Agent" service is
       actually running. Otherwise ssh in the container simply prompts for the
       key passphrase, as it would without the forward.

    6. Timezone detection
       The Windows time zone ID is translated to its IANA name (via the .NET
       API where available, otherwise a built-in mapping table, otherwise UTC).

    7. Generated files are always written as UTF-8 without BOM and with LF line
       endings, so the shell scripts run inside the Linux container.

    8. Distro support ("distro" in devcontainers-config.json)
       Both the Bash and the PowerShell scripts can build the container on a
       RHEL-family base ("distro": "rocky"). The generated Dockerfile then
       replaces every devcontainer feature - they are Debian/Ubuntu-only - with
       dnf installs (vscode user, JDK, Maven, Node, docker-ce), and
       devcontainer.json adds the --privileged/--init flags and the
       /var/lib/docker volume that the docker-in-docker feature would otherwise
       contribute. Default is "debian", which produces exactly the previous
       output.

.PARAMETER Arguments
    Positional/flag arguments, accepted in the same spelling as the Bash script:
        [-c|--config <path>] [--workspaces-root <path>] [-y|--yes] [-h|--help] <branch-name>

.EXAMPLE
    # from the project directory (finds .\dev-containers\devcontainers-config.json)
    spawn-workspace.ps1 feature/FLOW-4711_example-story

.EXAMPLE
    # explicit config, runnable from anywhere
    spawn-workspace.ps1 --config D:\work\myproject\dev-containers\devcontainers-config.json feature/FLOW-4711_example

.EXAMPLE
    spawn-workspace.ps1 --workspaces-root D:\dev feature/FLOW-4711_example

.EXAMPLE
    $env:FLOW_WORKSPACES_ROOT = 'D:\dev'
    spawn-workspace.ps1 --yes feature/FLOW-4711_example

.NOTES
    INSTALLATION
      Clone this directory ONCE and add it to your PATH, e.g.

          git clone <url> $HOME\tools\dev-containers
          $env:PATH += ";$HOME\tools\dev-containers"     # or set it permanently:
          [Environment]::SetEnvironmentVariable('PATH',
              [Environment]::GetEnvironmentVariable('PATH','User') + ";$HOME\tools\dev-containers",
              'User')

      PowerShell finds .ps1 files on the PATH, so `spawn-workspace.ps1 <branch>`
      then works from any directory. Per-project settings live in that project's
      own devcontainers-config.json; the scripts stay untouched and are shared by every project.

    The devcontainers-config.json is located in this order:
      1. --config <path>   file, or a directory containing devcontainers-config.json
      2. .\dev-containers\devcontainers-config.json, relative to the CURRENT WORKING DIRECTORY
      3. .\devcontainers-config.json,                relative to the CURRENT WORKING DIRECTORY
    Its directory becomes the base directory for the other project assets:
    README.md.tpl, initialize.sh and runConfigurations\ are read from there,
    falling back to the copies shipped next to the scripts. Because of that
    fallback, a lone devcontainers-config.json in the project directory is a complete setup.

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
# Windows time zone ID -> IANA name, needed for the container's TZ so that
# Spring Boot (and every other JVM) logs in local time instead of the UTC
# default of the devcontainer base image. .NET 6+ ships the ICU-backed
# conversion; Windows PowerShell 5.1 runs on .NET Framework, which does not, so
# a table covers the common zones and UTC is the final fallback (which just
# preserves the pre-existing behaviour).
function Get-HostIanaTimeZone {
    $winId = try { (Get-TimeZone).Id } catch { '' }
    if (-not $winId) { return 'UTC' }

    try {
        $method = [System.TimeZoneInfo].GetMethod(
            'TryConvertWindowsIdToIanaId',
            [type[]] @([string], [string].MakeByRefType()))
        if ($method) {
            $callArgs = [object[]] @($winId, $null)
            if ($method.Invoke($null, $callArgs)) { return [string]$callArgs[1] }
        }
    } catch {
        # fall through to the table below
    }

    $map = @{
        'W. Europe Standard Time'        = 'Europe/Berlin'
        'Central Europe Standard Time'   = 'Europe/Budapest'
        'Central European Standard Time' = 'Europe/Warsaw'
        'Romance Standard Time'          = 'Europe/Paris'
        'GMT Standard Time'              = 'Europe/London'
        'Greenwich Standard Time'        = 'Atlantic/Reykjavik'
        'E. Europe Standard Time'        = 'Europe/Chisinau'
        'FLE Standard Time'              = 'Europe/Kiev'
        'GTB Standard Time'              = 'Europe/Bucharest'
        'Turkey Standard Time'           = 'Europe/Istanbul'
        'Russian Standard Time'          = 'Europe/Moscow'
        'Israel Standard Time'           = 'Asia/Jerusalem'
        'Arabian Standard Time'          = 'Asia/Dubai'
        'India Standard Time'            = 'Asia/Kolkata'
        'China Standard Time'            = 'Asia/Shanghai'
        'Singapore Standard Time'        = 'Asia/Singapore'
        'Tokyo Standard Time'            = 'Asia/Tokyo'
        'Korea Standard Time'            = 'Asia/Seoul'
        'AUS Eastern Standard Time'      = 'Australia/Sydney'
        'New Zealand Standard Time'      = 'Pacific/Auckland'
        'Eastern Standard Time'          = 'America/New_York'
        'Central Standard Time'          = 'America/Chicago'
        'Mountain Standard Time'         = 'America/Denver'
        'Pacific Standard Time'          = 'America/Los_Angeles'
        'US Eastern Standard Time'       = 'America/Indiana/Indianapolis'
        'Canada Central Standard Time'   = 'America/Regina'
        'SA Pacific Standard Time'       = 'America/Bogota'
        'E. South America Standard Time' = 'America/Sao_Paulo'
        'Argentina Standard Time'        = 'America/Argentina/Buenos_Aires'
        'South Africa Standard Time'     = 'Africa/Johannesburg'
        'UTC'                            = 'UTC'
    }
    if ($map.ContainsKey($winId)) { return $map[$winId] }

    Write-Err "note: no IANA mapping for Windows time zone '$winId' -- using UTC in the container"
    return 'UTC'
}

# ============================================================================
# Argument parsing (same spelling as the Bash script)
# ============================================================================

$Usage = @'
usage: spawn-workspace.ps1 [--config <path>] [--workspaces-root <path>] [--yes] [--rebuild-base-image] <branch-name>

  -c, --config <path>       devcontainers-config.json to use, or a directory containing it
                            (default: .\dev-containers\devcontainers-config.json, relative to
                            the current directory)
  --workspaces-root <path>  directory holding <PROJECT_NAME> and the story
                            workspaces (default: from "workspacesRoot" in devcontainers-config.json, else auto-detected)
  -y, --yes                 skip the confirmation prompt
  --rebuild-base-image      force a fresh build of the cached base image even
                            if a matching tag already exists locally (use
                            after the internal mirror content changed without
                            a devcontainers-config.json version bump)
  -h, --help                show this help

Base refs for new branches are configured per repo in "repos" (devcontainers-config.json).
If the branch already exists locally or on origin, the existing tip is reused
and the base ref is ignored.
'@

$Branch = ''
$WorkspacesRootCli = ''
$ConfigCli = ''
$AssumeYes = $false
$RebuildBaseImage = $false

for ($i = 0; $i -lt $Arguments.Count; $i++) {
    $a = $Arguments[$i]
    switch -Regex ($a) {
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
        '^--rebuild-base-image$' { $RebuildBaseImage = $true; continue }
        '^(-h|--help|-\?)$'   { Write-Output $Usage; exit 0 }
        '^-'                  { Fail "unknown option: $a" 2 }
        default {
            if ($Branch) { Fail "unexpected argument: $a" 2 }
            $Branch = $a
        }
    }
}

if (-not $Branch) {
    Write-Err $Usage
    exit 2
}

# ============================================================================
# Project configuration
# ============================================================================

# --config wins; otherwise .\dev-containers\devcontainers-config.json or .\devcontainers-config.json,
# relative to the current directory. The config's directory is the base for the
# other project assets.
$ConfigPath = Resolve-DevContainerConfigPath -ConfigPath $ConfigCli
$cfg = Get-DevContainerConfig -Path $ConfigPath
$ConfigDir = $cfg.Dir
$ProjectName = $cfg.ProjectName
$ProjectShort = $cfg.ProjectShort

# Resolve a project asset: prefer the copy next to devcontainers-config.json, fall back to the
# one shipped next to the scripts (which may live anywhere on the PATH). Returns
# '' when neither exists, so callers can treat the asset as optional.
function Get-ConfigAsset {
    param([Parameter(Mandatory = $true)][string] $Name)
    $fromConfig = Join-Path $ConfigDir $Name
    if (Test-Path -LiteralPath $fromConfig) { return $fromConfig }
    $fromScript = Join-Path $PSScriptRoot $Name
    if (Test-Path -LiteralPath $fromScript) { return $fromScript }
    return ''
}

# Env var name for the workspaces-root override. Derived from projectShort
# (uppercased) so different projects don't fight for the same name.
$EnvVarWorkspacesRoot = ($ProjectShort -replace '[^A-Za-z0-9]', '_').ToUpperInvariant() + '_WORKSPACES_ROOT'

# GitLab integration is optional; it only kicks in when BOTH glabHostname and
# glabVersion are set. GitHub integration needs only ghVersion (gh always
# targets github.com). The conditional blocks in the generated files are
# stripped via __GLAB_BLOCK_*__ / __GH_BLOCK_*__ markers.
$GlabEnabled = (-not [string]::IsNullOrWhiteSpace($cfg.GlabHostname)) -and
               (-not [string]::IsNullOrWhiteSpace($cfg.GlabVersion))
$GhEnabled = -not [string]::IsNullOrWhiteSpace($cfg.GhVersion)

# Corporate proxy / TLS interception. Three independent switches, each driving a
# conditional block in the generated Dockerfile / devcontainer.json. All default
# to off, so a project without a "proxy" block gets exactly the same container
# as before.
$ProxyEnabled = (-not [string]::IsNullOrWhiteSpace($cfg.ProxyHttp)) -or
                (-not [string]::IsNullOrWhiteSpace($cfg.ProxyHttps))
$CaEnabled = $cfg.ProxyCaCerts.Count -gt 0
$AptHttpsEnabled = [bool]$cfg.ProxyDebianHttps

# Optional image build steps. Each defaults to on; turning one off drops the
# corresponding block from the generated Dockerfile (and, for chromium, the
# matching npm install from post-create.sh). Meant for builds that cannot reach
# a Debian package mirror -- see "imageBuild" in devcontainers-config.json for what each one
# costs.
$AptPkgsEnabled = [bool]$cfg.ImageAptPackages
$RecentGitEnabled = [bool]$cfg.ImageRecentGit
$ChromiumEnabled = [bool]$cfg.ImageChromium
if (-not ($AptPkgsEnabled -and $RecentGitEnabled -and $ChromiumEnabled)) {
    Write-Output ("image build steps: apt-packages={0} recent-git={1} chromium={2}" -f `
        [int]$AptPkgsEnabled, [int]$RecentGitEnabled, [int]$ChromiumEnabled)
}
if ($cfg.FeatureRegistry -ne 'ghcr.io') { Write-Output "feature registry:  $($cfg.FeatureRegistry)" }

# Package-manager family of the base image ("debian" | "rocky"). Everything
# distro-specific in the generated files sits in __DEB_BLOCK_*__ / __RPM_BLOCK_*__
# markers; exactly one of the two survives the substitution pass.
#
# Why Rocky needs its own path at all: the devcontainer FEATURES (java, node,
# git, docker-in-docker) are Debian/Ubuntu-only -- their install.sh calls
# apt-get and aborts on a RHEL-family base. So on Rocky the generated
# devcontainer.json declares no features and the Dockerfile installs the same
# toolchain from dnf / upstream tarballs instead.
$IsRocky = ($cfg.Distro -eq 'rocky')
$DebianEnabled = -not $IsRocky

# Where the JDK ends up, which the generated files hard-code in a dozen places
# (containerEnv, remoteEnv, profile.d, bashrc, post-create's probe).
#   Debian: the MS base image's own JDK.
#   Rocky : a stable symlink the Dockerfile creates next to the versioned
#           java-<n>-openjdk directory dnf installs, so the value stays
#           independent of the exact package release and the architecture.
$JavaHome = if ($IsRocky) { '/usr/lib/jvm/devcontainer-java' } else { '/usr/lib/jvm/msopenjdk-current' }

# System-wide rc file for interactive non-login bashes: Debian reads
# /etc/bash.bashrc, RHEL-family /etc/bashrc.
$SystemBashrc = if ($IsRocky) { '/etc/bashrc' } else { '/etc/bash.bashrc' }

if ($IsRocky) {
    Write-Output ("distro:           rocky (jdk {0}, maven {1}, node {2}, no devcontainer features)" -f `
        $cfg.JavaVersion, $cfg.MavenVersion, $cfg.NodeFeatureVersion)
}

# Repos: "<name>" + per-repo base ref. Mono-repo mode (empty list in devcontainers-config.json)
# synthesises a single virtual entry so every loop below works unchanged.
$MonoRepo = $cfg.MonoRepo
$Repos = @($cfg.Repos)
if ($MonoRepo) {
    $Repos = @([pscustomobject]@{ Name = $ProjectName; BaseRef = '' })
}
$RepoNames = @($Repos | ForEach-Object { $_.Name })

$BuildMode = $cfg.BuildMode
$BuildEntries = @($cfg.Builds)

# ============================================================================
# Paths
# ============================================================================

# Resolve the workspaces root. Priority (see Resolve-WorkspacesRoot in
# EnvConfig.ps1): --workspaces-root flag, env var, "workspacesRoot" in
# devcontainers-config.json, then auto-detect from the config location. Deliberately derived
# from the config and NOT from the script, which may sit anywhere on the PATH.
$WorkspacesRoot = Resolve-WorkspacesRoot -Config $cfg -Cli $WorkspacesRootCli -EnvVarName $EnvVarWorkspacesRoot

$SourceWs = Join-Path $WorkspacesRoot $ProjectName
$Leaf = ($Branch -split '/')[-1]
$WsName = "$ProjectName-$Leaf"
$WsDir = Join-Path $WorkspacesRoot $WsName

# In-container paths. Both workspaces are mounted as siblings under /workspaces
# so the relative git worktree links resolve on host and container alike.
$WorkspacePath = "/workspaces/$WsName"
$SourceWsContainer = "/workspaces/$ProjectName"
# Claude Code derives the project key from the cwd.
$MemoryKey = "-workspaces-$WsName"
# ... but memory itself stays in ONE host folder shared by every story container
# (and by containers spawned from macOS/Linux, which use this same key).
$SharedMemoryKey = "-workspaces-$ProjectName"

$HomeDir = $env:USERPROFILE
if (-not $HomeDir) { Fail 'USERPROFILE is not set - cannot resolve the host home directory.' }
$HomeDir = $HomeDir.TrimEnd('\')

# A leftover workspace from an earlier spawn would cause partial overwrites if
# we charged ahead. Dispose it first or rename it out of the way.
if (Test-Path -LiteralPath $WsDir) {
    Write-Err "Workspace already exists: $WsDir"
    Fail "Dispose it first: dispose-workspace.ps1 $Branch"
}

# ---------------------------------------------------------------------------
# Preflight: validate EVERY config-driven file asset before touching anything.
#
# All the generation below mutates the host (WsDir, worktrees, branches,
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

# Run-config XMLs (RunConfigs -> runConfigurations\).
$runConfigSrcDir = Get-ConfigAsset 'runConfigurations'
if (-not $runConfigSrcDir) { $runConfigSrcDir = Join-Path $ConfigDir 'runConfigurations' }
foreach ($rcFile in $cfg.RunConfigs) {
    $src = Join-Path $runConfigSrcDir $rcFile
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
        Write-Err "Run-config source missing: $src"
        Fail 'Check "runConfigs" in devcontainers-config.json.'
    }
}

# Corporate-proxy CA certificates (proxy.caCertificates). Copied into the build
# context by the CaEnabled block far below.
if ($CaEnabled) {
    foreach ($ca in $cfg.ProxyCaCerts) {
        $caSrc = $ca
        if (-not [System.IO.Path]::IsPathRooted($caSrc)) { $caSrc = Join-Path $ConfigDir $caSrc }
        if (-not (Test-Path -LiteralPath $caSrc -PathType Leaf)) {
            Write-Err "CA certificate not found: $caSrc"
            Fail "Check `"proxy.caCertificates`" in $($cfg.Path)."
        }
    }
}

# Welcome README template (README.md.tpl, project copy or the fallback next to
# the scripts). $readmeTpl is reused by the copy site below.
$readmeTpl = Get-ConfigAsset 'README.md.tpl'
if (-not $readmeTpl) { Fail "README template not found: $ConfigDir\README.md.tpl (nor next to the scripts)" }
# ---------------------------------------------------------------------------

Write-Output 'About to create story workspace:'
Write-Output "  target:  $WsDir"
Write-Output "  branch:  $Branch"
Write-Output "  source:  $SourceWs"
if (-not $AssumeYes) {
    $reply = Read-Host 'Proceed? [Y/n]'
    if ($reply -match '^[Nn]') {
        Write-Err "aborted. Pass --workspaces-root <path> or set `$env:$EnvVarWorkspacesRoot"
        Write-Err 'to point the script at a different workspaces directory.'
        exit 0
    }
}

# ============================================================================
# Port offset
# ============================================================================
#
# Pick an offset (multiple of portOffsetStep) where ALL forwarded ports are free
# on the host, so several stories can run their containers in parallel without
# colliding. Offset 0 means the original port numbers. Three sources are probed:
# ports statically reserved by other story workspaces' devcontainer.json files,
# ports bound by ANY docker container (including stopped ones and containers of
# other projects), and currently-live listeners.

$HostPortNumbers = @($cfg.HostPorts | ForEach-Object { $_.Port })

$ReservedHostPorts = New-Object System.Collections.Generic.HashSet[int]

# Reserved by other story workspaces. Even if their containers are stopped right
# now, starting them later would clash with our offset choice. The regex matches
# "<num>:<num>" - only port mappings appear in that quoted-pair shape.
Get-ChildItem -LiteralPath $WorkspacesRoot -Directory -Filter "$ProjectName-*" -ErrorAction SilentlyContinue |
    ForEach-Object {
        $dc = Join-Path $_.FullName '.devcontainer\devcontainer.json'
        if ((Test-Path -LiteralPath $dc) -and $_.FullName -ne $WsDir) {
            foreach ($m in [regex]::Matches((Read-TextFile $dc), '"(\d+):(\d+)"')) {
                [void]$ReservedHostPorts.Add([int]$m.Groups[1].Value)
            }
        }
    }
if ($ReservedHostPorts.Count -gt 0) {
    Write-Output "ports reserved by other workspaces: $(($ReservedHostPorts | Sort-Object) -join ' ')"
}

# Reserved by docker containers. HostConfig.PortBindings holds the statically
# mapped host ports regardless of run state, which closes the cross-project
# collision gap that the two other sources miss. Best-effort: skipped when
# docker is absent or the daemon is unreachable.
$DockerAvailable = $null -ne (Get-Command docker -ErrorAction SilentlyContinue)
if ($DockerAvailable) {
    $dockerReserved = @()
    $ps = Invoke-Docker @('ps', '-a', '--format', '{{.ID}}')
    $ids = @($ps.StdOut -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($ps.ExitCode -eq 0 -and $ids.Count -gt 0) {
        $tpl = '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}}{{"\n"}}{{end}}{{end}}'
        $inspect = Invoke-Docker (@('inspect', '--format', $tpl) + $ids)
        foreach ($line in ($inspect.StdOut -split "`r?`n")) {
            if ($line -match '^\s*(\d+)\s*$') {
                $dockerReserved += [int]$Matches[1]
                [void]$ReservedHostPorts.Add([int]$Matches[1])
            }
        }
    } elseif ($ps.ExitCode -ne 0) {
        Write-Err 'note: could not query docker for reserved ports (is Docker Desktop running?)'
    }
    if ($dockerReserved.Count -gt 0) {
        Write-Output "ports reserved by docker containers: $(($dockerReserved | Sort-Object -Unique) -join ' ')"
    }
} else {
    Write-Err 'docker not on PATH, skipping the container port-reservation scan'
}

# Live listeners on the host. GetActiveTcpListeners() is part of the .NET base
# class library, so it works on Windows PowerShell 5.1 without any module.
$ActiveListenerPorts = New-Object System.Collections.Generic.HashSet[int]
try {
    foreach ($ep in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
        [void]$ActiveListenerPorts.Add($ep.Port)
    }
} catch {
    Write-Err "note: could not enumerate active TCP listeners ($($_.Exception.Message))"
}

function Test-PortInUse {
    param([Parameter(Mandatory = $true)][int] $Port)
    if ($ReservedHostPorts.Contains($Port)) { return $true }
    return $ActiveListenerPorts.Contains($Port)
}

# Step size constrained to [500, 10000]: below 500 the offset ranges of two
# workspaces could overlap by less than the host-port spread; above 10000 offers
# no benefit and quickly runs host ports past the 65535 ceiling.
$PortOffsetStep = $cfg.PortOffsetStep
if ($PortOffsetStep -lt 500 -or $PortOffsetStep -gt 10000) {
    Fail "ERROR: portOffsetStep must be between 500 and 10000, got $PortOffsetStep"
}

$PortOffsetMax = 50000
$PortOffset = 0
while ($PortOffset -le $PortOffsetMax) {
    $freeRange = $true
    foreach ($p in $HostPortNumbers) {
        if (Test-PortInUse ($p + $PortOffset)) { $freeRange = $false; break }
    }
    if ($freeRange) { break }
    $PortOffset += $PortOffsetStep
}
if ($PortOffset -gt $PortOffsetMax) {
    Fail "ERROR: no free port range found (tried offset 0..$PortOffsetMax in $PortOffsetStep steps)"
}
Write-Output "port offset: $PortOffset"

# Derived per-port artifacts, all built from devcontainers-config.json's hostPorts so that adding
# a forwarded port only takes editing the config:
#   $PortTokens      __PORT_<container>__ -> offset host port (placeholder pass)
#   $PortRunArgs     JSON snippet for devcontainer.json runArgs ("-p", "h:c")
#   $PortTableRows   markdown table rows for the workspace README
#   $PortOutputLines plain-text port summary printed at the end
$PortTokens = [ordered]@{}
$portRunArgsParts = @()
$portTableRowsParts = @()
$portOutputParts = @()
foreach ($hp in $cfg.HostPorts) {
    $hostPort = $hp.Port + $PortOffset
    $PortTokens["__PORT_$($hp.Port)__"] = "$hostPort"
    $portRunArgsParts += "`"-p`", `"${hostPort}:$($hp.Port)`""
    $portTableRowsParts += "| $hostPort | $($hp.Port) | $($hp.Label) |"
    $portOutputParts += "  $hostPort  $($hp.Label)"
}
$PortRunArgs = $portRunArgsParts -join ', '
$PortTableRows = $portTableRowsParts -join "`n"
$PortOutputLines = $portOutputParts -join "`n"

# SSH_HOST_PORT: host-side port for the container's sshd (2222 + offset).
# FIRST_REPO: first repo name, used as an example in the README's shortcut docs.
$SshHostPort = 2222 + $PortOffset
$FirstRepo = if ($RepoNames.Count -gt 0) { $RepoNames[0] } else { 'some-repo' }

# ============================================================================
# Host-side warnings and preparation
# ============================================================================

# Warn only if the host actually USES env-var placeholders for private-package
# auth (some setups put literal tokens in ~/.npmrc / ~/.m2/settings.xml, in
# which case these env vars don't matter locally and the warning is noise).
$HostNpmrc = Join-Path $HomeDir '.npmrc'
$HostM2Settings = Join-Path $HomeDir '.m2\settings.xml'
foreach ($var in $cfg.ForwardedEnvVars) {
    $referencesVar = $false
    if (Test-Path -LiteralPath $HostNpmrc) {
        if ((Read-TextFile $HostNpmrc) -like "*`${$var}*") { $referencesVar = $true }
    }
    if (Test-Path -LiteralPath $HostM2Settings) {
        if ((Read-TextFile $HostM2Settings) -match ('\$\{(env\.)?' + [regex]::Escape($var) + '\}')) { $referencesVar = $true }
    }
    if ($referencesVar -and -not [Environment]::GetEnvironmentVariable($var)) {
        Write-Err "WARN: `$env:$var is referenced as a placeholder in your host npmrc/settings.xml"
        Write-Err '      but not set in this shell -- npm/Maven will fail with 401 on private packages.'
        Write-Err '      Set it in this shell (or system-wide) and re-run.'
    }
}

New-Item -ItemType Directory -Path $WsDir -Force | Out-Null

# ============================================================================
# Git worktrees
# ============================================================================

# Resolve a base ref against the given repo: prefer origin/<ref>, fall back to
# the local <ref>. Returns '' when the repo knows neither.
function Resolve-BaseRef {
    param(
        [Parameter(Mandatory = $true)][string] $RepoDir,
        [Parameter(Mandatory = $true)][string] $Ref
    )
    if (Test-GitSucceeded -RepoDir $RepoDir -GitArgs @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$Ref")) {
        return "origin/$Ref"
    }
    if (Test-GitSucceeded -RepoDir $RepoDir -GitArgs @('rev-parse', '--verify', '--quiet', $Ref)) {
        return $Ref
    }
    return ''
}

# Rewrite the worktree's ".git" pointer file from the absolute Windows path git
# just wrote to a path relative to the worktree directory.
#
# Why: git for Windows writes "gitdir: C:/...", which Linux does not consider
# absolute, so git inside the container would fail with "not a git repository"
# for every worktree. A relative link resolves on both sides because the
# container mounts the story workspace and the source workspace as siblings
# under /workspaces (see the header).
#
# The reverse link (<src>/.git/worktrees/<id>/gitdir) is deliberately left
# absolute: git only learned to read a relative path there in 2.48, and older
# versions treat the worktree as "prunable" and drop its metadata on the next
# `git worktree prune`. That file is only consulted by host-side worktree
# bookkeeping, which the dispose script performs on Windows anyway.
function Convert-WorktreeLinkToRelative {
    param([Parameter(Mandatory = $true)][string] $WorktreeDir)

    $gitFile = Join-Path $WorktreeDir '.git'
    if (-not (Test-Path -LiteralPath $gitFile -PathType Leaf)) { return }

    $content = (Read-TextFile $gitFile).Trim()
    if ($content -notmatch '^gitdir:\s*(.+)$') { return }
    $target = $Matches[1].Trim()
    # Already relative (e.g. git 2.48+ with worktree.useRelativePaths) -> done.
    if ($target -notmatch '^([A-Za-z]:[\\/]|[\\/])') { return }

    $relative = Get-RelativePosixPath -From $WorktreeDir -To $target

    # git marks the pointer file hidden on Windows; clear the attribute for the
    # rewrite and restore it afterwards so the working tree looks untouched.
    $item = Get-Item -LiteralPath $gitFile -Force
    $hadHidden = ($item.Attributes -band [System.IO.FileAttributes]::Hidden) -ne 0
    $item.Attributes = $item.Attributes -band (-bnot ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::ReadOnly))
    [System.IO.File]::WriteAllText($gitFile, "gitdir: $relative`n", (New-Object System.Text.UTF8Encoding($false)))
    if ($hadHidden) {
        $item = Get-Item -LiteralPath $gitFile -Force
        $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
    }
}

function New-Worktree {
    param(
        [Parameter(Mandatory = $true)][string] $Repo,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $BaseRef
    )

    # Mono-repo: the source workspace IS the git repo; no sub-directory.
    $src = if ($MonoRepo) { $SourceWs } else { Join-Path $SourceWs $Repo }
    $dst = Join-Path $WsDir $Repo

    # Accept both a real .git directory and a .git *file*: git submodules store
    # their metadata under the superproject's .git/modules/<name> and leave only
    # a "gitdir: ..." pointer file in the working tree.
    if (-not (Test-Path -LiteralPath (Join-Path $src '.git'))) {
        Write-Output "skip ${Repo}: no git repo at $src"
        return
    }

    $baseLabel = if ($BaseRef) { $BaseRef } else { '<origin/HEAD>' }
    Write-Output "worktree: $Repo (base $baseLabel)"

    # Prune stale worktree entries before adding. Without this, a failed or
    # mis-pathed previous spawn leaves git metadata pointing at a deleted
    # directory, causing "already used by worktree" on the next attempt.
    Invoke-Git -RepoDir $src -GitArgs @('worktree', 'prune') | Out-Null
    Invoke-Git -RepoDir $src -GitArgs @('fetch', '--quiet', 'origin') -AllowFailure -Quiet | Out-Null

    if (Test-GitSucceeded -RepoDir $src -GitArgs @('show-ref', '--verify', '--quiet', "refs/heads/$Branch")) {
        # Local branch exists. Fast-forward it before checking out so the new
        # worktree reflects the latest state rather than a stale local snapshot.
        #
        # (i) origin/<branch> also exists: fast-forward to the remote tip if the
        #     local is a strict ancestor, i.e. has no divergent commits. This
        #     picks up commits pushed by collaborators; divergent locals are
        #     left as-is.
        # (ii) No remote counterpart: if the local has no story-specific commits
        #     yet (its tip is an ancestor of the configured base), fast-forward
        #     to that base. Handles re-spawn-after-dispose-without-delete-branch.
        if (Test-GitSucceeded -RepoDir $src -GitArgs @('show-ref', '--verify', '--quiet', "refs/remotes/origin/$Branch")) {
            $localTip = Invoke-Git -RepoDir $src -GitArgs @('rev-parse', "refs/heads/$Branch")
            $remoteTip = Invoke-Git -RepoDir $src -GitArgs @('rev-parse', "refs/remotes/origin/$Branch")
            if ($localTip -ne $remoteTip -and
                (Test-GitSucceeded -RepoDir $src -GitArgs @('merge-base', '--is-ancestor', $localTip, $remoteTip))) {
                Write-Output "  fast-forwarding '$Branch' to origin/$Branch"
                Invoke-Git -RepoDir $src -GitArgs @('update-ref', "refs/heads/$Branch", $remoteTip) | Out-Null
            }
        } elseif ($BaseRef) {
            $baseResolved = Resolve-BaseRef -RepoDir $src -Ref $BaseRef
            if ($baseResolved) {
                $branchTip = Invoke-Git -RepoDir $src -GitArgs @('rev-parse', "refs/heads/$Branch")
                $baseTip = Invoke-Git -RepoDir $src -GitArgs @('rev-parse', $baseResolved)
                if ($branchTip -ne $baseTip -and
                    (Test-GitSucceeded -RepoDir $src -GitArgs @('merge-base', '--is-ancestor', $branchTip, $baseTip))) {
                    Write-Output "  branch '$Branch' has no commits beyond $baseResolved, fast-forwarding"
                    Invoke-Git -RepoDir $src -GitArgs @('update-ref', "refs/heads/$Branch", $baseTip) | Out-Null
                }
            }
        }
        Invoke-Git -RepoDir $src -GitArgs @('worktree', 'add', $dst, $Branch) | Write-Output
    } elseif (Test-GitSucceeded -RepoDir $src -GitArgs @('ls-remote', '--exit-code', '--heads', 'origin', $Branch)) {
        # Remote branch exists, no local copy -> track it.
        Invoke-Git -RepoDir $src -GitArgs @('worktree', 'add', '--track', '-b', $Branch, $dst, "origin/$Branch") | Write-Output
    } else {
        # Branch is new -> base it on this repo's configured base ref if present,
        # otherwise (or when the repo doesn't know that ref, e.g. a docs-only
        # repo has no 'development' branch) fall back to the repo's origin/HEAD.
        $base = ''
        if ($BaseRef) { $base = Resolve-BaseRef -RepoDir $src -Ref $BaseRef }
        if (-not $base) {
            if ($BaseRef) {
                Write-Output "  note: base '$BaseRef' not found in $Repo, using origin/HEAD instead"
            }
            $base = Invoke-Git -RepoDir $src -GitArgs @('symbolic-ref', '--short', 'refs/remotes/origin/HEAD') -AllowFailure -Quiet
            if (-not $base) { $base = 'origin/main' }
        }
        Write-Output "  new branch from $base"
        # --no-track: don't inherit ${base} as upstream. Otherwise the new local
        # branch would get upstream=origin/<base>, and push.default=simple then
        # refuses 'git push' because local and upstream names don't match. With
        # --no-track the first 'git push -u origin HEAD' wires it up cleanly.
        Invoke-Git -RepoDir $src -GitArgs @('worktree', 'add', '--no-track', '-b', $Branch, $dst, $base) | Write-Output
    }

    Convert-WorktreeLinkToRelative -WorktreeDir $dst
}

# Host-mount repos: an entry with an EMPTY baseRef is not a git repo -- no
# worktree is created. Instead the host directory <SourceWs>/<repo> is
# bind-mounted straight into the workspace at the same path a worktree would
# occupy. Use this for pre-built artifacts / non-versioned dirs that should
# still be visible and buildable inside the container. (Mono-repo's synthetic
# entry also has an empty base ref but IS a real git repo, hence the guard.)
$HostMountRepos = @()
foreach ($entry in $Repos) {
    if (-not $MonoRepo -and [string]::IsNullOrEmpty($entry.BaseRef)) {
        Write-Output "host-mount: $($entry.Name) (bind $SourceWs\$($entry.Name), no worktree)"
        $HostMountRepos += $entry.Name
        continue
    }
    New-Worktree -Repo $entry.Name -BaseRef $entry.BaseRef
}

# Each source repo has its own .git/config which can ship with stale settings
# from a long-ago first clone: core.filemode=true, no core.autocrlf, etc.
# Worktrees inherit those because they all share the main repo's config, and the
# git --global defaults set inside the container DON'T win because local repo
# config trumps global. Set them locally per source repo so the container-
# friendly values stick everywhere. autocrlf=input additionally keeps the
# checked-out worktree free of CRLF, which the Linux build would trip over.
foreach ($repo in $RepoNames) {
    $srcRepo = if ($MonoRepo) { $SourceWs } else { Join-Path $SourceWs $repo }
    if (-not (Test-Path -LiteralPath (Join-Path $srcRepo '.git'))) { continue }
    Invoke-Git -RepoDir $srcRepo -GitArgs @('config', 'core.fileMode', 'false') | Out-Null
    Invoke-Git -RepoDir $srcRepo -GitArgs @('config', 'core.autocrlf', 'input') | Out-Null
    # Same as the --global settings in post-create.sh, but written locally so
    # they survive even if a future global gets cleared. checkStat/trustctime
    # work around bind-mount stat drift that makes rebase steps spuriously abort
    # with "Your local changes would be overwritten".
    Invoke-Git -RepoDir $srcRepo -GitArgs @('config', 'core.checkStat', 'minimal') | Out-Null
    Invoke-Git -RepoDir $srcRepo -GitArgs @('config', 'core.trustctime', 'false') | Out-Null
}

# ============================================================================
# node_modules named volumes + host-mount binds
# ============================================================================
#
# Every npm module (each package.json outside node_modules/.git) gets its
# node_modules mounted as a Docker named volume instead of living in the
# bind-mounted workspace. Rationale: Docker Desktop bridges every file of a bind
# mount between the Linux VM and the host; for node_modules with tens of
# thousands of files npm becomes 10-100x slower. Named volumes live on the VM's
# own filesystem, so npm writes at Linux-native speed. dispose-workspace.ps1
# removes these volumes automatically via `docker inspect` on the container.
$NpmModuleDirs = @()
Get-ChildItem -LiteralPath $WsDir -Recurse -File -Filter 'package.json' -Force -ErrorAction SilentlyContinue |
    ForEach-Object {
        $rel = $_.DirectoryName.Substring($WsDir.Length).TrimStart('\')
        $relPosix = ($rel -replace '\\', '/')
        if ($relPosix -match '(^|/)node_modules(/|$)' -or $relPosix -match '(^|/)\.git(/|$)') { return }
        if ($relPosix) { $NpmModuleDirs += $relPosix }
    }

# JSON fragment appended after the last fixed entry of the mounts array; each
# line carries a leading comma so it splices in cleanly.
$NpmVolumeMounts = ''
foreach ($relDir in $NpmModuleDirs) {
    $slug = ($relDir -replace '[/_]', '-')
    $volName = "$ProjectShort-$Leaf-$slug-nm"
    $NpmVolumeMounts += "        ,`"source=$volName,target=$WorkspacePath/$relDir/node_modules,type=volume`"`n"
}

# One bind mount per host-mount repo, from the host source dir to its workspace
# path in the container. An empty placeholder dir is created inside the story
# workspace so the bind has a mountpoint within the workspaceMount; it stays
# empty on the host (the bind overlays the real source at container runtime), so
# disposing the workspace never touches the host source directory.
$HostMountBinds = ''
# find(1) prune expression injected into post-create.sh's node_modules chown so
# that scan stays out of the bind-mounted host dirs. Empty when there are none.
$HostMountPrune = ''
if ($HostMountRepos.Count -gt 0) {
    $pruneParts = @()
    foreach ($repo in $HostMountRepos) {
        New-Item -ItemType Directory -Path (Join-Path $WsDir $repo) -Force | Out-Null
        $srcPosix = ConvertTo-DockerPath (Join-Path $SourceWs $repo)
        $HostMountBinds += "        ,`"source=$srcPosix,target=$WorkspacePath/$repo,type=bind,consistency=cached`"`n"
        $pruneParts += "-path $WorkspacePath/$repo"
    }
    $HostMountPrune = '\( ' + ($pruneParts -join ' -o ') + ' \) -prune -o '
}

# ============================================================================
# Workspace content: Claude, README, .idea
# ============================================================================

# Carry CLAUDE.md and .claude into the new workspace so Claude Code has the same
# project-level context as the source workspace.
if (Test-Path -LiteralPath (Join-Path $SourceWs 'CLAUDE.md')) {
    Copy-Item -LiteralPath (Join-Path $SourceWs 'CLAUDE.md') -Destination $WsDir -Force
}
if (Test-Path -LiteralPath (Join-Path $SourceWs '.claude')) {
    Copy-Item -LiteralPath (Join-Path $SourceWs '.claude') -Destination $WsDir -Recurse -Force
}

# Share the project-level Claude skills directory back to the SOURCE workspace
# instead of leaving it as the one-time copy above: a devcontainer bind mount
# overlays .claude/skills onto <SourceWs>/.claude/skills at runtime, so skills an
# agent creates or edits in one story container are immediately visible to every
# other container and to the base workspace. Pre-create both the bind source and
# the mountpoint so Docker doesn't materialise them as root-owned dirs.
New-Item -ItemType Directory -Path (Join-Path $SourceWs '.claude\skills') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $WsDir '.claude\skills') -Force | Out-Null

# Project-local Claude Code overrides that ONLY apply inside this devcontainer.
# permissions.defaultMode=bypassPermissions skips approval prompts: the container
# is a sandbox and all tool calls go through it, so loosening permissions here
# doesn't loosen anything on the host. settings.local.json is the per-machine
# override layer, so settings.json from the source workspace stays untouched.
Write-LfFile -Path (Join-Path $WsDir '.claude\settings.local.json') -Content @'
{
    "permissions": {
        "defaultMode": "bypassPermissions"
    }
}
'@

# Welcome file at the workspace root. Named README.md (not WELCOME.md) so
# IntelliJ's "open project README on first open" heuristic targets THIS file
# instead of descending into the imported Maven modules. Content lives in
# README.md.tpl next to this script; edit it there to customise the welcome text.
# __PORT_TABLE_ROWS__ is multi-line, so it is spliced in here; the remaining
# __*__ tokens are handled by Update-Placeholders below.
# $readmeTpl was resolved and validated up-front (preflight), so just render it.
Write-LfFile -Path (Join-Path $WsDir 'README.md') `
             -Content ((Read-TextFile $readmeTpl).Replace('__PORT_TABLE_ROWS__', $PortTableRows))

# Pre-seed IntelliJ workspace state: pin the Terminal's start directory to the
# workspace root, otherwise IntelliJ picks one of the imported Maven modules.
# We deliberately do NOT touch the auto-README opener -- we WANT it to fire,
# because the README.md written above sits at the project basePath, which the
# heuristic prefers over module-level READMEs.
New-Item -ItemType Directory -Path (Join-Path $WsDir '.idea') -Force | Out-Null
# Optionally pin the terminal's login shell. Without myShellPath JetBrains
# auto-detects one and prefers zsh when present (the base image ships oh-my-zsh
# via common-utils) even though vscode's login shell is /bin/bash. When
# terminalShell is set we splice a second <option> onto the same line as
# myStartingDirectory; the value carries its own leading newline + indent, so an
# unset terminalShell leaves that line byte-identical to before.
$TerminalShellOption = ''
if (-not [string]::IsNullOrWhiteSpace($cfg.TerminalShell)) {
    $TerminalShellOption = "`n        <option name=""myShellPath"" value=""$($cfg.TerminalShell)"" />"
}
Write-LfFile -Path (Join-Path $WsDir '.idea\workspace.xml') -Content (@'
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
'@).Replace('__TERMINAL_SHELL_OPTION__', $TerminalShellOption)

# Give IntelliJ a distinctive project name. It reads .idea/.name and uses it for
# the window title, the workspace selector and the task-switcher entry.
Write-LfFile -Path (Join-Path $WsDir '.idea\.name') -Content "$ProjectShort $Leaf"

# Build the MavenProjectsManager originalFiles list and the post-create build
# commands at spawn time, so they only contain repos that actually got checked
# out. NO aggregator pom.xml is created at the workspace root: subprojects'
# parent declarations have no explicit <relativePath>, so Maven would falsely
# treat a root pom as their parent and complain on every sync.
$MavenPomsList = ''
$MavenBuildCommands = ''
# Mono-repo default: when no build list is configured and a pom.xml exists at the
# repo root, build the project as a single Maven reactor.
if ($MonoRepo -and $BuildEntries.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $SourceWs 'pom.xml'))) {
    $BuildEntries = @([pscustomobject]@{ Repo = $ProjectName; Value = 'install' })
    $BuildMode = 'maven'
}
foreach ($entry in $BuildEntries) {
    $r = $entry.Repo
    $val = $entry.Value
    if (Test-Path -LiteralPath (Join-Path $WsDir "$r\pom.xml")) {
        $MavenPomsList += "                <option value=`"`$PROJECT_DIR`$/$r/pom.xml`" />`n"
    }
    if ($BuildMode -eq 'raw') {
        # "builds" style: the value is always a raw bash command run verbatim
        # inside the repo dir. No mvn/MVN_FLAGS wrapping.
        $MavenBuildCommands += "[[ -d $r ]] && (cd $r && $val)`n"
    } elseif ($val.StartsWith('$')) {
        # "mavenBuilds" style, raw-command form: a goal starting with '$' is an
        # arbitrary bash command run verbatim inside the repo dir (for repos with
        # no parent pom but several sub-dir poms). MVN_FLAGS is NOT injected.
        $raw = $val.Substring(1).TrimStart()
        $MavenBuildCommands += "[[ -d $r ]] && (cd $r && $raw)`n"
    } else {
        # "mavenBuilds" style, mvn-goal form: inject `mvn ${MVN_FLAGS}`.
        $MavenBuildCommands += "[[ -d $r ]] && (cd $r && mvn `${MVN_FLAGS} $val)`n"
    }
}
$MavenBuildCommands = $MavenBuildCommands.TrimEnd("`n")

Write-LfFile -Path (Join-Path $WsDir '.idea\misc.xml') -Content @"
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
$MavenPomsList            </list>
        </option>
    </component>
    <component name="ProjectRootManager" version="2" languageLevel="JDK_21" default="true" project-jdk-name="21" project-jdk-type="JavaSDK">
        <output url="file://`$PROJECT_DIR`$/out" />
    </component>
</project>
"@

# Enable annotation processing globally so IntelliJ stops asking "Enable
# Lombok?" when opening a Java file with @Data / @Builder / @Slf4j. The default
# profile applies to every module unless an explicit per-module profile exists.
Write-LfFile -Path (Join-Path $WsDir '.idea\compiler.xml') -Content @'
<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
    <component name="CompilerConfiguration">
        <annotationProcessing>
            <profile default="true" name="Default" enabled="true" />
        </annotationProcessing>
    </component>
</project>
'@

# Copy each run-config XML from the project's runConfigurations/ directory into
# the new workspace's .idea/runConfigurations/. The placeholder pass below fills
# in port numbers etc. Filenames come from "runConfigs" in devcontainers-config.json.
# $runConfigSrcDir and the existence of every entry were already resolved and
# validated up-front (before any mutation), so here we only copy.
New-Item -ItemType Directory -Path (Join-Path $WsDir '.idea\runConfigurations') -Force | Out-Null
foreach ($rcFile in $cfg.RunConfigs) {
    $src = Join-Path $runConfigSrcDir $rcFile
    Copy-Item -LiteralPath $src -Destination (Join-Path $WsDir ".idea\runConfigurations\$rcFile") -Force
}

# ============================================================================
# Host integration paths
# ============================================================================

# Bind targets have to exist on the host before the container starts, otherwise
# Docker materialises them as root-owned directories on first mount. The Bash
# script does this in devcontainer.json's initializeCommand; on Windows that
# command would run through cmd.exe, so we prepare everything here instead.
$SharedMemoryDir = Join-Path $HomeDir ".claude\projects\$SharedMemoryKey\memory"
foreach ($d in (Join-Path $HomeDir '.m2'), (Join-Path $HomeDir '.ssh'),
                (Join-Path $HomeDir '.claude'), $SharedMemoryDir,
                (Join-Path $HomeDir '.copilot\skills'), (Join-Path $HomeDir '.copilot\instructions'),
                (Join-Path $HomeDir '.copilot\prompts')) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
$ClaudeJson = Join-Path $HomeDir '.claude.json'
if (-not (Test-Path -LiteralPath $ClaudeJson)) { New-Item -ItemType File -Path $ClaudeJson -Force | Out-Null }

# glab is written in Go and uses os.UserConfigDir(), which returns a different
# path per OS: %AppData%\glab-cli on Windows, ~/Library/Application Support/
# glab-cli on macOS, ~/.config/glab-cli on Linux. Inside the container (Linux)
# glab looks at ~/.config/glab-cli, so we map the host's ACTUAL directory onto
# that target and the same config.yml flows between host and container.
# Fallback: create the Windows-style path as a stub so the mount has a valid
# source; 'glab auth login' then populates it through the bind.
$GlabConfigSrc = ''
if ($GlabEnabled) {
    $candidates = @()
    if ($env:APPDATA) { $candidates += (Join-Path $env:APPDATA 'glab-cli') }
    $candidates += (Join-Path $HomeDir '.config\glab-cli')
    $GlabConfigSrc = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
    if (-not $GlabConfigSrc) {
        $GlabConfigSrc = $candidates[0]
        New-Item -ItemType Directory -Path $GlabConfigSrc -Force | Out-Null
        Write-Output "note: no host glab config found, created stub at $GlabConfigSrc"
        Write-Output "      run 'glab auth login --hostname $($cfg.GlabHostname)' (host or container) to populate"
    }
    Write-Output "glab config source: $GlabConfigSrc"
} else {
    Write-Output 'glab integration: disabled (glabHostname and/or glabVersion empty in devcontainers-config.json)'
}

# gh (GitHub CLI) stores hosts.yml (the github.com auth token) in
# %AppData%\GitHub CLI on Windows and ~/.config/gh elsewhere; the container
# always reads ~/.config/gh. Same bidirectional-sharing idea as glab above.
$GhConfigSrc = ''
if ($GhEnabled) {
    $candidates = @()
    if ($env:APPDATA) { $candidates += (Join-Path $env:APPDATA 'GitHub CLI') }
    $candidates += (Join-Path $HomeDir '.config\gh')
    $GhConfigSrc = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
    if (-not $GhConfigSrc) {
        $GhConfigSrc = $candidates[0]
        New-Item -ItemType Directory -Path $GhConfigSrc -Force | Out-Null
        Write-Output "note: no host gh config found, created stub at $GhConfigSrc"
        Write-Output "      run 'gh auth login' (host or container) to populate"
    }
    Write-Output "gh config source: $GhConfigSrc"
} else {
    Write-Output 'gh integration: disabled (ghVersion empty in devcontainers-config.json)'
}

# SSH-agent forwarding so key-based remotes (git@<host>:...) don't prompt for the
# key passphrase on every operation. Docker Desktop exposes the host agent at the
# magic socket /run/host-services/ssh-auth.sock. On Windows the host side of that
# bridge is the "OpenSSH Authentication Agent" service; if it isn't running there
# is nothing to forward, so the mount and SSH_AUTH_SOCK are omitted entirely and
# ssh behaves as it does today (prompting for the passphrase).
$SshAgentSrc = '/run/host-services/ssh-auth.sock'
$SshAgentEnabled = $false
try {
    $svc = Get-Service -Name 'ssh-agent' -ErrorAction Stop
    $SshAgentEnabled = ($svc.Status -eq 'Running')
} catch {
    $SshAgentEnabled = $false
}
if ($SshAgentEnabled) {
    Write-Output "ssh agent source: $SshAgentSrc (Windows OpenSSH Authentication Agent is running)"
} else {
    Write-Output "ssh agent:        not forwarded (Windows service 'ssh-agent' is not running)"
    Write-Output "                  start it with: Start-Service ssh-agent   (needs admin once: Set-Service ssh-agent -StartupType Automatic)"
}

# Host IANA timezone -> container TZ env var so Spring Boot (and every other
# JVM/tool) logs in the local timezone instead of the UTC default that ships
# with the devcontainer base image. Java's TimeZone.getDefault() honours $TZ
# first, so setting it at PID 1 (containerEnv) is the least invasive option.
$HostTz = Get-HostIanaTimeZone
Write-Output "host timezone:    $HostTz"

New-Item -ItemType Directory -Path (Join-Path $WsDir '.devcontainer') -Force | Out-Null

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
if ($CaEnabled) {
    $certDir = Join-Path $WsDir '.devcontainer\certs'
    New-Item -ItemType Directory -Path $certDir -Force | Out-Null
    foreach ($ca in $cfg.ProxyCaCerts) {
        $caSrc = $ca
        if (-not [System.IO.Path]::IsPathRooted($caSrc)) { $caSrc = Join-Path $ConfigDir $caSrc }
        Copy-Item -LiteralPath $caSrc -Destination (Join-Path $certDir (Split-Path -Leaf $caSrc)) -Force
        Write-Output "ca certificate: $(Split-Path -Leaf $caSrc)"
    }
}

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
if ($IsRocky) {
    $rockyRepoDir = Join-Path $WsDir '.devcontainer\rocky-repos'
    New-Item -ItemType Directory -Path $rockyRepoDir -Force | Out-Null
    Write-LfFile -Path (Join-Path $rockyRepoDir 'rocky-9.repo') -Content @'
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
'@
    Write-LfFile -Path (Join-Path $rockyRepoDir 'docker-ce-9.repo') -Content @'
[docker-ce-9-stable]
name=docker-ce-9-stable Repository
baseurl=https://repos.ads.dmz/docker-ce-9/docker-ce-9-stable
enabled=1
gpgcheck=0
sslverify=0
'@
    Write-Output 'rocky repos:      baseos/appstream/devel/docker-ce via repos.ads.dmz (internal mirror)'
}

# Proxy JSON fragments for devcontainer.json. Both build args (used while the
# image is built) and containerEnv (used by post-create's npm/Maven runs and by
# anything the developer runs later) are emitted, in upper- and lowercase
# spelling because tools disagree about which they read.
$ProxyBuildArgs = ''
$ProxyContainerEnv = ''
if ($ProxyEnabled) {
    $pHttp = if ($cfg.ProxyHttp) { $cfg.ProxyHttp } else { $cfg.ProxyHttps }
    $pHttps = if ($cfg.ProxyHttps) { $cfg.ProxyHttps } else { $cfg.ProxyHttp }
    # A hashtable is out: PowerShell keys are case-insensitive, so HTTP_PROXY and
    # http_proxy would collide -- yet both spellings must reach the container,
    # because tools disagree about which one they read.
    $pairs = @(
        @('HTTP_PROXY',  $pHttp),
        @('HTTPS_PROXY', $pHttps),
        @('http_proxy',  $pHttp),
        @('https_proxy', $pHttps)
    )
    if ($cfg.ProxyNoProxy) {
        $pairs += , @('NO_PROXY', $cfg.ProxyNoProxy)
        $pairs += , @('no_proxy', $cfg.ProxyNoProxy)
    }
    $ProxyBuildArgs = (@($pairs | ForEach-Object { "`"$($_[0])`": `"$($_[1])`"" })) -join ', '
    $ProxyContainerEnv = ', ' + $ProxyBuildArgs
    $noProxyLabel = if ($cfg.ProxyNoProxy) { $cfg.ProxyNoProxy } else { '<none>' }
    Write-Output "proxy:            $pHttps (no_proxy: $noProxyLabel)"
}

# Resolve the host's ~/.npmrc into the workspace so post-create.sh can copy it to
# /home/vscode/.npmrc inside the container. Bind-mounting the host file directly
# proved unreliable in JetBrains' devcontainer setup, so it travels through the
# workspace bind instead. Two transformations:
#   1. Drop lines carrying host-absolute paths (Windows drive paths or
#      /Users/... from a shared dotfiles repo) -- they break npm on Linux.
#   2. Substitute ${TOKEN} placeholders for every forwarded env var with this
#      shell's value, so the resolved npmrc holds literal tokens. That is the
#      reliable path for getting auth into the container; remoteEnv forwarding
#      works unevenly across IntelliJ launch contexts.
# The resolved file holds tokens in plaintext under the story workspace dir.
# That's acceptable for a personal dev workspace, but never share the directory.
if (Test-Path -LiteralPath $HostNpmrc -PathType Leaf) {
    $npmrcLines = [System.IO.File]::ReadAllLines($HostNpmrc)
    $resolved = foreach ($line in $npmrcLines) {
        $l = $line
        foreach ($var in $cfg.ForwardedEnvVars) {
            $value = [Environment]::GetEnvironmentVariable($var)
            if ($null -eq $value) { $value = '' }
            $l = $l.Replace('${' + $var + '}', $value)
        }
        if ($l -match '/Users/' -or $l -match '\b[A-Za-z]:[\\/]') { continue }
        $l
    }
    Write-LfFile -Path (Join-Path $WsDir '.devcontainer\host-npmrc.resolved') -Content (($resolved) -join "`n")
    Write-Output 'wrote .devcontainer/host-npmrc.resolved (tokens substituted from this shell)'
} else {
    Write-Output 'note: no ~/.npmrc on host -- npm in the container will use defaults only'
}

# ============================================================================
# .devcontainer templates
# ============================================================================

# Custom Dockerfile so we can patch the base image *before* devcontainer features
# run. The MS Java base image carries an apt source for the Yarn Debian repo
# whose signing key is expired, which makes every subsequent apt-get update
# inside any feature install fail with exit code 100. We don't need Yarn (Node +
# npm come from the node feature), so the dead repo is simply dropped.
#
# The template covers BOTH supported distro families. Everything that differs
# sits in __DEB_BLOCK_*__ / __RPM_BLOCK_*__ markers, and Update-Placeholders
# keeps exactly one side depending on "distro" in devcontainers-config.json. On the rocky side
# the Dockerfile additionally has to do the whole job of the devcontainer
# features (user, JDK, Maven, Node, docker-ce), which are Debian/Ubuntu-only.
Write-LfFile -Path (Join-Path $WsDir '.devcontainer\Dockerfile') -Content @'
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
# linux-arm64 build: on arm64 hosts it downloads the x86-64 binary, which
# Docker Desktop can only run if the image ships the x86 ELF loader
# (/lib64/ld-linux-x86-64.so.2). The MS arm64 base image doesn't, so a render
# dies with "rosetta error: failed to open elf at /lib64/ld-linux-x86-64.so.2".
# Fix: install the distro's native Chromium and point Puppeteer at it, skipping
# its own download entirely.
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
# glab (GitLab CLI). Pinned to a known-good version; bump glabVersion in devcontainers-config.json.
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
# gh (GitHub CLI). Pinned to a known-good version; bump ghVersion in devcontainers-config.json.
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
'@

Write-LfFile -Path (Join-Path $WsDir '.devcontainer\devcontainer.json') -Content @'
{
    "name": "__WS_NAME__",
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

    // The story workspace and the source workspace are mounted as SIBLINGS under
    // /workspaces, mirroring their layout on the Windows host. That is what makes
    // the relative git-worktree links written by spawn-workspace.ps1 resolve both
    // here and on the host. All bind sources are fully resolved Windows paths in
    // forward-slash form, so no ${localEnv:...} / ${localWorkspaceFolder}
    // expansion has to behave a particular way on Windows.
    "workspaceFolder": "__WORKSPACE_PATH__",
    "workspaceMount": "source=__WS_DIR_HOST__,target=__WORKSPACE_PATH__,type=bind,consistency=cached",

    // No "initializeCommand": spawn-workspace.ps1 creates every host-side bind
    // target itself (the Bash version uses a POSIX one-liner here, which would
    // run through cmd.exe on Windows).

    // Mount order matters: deeper paths must come AFTER their parents so they take
    // precedence. The layering is:
    //   1. ~/.claude               -> shared by default (login, agents, commands, ...)
    //   2. named volume per story  -> overrides per-project state (history, todos)
    //   3. shared memory bind      -> overrides only the memory/ subfolder back to shared
    "mounts": [
        // Source workspace. A worktree's .git file points at
        //   ../../<PROJECT_NAME>/<repo>/.git/worktrees/<name>
        // so the source repos must be reachable next to the story workspace;
        // without this mount git reports "not a git repository" for every
        // worktree, the 'branches' helper shows '?', and IntelliJ/Maven get
        // confused about the module structure.
        "source=__SOURCE_WS_HOST__,target=__SOURCE_WS__,type=bind",

        // Project-level Claude skills are shared back to the SOURCE workspace so
        // that skills created or edited by an agent inside one story container
        // are immediately available to every other container and to the base
        // workspace. Without this the workspace .claude/ is only a one-time copy,
        // so skill changes would stay trapped in the container. This deeper bind
        // overlays ONLY the skills/ subfolder on top of the workspaceMount.
        "source=__SOURCE_WS_HOST__/.claude/skills,target=__WORKSPACE_PATH__/.claude/skills,type=bind",

        "source=__HOME_HOST__/.ssh,target=/home/vscode/.ssh,type=bind,readonly",
        "source=__HOME_HOST__/.m2,target=/home/vscode/.m2,type=bind",
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
        // login' run in either place persists to the same config.yml. The source
        // path is OS-specific on the host (Windows: %AppData%\glab-cli) and
        // resolved by spawn-workspace.ps1; the target is always the linux-style
        // path that glab looks at inside the container.
        "source=__GLAB_CONFIG_SRC__,target=/home/vscode/.config/glab-cli,type=bind",
        // __GLAB_BLOCK_END__
        // __GH_BLOCK_START__
        // gh (GitHub CLI) config: hosts.yml holds the github.com auth token.
        // Bind-mounted rw so 'gh auth login' run on the host or in the container
        // persists to the same file. Windows keeps it in %AppData%\GitHub CLI.
        "source=__GH_CONFIG_SRC__,target=/home/vscode/.config/gh,type=bind",
        // __GH_BLOCK_END__
        // __SSHAGENT_BLOCK_START__
        // SSH-agent socket forwarding: the host's ssh-agent (with cached
        // passphrase-protected keys) is reachable inside the container at
        // /ssh-agent through Docker Desktop's magic socket. Only emitted when the
        // Windows "OpenSSH Authentication Agent" service is running.
        "source=__SSH_AGENT_SRC__,target=/ssh-agent,type=bind",
        // __SSHAGENT_BLOCK_END__
        "source=__HOME_HOST__/.claude.json,target=/home/vscode/.claude.json,type=bind",
        "source=__HOME_HOST__/.claude,target=/home/vscode/.claude,type=bind",
        "source=__PROJECT_SHORT__-claude-project-${devcontainerId},target=/home/vscode/.claude/projects/__MEMORY_KEY__,type=volume",
        // Memory lives in ONE host folder keyed by the PROJECT (not the story),
        // mounted onto this story's project key. Result: memory is shared across
        // all story containers -- including ones spawned from macOS/Linux, which
        // use the very same host folder -- while the conversation history in the
        // named volume above stays per-story.
        "source=__HOME_HOST__/.claude/projects/__SHARED_MEMORY_KEY__/memory,target=/home/vscode/.claude/projects/__MEMORY_KEY__/memory,type=bind",
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
        "source=__HOME_HOST__/.copilot/skills,target=/home/vscode/.copilot/skills,type=bind",
        "source=__HOME_HOST__/.copilot/instructions,target=/home/vscode/.copilot/instructions,type=bind",
        "source=__HOME_HOST__/.copilot/prompts,target=/home/vscode/.copilot/prompts,type=bind"
        // host-mounted repos: entries in "repos" with an empty base ref are plain
        // host directories (not git worktrees), bind-mounted straight in at
        // their workspace path. Generated by spawn-workspace.ps1.
__HOST_MOUNT_BINDS__
        // node_modules volumes: one Docker named volume per npm module. These are
        // generated by spawn-workspace.ps1 from the package.json files found in
        // the workspace. Named volumes bypass the host<->VM bind-mount bridge,
        // eliminating the I/O bottleneck that makes npm 10-100x slower.
        // dispose-workspace.ps1 removes them automatically.
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
        // __SSHAGENT_BLOCK_START__
        // Tell ssh inside the container where to find the agent socket
        // (forwarded from the host via the mount above). Result: ssh uses
        // the host's already-unlocked key for git over SSH without ever
        // prompting for the passphrase.
        "SSH_AUTH_SOCK": "/ssh-agent",
        // __SSHAGENT_BLOCK_END__
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
    // - forwardedEnvVars from devcontainers-config.json: forwarded from the host so that any
    //   '${TOKEN}'-style placeholder in the user's ~/.npmrc / ~/.m2/settings.xml
    //   resolves inside the container. Otherwise npm install of private
    //   packages and Maven resolution from private repos fail with 401.
    //   These read from the env that LAUNCHED IntelliJ (or that ran
    //   spawn-workspace.ps1).
    "remoteEnv": {
        "JAVA_HOME": "__JAVA_HOME__"__REMOTE_ENV_FORWARDED__
    },

    // Port labels for the JetBrains Services view. Keys are the container-side
    // port numbers; the host-side port comes from runArgs -p above. Suppress
    // the auto-forward notification that pops up every time a service starts.
    // Labels come from "hostPorts" in devcontainers-config.json.
    "portsAttributes": {
        __PORTS_ATTRS__
    },

    // Make the IDE wait for postCreateCommand (Maven builds, npm install)
    // before attaching. Default 'updateContentCommand' lets JetBrains open
    // the project window while postCreate is still running, which makes the
    // initial reactor look empty until Maven catches up.
    "waitFor": "postCreateCommand",

    // Invoked through 'bash' rather than relying on the executable bit: the
    // scripts live on an NTFS bind mount, which carries no POSIX permissions.
    "postCreateCommand": "bash __WORKSPACE_PATH__/.devcontainer/post-create.sh",

    // Re-runs every time the container starts (postCreate runs only once).
    // Used to kick dockerd: the docker-in-docker feature installs an init
    // script meant to run as the container's entrypoint, but JetBrains
    // Gateway overrides the entrypoint, so the daemon doesn't auto-start
    // and Testcontainers fails with "no Docker environment found".
    "postStartCommand": "bash __WORKSPACE_PATH__/.devcontainer/post-start.sh",

    "customizations": {
        "jetbrains": {
            "backend": "IntelliJ",
            // Gateway pre-installs these into the remote backend on first connect.
            //   - Docker (id: "Docker"): the full marketplace Docker plugin.
            //     Gateway's own bundled backend only ships "clouds-docker-gateway"
            //     (a stripped bridge that handles the Services view) WITHOUT the
            //     compose content-module -- so compose.yaml gets no file-type
            //     registration, no gutter Play buttons, and no "Docker Compose"
            //     entry under Run -> Edit Configurations -> +. Installing the
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
                // IDE, no Maven subprocess, no Eel layer.
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
'@

Write-LfFile -Path (Join-Path $WsDir '.devcontainer\post-create.sh') -Content @'
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

# Copy the resolved npmrc that spawn-workspace.ps1 produced. It already has
# host-absolute paths stripped and any forwarded token placeholders substituted
# with values from the spawn shell, so npm in the container can auth against
# private registries.
RESOLVED_NPMRC=__WORKSPACE_PATH__/.devcontainer/host-npmrc.resolved
if [[ -f "${RESOLVED_NPMRC}" ]]; then
    install -m 600 "${RESOLVED_NPMRC}" /home/vscode/.npmrc
    echo "npmrc installed from ${RESOLVED_NPMRC}"
else
    echo "WARN: ${RESOLVED_NPMRC} not found -- npm install of private packages will 401" >&2
fi

# install Claude Code globally â€” via login shell so npm/node from the Node feature
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
# (x86-only) Chrome download and the CLI uses the system chromium via
# PUPPETEER_EXECUTABLE_PATH at render time.
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
# UID on the files. Host-mounted volumes appear with a foreign UID inside the
# container; if that doesn't match the vscode user, git refuses with
# "fatal: detected dubious ownership in repository". System-wide config so it
# applies to all users in the container.
sudo git config --system --add safe.directory '*'

# __GLAB_BLOCK_START__
# Use glab as git's credential helper for HTTPS pushes to the configured
# GitLab host (glabHostname from devcontainers-config.json). glab is installed in the image
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
# See the post-create.sh block in the spawn scripts for the why.
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

# Align git's working-tree heuristics with the host so the bind-mounted
# worktree doesn't look "dirty" inside the container.
#
# core.fileMode=false: Docker Desktop bind mounts report different executable
# bits than the host filesystem does. With the Linux default (true) git treats
# those flips as file modifications, which during 'git rebase -i squash'
# surfaces as "Your local changes would be overwritten" even though the content
# is identical.
#
# core.autocrlf=input: matches the setting the spawn script writes into each
# source repo. With a mismatch, git in the container would convert line endings
# on checkout that the host left alone (or vice versa), making the same checkout
# look modified depending on which side last touched it.
git config --global core.fileMode false
git config --global core.autocrlf input

# Bind-mount stat-cache drift: Docker Desktop reports different mtime
# nanoseconds / ctime / inode for the same file depending on whether the
# host or the container accessed it last. Git's default stat check (size +
# mtime-ns + ctime + inode) then flags "modified" mid-rebase even when the
# content is identical. 'git status' silently refreshes the stat cache so the
# tree looks clean from the prompt, but rebase sub-steps (merge-recursive) do
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
# JetBrains' terminal opens an SSH-style channel that forwards the client
# terminal's locale (LC_CTYPE=UTF-8 -- glibc rejects this format with
# "manpath: can't set the locale") AFTER PID-1 env is applied, shadowing our
# LC_ALL. So we also write to two shell-rc layers:
#   - /etc/profile.d/zz-<projectShort>-env.sh : sourced by login shells via /etc/profile
#   - __SYSTEM_BASHRC__ append                : sourced by interactive non-login
#                                               bashes (JetBrains' terminal
#                                               usually is one)
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
# isn't installed via SDKMAN. Also blocks SSH forwarding of LC_CTYPE=UTF-8
# which glibc can't parse, and ensures DOCKER_API_VERSION is set even for
# IDE-spawned shells that don't go through /etc/profile.
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
# Each npm module's node_modules is mounted as a named volume so npm writes at
# Linux-native speed instead of through the slow host bind-mount. A freshly
# created named volume is owned by root:root, though, so npm running as vscode
# during the Maven warmup below can't write into it and dies with
#   EACCES: permission denied, mkdir '.../node_modules/@types'
# chown each mount-point to vscode up front. The find mirrors the module
# discovery in the spawn script (package.json outside node_modules/.git), so
# it stays in sync with the volumes actually mounted. Non-recursive is enough:
# npm creates everything below once it owns the mount root.
# The prune expression spliced in below (may be empty) skips any host-mounted
# repo dirs: they carry no named-volume node_modules, and chowning anything
# inside them would rewrite ownership of the bind-mounted HOST files. The `if`
# (not `&&`) keeps a module without a node_modules dir from making the loop --
# and thus the whole pipeline under `set -e`/`pipefail` -- exit non-zero.
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
# the spawn scripts in dev-containers/; they copy it here. Runs with the
# workspace root as CWD, before the Maven warmup builds.
if [[ -f .devcontainer/initialize.sh ]]; then
    echo "--- running initialize.sh ---"
    bash .devcontainer/initialize.sh
fi

# Resolve build dependencies in order ("builds" / "mavenBuilds" in devcontainers-config.json).
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
'@

# MAVEN_BUILD_COMMANDS and HOST_MOUNT_PRUNE are multi-line / may be empty, so
# they are spliced in before the generic placeholder pass runs.
$postCreatePath = Join-Path $WsDir '.devcontainer\post-create.sh'
$pc = (Read-TextFile $postCreatePath).
        Replace('__MAVEN_BUILD_COMMANDS__', $MavenBuildCommands).
        Replace('__HOST_MOUNT_PRUNE__', $HostMountPrune)
Write-LfFile -Path $postCreatePath -Content $pc

# Copy the optional initialization hook into the workspace's .devcontainer/.
# post-create.sh runs it before the Maven warmup builds if present.
$initHook = Get-ConfigAsset 'initialize.sh'
if ($initHook) {
    Write-LfFile -Path (Join-Path $WsDir '.devcontainer\initialize.sh') -Content (Read-TextFile $initHook)
}

Write-LfFile -Path (Join-Path $WsDir '.devcontainer\post-start.sh') -Content @'
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
# config dir. Safe write saves via write-tmp + rename, which on Docker bind
# mounts produces a new inode + ctime drift that IntelliJ's external-change
# detector reads as "someone else touched the file" -> "file was changed
# externally" dialog right after every save. Disabling it makes the editor
# write the file in place (open+truncate+write), preserving the inode.
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
# Publishing: the spawn scripts only map the ports listed in "hostPorts"
# (devcontainers-config.json) via 'docker run -p'. Add 2222 there so this sshd is reachable
# from the host at 2222+offset. Without that entry sshd still runs but is only
# reachable from inside the container.
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
'@

# ============================================================================
# Placeholder substitution
# ============================================================================

# JSON fragment for the forwarded remoteEnv vars (leading comma + one key each).
# An empty list yields an empty snippet, which leaves the JSON valid.
$RemoteEnvForwarded = ''
foreach ($var in $cfg.ForwardedEnvVars) {
    $RemoteEnvForwarded += ", `"$var`": `"`${localEnv:$var}`""
}

# Same vars, ALSO baked into containerEnv (not just remoteEnv). remoteEnv is
# resolved per remote-launched process and, per the DOCKER_API_VERSION comment
# above, some IntelliJ launch paths (run configs, background tasks) bypass it
# entirely. containerEnv is set once at container-create time and reaches
# every process unconditionally, so private-registry tokens referenced by
# in-repo '${TOKEN}'-style .npmrc/.settings.xml files (not just the HOME
# ~/.npmrc that spawn-workspace resolves itself) still work when npm/Maven is
# invoked from a context remoteEnv doesn't cover.
$ContainerEnvForwarded = ''
foreach ($var in $cfg.ForwardedEnvVars) {
    $ContainerEnvForwarded += ", `"$var`": `"`${localEnv:$var}`""
}

# portsAttributes entries from the labelled host ports. Joined with commas; no
# trailing comma (JSON forbids it).
$PortsAttrs = (@($cfg.HostPorts | Where-Object { $_.Label } | ForEach-Object {
    "`"$($_.Port)`": { `"label`": `"$($_.Label)`", `"onAutoForward`": `"silent`" }"
})) -join ', '

# Echo back the --config flag in the hints only when the user actually passed
# one; without it the default lookup finds the same config anyway.
$ConfigHint = ''
if ($ConfigCli) { $ConfigHint = "--config `"$ConfigPath`" " }

$Tokens = [ordered]@{
    '__WS_NAME__'              = $WsName
    '__LEAF__'                 = $Leaf
    '__PROJECT_NAME__'         = $ProjectName
    '__PROJECT_SHORT__'        = $ProjectShort
    '__PORT_RUNARGS__'         = $PortRunArgs
    '__WORKSPACE_PATH__'       = $WorkspacePath
    '__SOURCE_WS__'            = $SourceWsContainer
    '__WS_DIR_HOST__'          = (ConvertTo-DockerPath $WsDir)
    '__SOURCE_WS_HOST__'       = (ConvertTo-DockerPath $SourceWs)
    '__HOME_HOST__'            = (ConvertTo-DockerPath $HomeDir)
    '__MEMORY_KEY__'           = $MemoryKey
    '__SHARED_MEMORY_KEY__'    = $SharedMemoryKey
    '__BASE_IMAGE__'           = $cfg.BaseImage
    '__NODE_FEATURE_VERSION__' = $cfg.NodeFeatureVersion
    '__GLAB_VERSION__'         = $cfg.GlabVersion
    '__GLAB_HOSTNAME__'        = $cfg.GlabHostname
    '__GH_VERSION__'           = $cfg.GhVersion
    '__REMOTE_ENV_FORWARDED__' = $RemoteEnvForwarded
    '__CONTAINER_ENV_FORWARDED__' = $ContainerEnvForwarded
    '__PORTS_ATTRS__'          = $PortsAttrs
    '__GLAB_CONFIG_SRC__'      = (ConvertTo-DockerPath $GlabConfigSrc)
    '__GH_CONFIG_SRC__'        = (ConvertTo-DockerPath $GhConfigSrc)
    '__SSH_AGENT_SRC__'        = $SshAgentSrc
    '__HOST_TZ__'              = $HostTz
    '__PORT_OFFSET__'          = "$PortOffset"
    '__SSH_HOST_PORT__'        = "$SshHostPort"
    '__FIRST_REPO__'           = $FirstRepo
    '__SPAWN_CMD__'            = 'spawn-workspace.ps1'
    '__DISPOSE_CMD__'          = ("dispose-workspace.ps1 $ConfigHint").TrimEnd()
    '__PROXY_BUILD_ARGS__'     = $ProxyBuildArgs
    '__PROXY_CONTAINER_ENV__'  = $ProxyContainerEnv
    '__FEATURE_REGISTRY__'     = $cfg.FeatureRegistry
    '__JAVA_HOME__'            = $JavaHome
    '__SYSTEM_BASHRC__'        = $SystemBashrc
    '__JAVA_VERSION__'         = $cfg.JavaVersion
    '__MAVEN_VERSION__'        = $cfg.MavenVersion
}
foreach ($k in $PortTokens.Keys) { $Tokens[$k] = $PortTokens[$k] }

# Conditional blocks marked with __<NAME>_BLOCK_START__ ... __<NAME>_BLOCK_END__
# in the templates: when the feature is enabled, only the marker lines are
# stripped (content kept); when it is disabled, the markers AND everything
# between them are dropped, so the generated file carries no trace of it.
function Remove-ConditionalBlock {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][bool] $Enabled
    )
    $lines = $Text -split "`n"
    $out = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($line in $lines) {
        if ($line -match "__${Name}_BLOCK_START__") { $inBlock = $true; continue }
        if ($line -match "__${Name}_BLOCK_END__") { $inBlock = $false; continue }
        if ($inBlock -and -not $Enabled) { continue }
        $out.Add($line)
    }
    return ($out -join "`n")
}

function Update-Placeholders {
    param([Parameter(Mandatory = $true)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $text = Read-TextFile $Path
    foreach ($k in $Tokens.Keys) {
        $v = $Tokens[$k]
        if ($null -eq $v) { $v = '' }
        $text = $text.Replace($k, [string]$v)
    }
    $text = Remove-ConditionalBlock -Text $text -Name 'GLAB' -Enabled $GlabEnabled
    $text = Remove-ConditionalBlock -Text $text -Name 'GH' -Enabled $GhEnabled
    $text = Remove-ConditionalBlock -Text $text -Name 'SSHAGENT' -Enabled $SshAgentEnabled
    # Corporate-proxy blocks. Each is independent: a project may need only the CA
    # certificates (proxy configured globally in Docker Desktop), only the proxy
    # URLs, or all three.
    $text = Remove-ConditionalBlock -Text $text -Name 'PROXY' -Enabled $ProxyEnabled
    $text = Remove-ConditionalBlock -Text $text -Name 'CA' -Enabled $CaEnabled
    $text = Remove-ConditionalBlock -Text $text -Name 'APT_HTTPS' -Enabled $AptHttpsEnabled
    $text = Remove-ConditionalBlock -Text $text -Name 'APT_PKGS' -Enabled $AptPkgsEnabled
    $text = Remove-ConditionalBlock -Text $text -Name 'RECENT_GIT' -Enabled $RecentGitEnabled
    $text = Remove-ConditionalBlock -Text $text -Name 'CHROMIUM' -Enabled $ChromiumEnabled
    # Distro split. MUST run last: the DEB/RPM markers are nested INSIDE several
    # of the blocks above (CA, APT_HTTPS, APT_PKGS, RECENT_GIT, CHROMIUM), and
    # Remove-ConditionalBlock has no nesting depth counter -- it relies on the
    # outer block being resolved first. Exactly one of the two survives.
    $text = Remove-ConditionalBlock -Text $text -Name 'DEB' -Enabled $DebianEnabled
    $text = Remove-ConditionalBlock -Text $text -Name 'RPM' -Enabled $IsRocky
    Write-LfFile -Path $Path -Content $text
}

# The multi-line mount fragments are spliced into devcontainer.json first
# (an empty fragment simply removes the placeholder line), then the generic
# token pass runs over every generated file.
$dcPath = Join-Path $WsDir '.devcontainer\devcontainer.json'
$dcText = (Read-TextFile $dcPath).
            Replace("__HOST_MOUNT_BINDS__`n", $HostMountBinds).
            Replace('__HOST_MOUNT_BINDS__', $HostMountBinds.TrimEnd("`n")).
            Replace("__NPM_NM_VOLUME_MOUNTS__`n", $NpmVolumeMounts).
            Replace('__NPM_NM_VOLUME_MOUNTS__', $NpmVolumeMounts.TrimEnd("`n"))
Write-LfFile -Path $dcPath -Content $dcText

Update-Placeholders -Path $dcPath
Update-Placeholders -Path (Join-Path $WsDir '.devcontainer\Dockerfile')
Update-Placeholders -Path (Join-Path $WsDir '.devcontainer\post-create.sh')
Update-Placeholders -Path (Join-Path $WsDir '.devcontainer\post-start.sh')
Update-Placeholders -Path (Join-Path $WsDir 'README.md')
Get-ChildItem -LiteralPath (Join-Path $WsDir '.idea\runConfigurations') -Filter '*.xml' -ErrorAction SilentlyContinue |
    ForEach-Object { Update-Placeholders -Path $_.FullName }

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
$DockerfilePath = Join-Path $WsDir '.devcontainer\Dockerfile'
$CertsDir       = Join-Path $WsDir '.devcontainer\certs'
$RockyRepoDir   = Join-Path $WsDir '.devcontainer\rocky-repos'
$DockerfileText = Read-TextFile $DockerfilePath

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($DockerfileText)
    foreach ($dir in @($CertsDir, $RockyRepoDir)) {
        if (Test-Path -LiteralPath $dir) {
            Get-ChildItem -LiteralPath $dir -File | Sort-Object Name | ForEach-Object {
                [void]$sb.Append("|file:$($_.Name)|")
                [void]$sb.Append((Read-TextFile $_.FullName))
            }
        }
    }
    $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb.ToString()))
} finally {
    $sha.Dispose()
}
$BaseImageHash = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 12).ToLowerInvariant()
$BaseImageTag  = "devcontainer-base:$($cfg.Distro)-$BaseImageHash"

$baseExists = $false
$inspectResult = Invoke-Docker @('image', 'inspect', $BaseImageTag)
if ($inspectResult.ExitCode -eq 0) { $baseExists = $true }

if ($RebuildBaseImage -or -not $baseExists) {
    Write-Output ''
    if ($RebuildBaseImage -and $baseExists) {
        Write-Output "rebuilding base image (--rebuild-base-image): $BaseImageTag"
    } else {
        Write-Output "base image cache miss -- building $BaseImageTag once (subsequent workspaces reuse it)..."
    }
    $dockerBuildArgs = @('build', '-t', $BaseImageTag)
    if ($ProxyEnabled) {
        foreach ($pair in $pairs) {
            $dockerBuildArgs += @('--build-arg', "$($pair[0])=$($pair[1])")
        }
    }
    $dockerBuildArgs += (Join-Path $WsDir '.devcontainer')
    # docker build writes its progress to stderr; with $ErrorActionPreference =
    # 'Stop' (set at the top of this script) PowerShell would turn every one of
    # those lines into a terminating error the instant the call returns. Relax
    # it locally, same pattern Invoke-NativeCapture uses, and check the real
    # exit code via $LASTEXITCODE instead.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker @dockerBuildArgs 2>&1 | ForEach-Object { Write-Output $_ }
        $buildExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousEap
    }
    if ($buildExit -ne 0) {
        Fail "base image build failed ($BaseImageTag) -- see docker output above"
    }
    Write-Output "base image ready: $BaseImageTag"
} else {
    Write-Output "base image cache hit: $BaseImageTag (skipping the dnf/JDK/Maven/Node/Docker-CE install)"
}

Write-LfFile -Path $DockerfilePath -Content @"
# Cached base image -- collapsed from the full Rocky/Debian setup Dockerfile
# by spawn-workspace.ps1's base-image caching step (see there for the "why").
# The tag below was pre-built and is already local, so this docker build
# just resolves FROM and finishes in seconds.
#
# Config changed (version bump, new proxy, different certs/repo mirror)? The
# tag's hash covers all of that automatically, so a real change gets a new
# tag and a fresh build on the next spawn. To force a rebuild WITHOUT a
# config change (e.g. the internal mirror's package set moved forward), run:
#   spawn-workspace.ps1 --rebuild-base-image <branch-name>
# or manually: docker rmi $BaseImageTag
FROM $BaseImageTag

# Unused now that FROM points at a prebuilt tag (no RUN below consumes them),
# but kept declared so devcontainer.json's build.args don't trigger a
# "build arg not consumed" warning.
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy
"@

# ============================================================================
# Done
# ============================================================================

Write-Output ''
Write-Output "workspace ready: $WsDir"
Write-Output ''
Write-Output 'Open in IntelliJ:'
Write-Output '  File -> Remote Development -> Dev Containers'
Write-Output "  Pick: $WsDir\.devcontainer\devcontainer.json"
Write-Output ''
Write-Output '  IntelliJ auto-opens README.md from the workspace root on first open --'
Write-Output '  it contains the first-time setup steps for this story.'
Write-Output ''
Write-Output "Port offset: +$PortOffset  (host-side port = container port + offset)"
if ($PortOutputLines) { Write-Output $PortOutputLines }
Write-Output ''
Write-Output "Inside the container, list each worktree's current branch with:"
Write-Output '  branches'
Write-Output ''
Write-Output 'Dispose later with:'
Write-Output "  dispose-workspace.ps1 $ConfigHint$Branch"
