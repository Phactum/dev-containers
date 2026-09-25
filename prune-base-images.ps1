<#
.SYNOPSIS
    prune-base-images.ps1 - remove locally cached 'devcontainer-base:*' images
    that no existing workspace references anymore. Windows/PowerShell port of
    prune-base-images.sh.

.DESCRIPTION
    spawn-workspace.ps1/.sh pre-build a reusable base image per devcontainers-config.json
    (tag: devcontainer-base:<distro>-<hash>) and collapse each workspace's own
    Dockerfile down to "FROM <tag>". A tag becomes orphaned once every
    workspace that used it has been disposed, or once devcontainers-config.json changed and
    every remaining workspace now points at a newer tag. Those orphaned images
    just take up disk space (a few GB each) with no way to reach them from a
    running workspace, so this script finds and removes them.

    An image is considered STILL IN USE if any workspace under
    <workspaces-root>/<PROJECT_NAME>-* has a ".devcontainer/Dockerfile" whose
    "FROM" line names it. Everything else tagged "devcontainer-base:*" locally
    is offered for removal.

.PARAMETER Arguments
    [-c|--config <path>] [--workspaces-root <path>] [-y|--yes] [-h|--help]

.EXAMPLE
    prune-base-images.ps1

.EXAMPLE
    prune-base-images.ps1 --yes
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

trap {
    Write-Err $_.Exception.Message
    exit 1
}

$Usage = @'
usage: prune-base-images.ps1 [--config <path>] [--workspaces-root <path>] [--yes]

  -c, --config <path>       devcontainers-config.json to use, or a directory containing it
                            (default: .\dev-containers\devcontainers-config.json, relative to
                            the current directory)
  --workspaces-root <path>  directory holding <PROJECT_NAME> and the story
                            workspaces (default: from "workspacesRoot" in devcontainers-config.json, else auto-detected)
  -y, --yes                 skip the confirmation prompt
  -h, --help                show this help

Removes every local 'devcontainer-base:*' image that no workspace's
.devcontainer/Dockerfile currently references (see spawn-workspace.ps1's
base-image caching step for how those tags are created).
'@

$WorkspacesRootCli = ''
$ConfigCli = ''
$AssumeYes = $false

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
        '^(-h|--help|-\?)$'   { Write-Output $Usage; exit 0 }
        '^-'                  { Fail "unknown option: $a" 2 }
        default { Fail "unexpected argument: $a" 2 }
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Fail 'docker not on PATH'
}

$ConfigPath = Resolve-DevContainerConfigPath -ConfigPath $ConfigCli
$cfg = Get-DevContainerConfig -Path $ConfigPath
$ProjectName = $cfg.ProjectName
$ProjectShort = $cfg.ProjectShort
$EnvVarWorkspacesRoot = ($ProjectShort -replace '[^A-Za-z0-9]', '_').ToUpperInvariant() + '_WORKSPACES_ROOT'
$WorkspacesRoot = Resolve-WorkspacesRoot -Config $cfg -Cli $WorkspacesRootCli -EnvVarName $EnvVarWorkspacesRoot

# Every workspace directory's own Dockerfile still names the tag it was built
# from ("FROM devcontainer-base:..."), even after the heavy install steps were
# collapsed away -- so scanning those FROM lines is a complete and exact
# in-use set, no guessing needed.
$referenced = New-Object System.Collections.Generic.HashSet[string]
if (Test-Path -LiteralPath $WorkspacesRoot -PathType Container) {
    Get-ChildItem -LiteralPath $WorkspacesRoot -Directory -Filter "$ProjectName-*" -ErrorAction SilentlyContinue |
        ForEach-Object {
            $dockerfile = Join-Path $_.FullName '.devcontainer\Dockerfile'
            if (Test-Path -LiteralPath $dockerfile -PathType Leaf) {
                (Read-TextFile $dockerfile) -split "`n" | Where-Object { $_ -match '^\s*FROM\s+(devcontainer-base:\S+)' } |
                    ForEach-Object {
                        if ($_ -match '^\s*FROM\s+(devcontainer-base:\S+)') {
                            [void]$referenced.Add($Matches[1])
                        }
                    }
            }
        }
}

$listResult = Invoke-Docker @('images', '--filter', 'reference=devcontainer-base', '--format', '{{.Repository}}:{{.Tag}}|{{.Size}}|{{.ID}}')
if ($listResult.ExitCode -ne 0) { Fail "docker images failed:`n$($listResult.StdErr)" }

$all = @($listResult.StdOut -split "`r?`n" | Where-Object { $_ })
if (-not $all) {
    Write-Output 'no devcontainer-base images found locally -- nothing to prune'
    exit 0
}

$orphaned = @()
foreach ($line in $all) {
    $parts = $line -split '\|'
    $tag = $parts[0]; $size = $parts[1]; $id = $parts[2]
    if (-not $referenced.Contains($tag)) {
        $orphaned += [pscustomobject]@{ Tag = $tag; Size = $size; Id = $id }
    }
}

Write-Output "workspaces root:  $WorkspacesRoot"
Write-Output "in-use tags:      $(if ($referenced.Count -gt 0) { ($referenced -join ', ') } else { '<none>' })"
Write-Output ''

if (-not $orphaned) {
    Write-Output 'no orphaned devcontainer-base images -- nothing to prune'
    exit 0
}

Write-Output 'orphaned (no workspace references these anymore):'
foreach ($o in $orphaned) { Write-Output "  $($o.Tag)  ($($o.Size))" }
Write-Output ''

if (-not $AssumeYes) {
    $reply = Read-Host "remove $($orphaned.Count) image(s)? [y/N]"
    if ($reply -notmatch '^[Yy]') {
        Write-Output 'aborted'
        exit 0
    }
}

foreach ($o in $orphaned) {
    Write-Output "removing $($o.Tag)..."
    $rm = Invoke-Docker @('rmi', $o.Id)
    if ($rm.ExitCode -ne 0) {
        Write-Output "  not removed (still in use by a container, or another tag points at the same layers): $($rm.StdErr)"
    }
}
