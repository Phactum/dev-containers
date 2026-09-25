<#
.SYNOPSIS
    Shared helper functions for spawn-workspace.ps1 and dispose-workspace.ps1.

.DESCRIPTION
    Dot-sourced by both scripts:

        . "$PSScriptRoot\Common.ps1"

    Only Windows PowerShell 5.1 built-ins are used, so nothing has to be
    installed for these scripts to run.
#>

Set-StrictMode -Version Latest

function Write-Err {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Message)
    [Console]::Error.WriteLine($Message)
}

function Fail {
    param(
        [Parameter(Mandatory = $true)][string] $Message,
        [int] $Code = 1
    )
    Write-Err $Message
    exit $Code
}

# Every generated file ends up in a Linux container (shell scripts, Dockerfile)
# or is read by tooling that dislikes a BOM (devcontainer.json). PowerShell's
# Set-Content would write CRLF and, on 5.1, a BOM for UTF8 - so we always go
# through this helper instead.
function Write-LfFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Content
    )
    $normalised = $Content -replace "`r`n", "`n"
    if (-not $normalised.EndsWith("`n")) { $normalised += "`n" }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $normalised, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-TextFile {
    param([Parameter(Mandatory = $true)][string] $Path)
    return [System.IO.File]::ReadAllText($Path)
}

# Docker (and therefore every bind-mount source in devcontainer.json) is happy
# with forward slashes on Windows and unhappy with backslashes inside JSON,
# where they would have to be escaped. Normalise once, use everywhere.
function ConvertTo-DockerPath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Path)
    if (-not $Path) { return '' }
    return ($Path -replace '\\', '/').TrimEnd('/')
}

# POSIX-style relative path from one directory to another. Used for the git
# worktree link files, which must resolve on the Windows host as well as inside
# the Linux container.
function Get-RelativePosixPath {
    param(
        [Parameter(Mandatory = $true)][string] $From,   # directory the link lives in
        [Parameter(Mandatory = $true)][string] $To      # target path
    )
    $fromParts = ($From -replace '\\', '/').TrimEnd('/') -split '/'
    $toParts = ($To -replace '\\', '/').TrimEnd('/') -split '/'

    $common = 0
    while ($common -lt $fromParts.Count -and $common -lt $toParts.Count -and
           $fromParts[$common].ToLowerInvariant() -eq $toParts[$common].ToLowerInvariant()) {
        $common++
    }
    if ($common -eq 0) {
        throw "Cannot build a relative path between different drives: '$From' -> '$To'"
    }

    $up = @()
    if ($fromParts.Count -gt $common) { $up = @('..') * ($fromParts.Count - $common) }
    $down = @()
    if ($common -lt $toParts.Count) { $down = $toParts[$common..($toParts.Count - 1)] }
    $parts = @($up) + @($down)
    if ($parts.Count -eq 0) { return '.' }
    return ($parts -join '/')
}

# Recursive delete that copes with the read-only/hidden bits git sets inside
# .git and with the odd locked handle, falling back to cmd's rd.
#
# Docker Desktop returns from `docker rm`/`docker volume rm` before its
# file-sharing layer has actually released the per-module node_modules named
# volumes bound INTO the workspace, so a delete can transiently fail with
# access / "directory not empty" errors on those mount-points for a few seconds
# even though the container and volumes are already gone. Retry a bounded number
# of times before giving up. By default (spawn's callers) a final failure still
# throws; pass -AllowFailure to get $true/$false back instead, so a caller in a
# loop (dispose) can warn and continue rather than abort.
function Remove-TreeForce {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [switch] $AllowFailure
    )
    $removed = $false
    if (-not (Test-Path -LiteralPath $Path)) {
        $removed = $true
    } else {
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            & cmd.exe /c "attrib -R -H -S `"$Path\*`" /S /D" 2>&1 | Out-Null
            try {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            } catch {
                & cmd.exe /c "rd /s /q `"$Path`"" 2>&1 | Out-Null
            }
            if (-not (Test-Path -LiteralPath $Path)) { $removed = $true; break }
            Start-Sleep -Seconds 2
        }
    }
    if (-not $removed -and -not $AllowFailure) { throw "Could not remove directory: $Path" }
    if ($AllowFailure) { return $removed }
}

# Run a native executable and capture its output without letting PowerShell's
# $ErrorActionPreference='Stop' turn anything the process writes to stderr into
# a terminating NativeCommandError. Returns exit code, stdout and stderr
# separately so callers can decide what a non-zero exit means.
function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $ArgumentList
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $FilePath @ArgumentList 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }

    $stdout = New-Object System.Collections.Generic.List[string]
    $stderr = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($raw)) {
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            $stderr.Add($item.ToString())
        } else {
            $stdout.Add([string]$item)
        }
    }

    return [pscustomobject]@{
        ExitCode = $code
        StdOut   = (($stdout -join "`n").Trim())
        StdErr   = (($stderr -join "`n").Trim())
    }
}

# git wrapper: native commands don't raise, so the exit code is checked
# explicitly. Returns stdout as a single trimmed string and records the exit
# code in $script:LastGitExitCode for the Test-GitSucceeded probe below.
# Unless -Quiet is given, git's stderr (progress messages, hints) is passed
# through to the console, matching what the Bash script shows.
function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]] $GitArgs,
        [string] $RepoDir,
        [switch] $AllowFailure,
        [switch] $Quiet
    )
    $all = @()
    if ($RepoDir) { $all += @('-C', $RepoDir) }
    $all += $GitArgs

    $result = Invoke-NativeCapture -FilePath 'git' -ArgumentList $all
    $script:LastGitExitCode = $result.ExitCode

    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($all -join ' ') failed (exit $($result.ExitCode))`n$($result.StdOut)`n$($result.StdErr)"
    }
    if (-not $Quiet -and $result.StdErr) { Write-Err $result.StdErr }
    return $result.StdOut
}

# docker wrapper on the same footing as Invoke-Git. Docker cleanup is always
# best-effort, so this never throws; callers inspect ExitCode.
function Invoke-Docker {
    param([Parameter(Mandatory = $true)][string[]] $DockerArgs)
    return Invoke-NativeCapture -FilePath 'docker' -ArgumentList $DockerArgs
}

function Test-GitSucceeded {
    param(
        [Parameter(Mandatory = $true)][string[]] $GitArgs,
        [string] $RepoDir
    )
    Invoke-Git -GitArgs $GitArgs -RepoDir $RepoDir -AllowFailure -Quiet | Out-Null
    return ($script:LastGitExitCode -eq 0)
}
