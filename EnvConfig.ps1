<#
.SYNOPSIS
    Loads a project's devcontainers-config.json and returns it as a normalised object.

.DESCRIPTION
    Dot-sourced by spawn-workspace.ps1 and dispose-workspace.ps1:

        . "$PSScriptRoot\EnvConfig.ps1"
        $cfg = Get-DevContainerConfig -Path $resolvedConfigPath

    devcontainers-config.json is the single source of truth for project
    configuration and is
    shared with the Bash scripts (which read it through env-config.sh + jq).
    It is JSON with full-line "//" comments; those lines are stripped here
    before ConvertFrom-Json sees the document. Only Windows PowerShell 5.1
    built-ins are used, so no module installation is required.

    The returned object mirrors the variables the Bash side exposes:

        ProjectName, ProjectShort, BaseImage, NodeFeatureVersion,
        GlabVersion, GlabHostname, GhVersion, PortOffsetStep, TerminalShell
        Repos             [ @{ Name; BaseRef } ]
        HostPorts         [ @{ Port; Label } ]
        RunConfigs        [ string ]
        ForwardedEnvVars  [ string ]
        Builds            [ @{ Repo; Type; Value } ]   Type = 'mvn' | 'cmd'
        BuildsDefined     bool -- whether the "builds" key was present
        MonoRepo          $true when Repos is empty
        WorkspacesRoot    '' unless the project pins one
        Path              the resolved config path
        Dir               its directory (base dir for the other project assets)
#>

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Resolves which devcontainers-config.json to use.

.DESCRIPTION
    Mirrors the Bash lookup:
      1. -ConfigPath (a config file, or a directory containing devcontainers-config.json)
      2. .\dev-containers\devcontainers-config.json, relative to the CURRENT WORKING DIRECTORY
      3. .\devcontainers-config.json, relative to the CURRENT WORKING DIRECTORY
    Resolving against the working directory - not against the script location -
    is what lets a single PATH-installed clone serve every project. Because all
    other project assets fall back to the copies shipped with the scripts, a lone
    devcontainers-config.json in the project root is a complete setup.
#>
function Resolve-DevContainerConfigPath {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string] $ConfigPath = ''
    )

    $defaultRelatives = @('dev-containers\devcontainers-config.json', 'devcontainers-config.json')

    if ($ConfigPath) {
        if (Test-Path -LiteralPath $ConfigPath -PathType Container) {
            $candidate = Join-Path $ConfigPath 'devcontainers-config.json'
        } else {
            $candidate = $ConfigPath
        }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Project config not found: $candidate"
        }
    } else {
        $cwd = (Get-Location).Path
        $candidate = $null
        foreach ($rel in $defaultRelatives) {
            $probe = Join-Path $cwd $rel
            if (Test-Path -LiteralPath $probe -PathType Leaf) { $candidate = $probe; break }
        }
        if (-not $candidate) {
            $looked = ($defaultRelatives | ForEach-Object { "  " + (Join-Path $cwd $_) }) -join "`n"
            throw ("Project config not found. Looked for:`n$looked`n" +
                   "Run the command from the project directory, or point at a config`n" +
                   'with --config <path-to-devcontainers-config.json|dir>.')
        }
    }

    return (Resolve-Path -LiteralPath $candidate).Path
}

<#
.SYNOPSIS
    Resolves the workspaces root, shared by spawn and dispose so both agree.

.DESCRIPTION
    Priority:
      1. -Cli                        --workspaces-root CLI flag
      2. $env:<PROJECTSHORT>_WORKSPACES_ROOT
      3. "workspacesRoot" in devcontainers-config.json (relative paths resolve against the
         config's own directory)
      4. auto-detect from the config location

    Auto-detect walks up from the config's directory looking for the directory
    named after the project - that is the source workspace, so its parent is the
    workspaces root. This makes both supported layouts work with no
    configuration at all:
        <root>\<PROJECT_NAME>\dev-containers\devcontainers-config.json   (config in a subdir)
        <root>\<PROJECT_NAME>\devcontainers-config.json                  (config in the project root)
    If no such directory is found (the project directory has a different name),
    it falls back to two levels above the config, the historical behaviour.
#>
function Resolve-WorkspacesRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Config,
        [AllowEmptyString()][string] $Cli = '',
        [Parameter(Mandatory = $true)][string] $EnvVarName
    )

    $candidate = ''
    if ($Cli) {
        $candidate = $Cli
    } else {
        $fromEnv = [Environment]::GetEnvironmentVariable($EnvVarName)
        if ($fromEnv) {
            $candidate = $fromEnv
        } elseif ($Config.WorkspacesRoot) {
            $candidate = $Config.WorkspacesRoot
            # A relative path in devcontainers-config.json is relative to the config itself, so
            # a project can commit e.g. "workspacesRoot": ".." and stay portable.
            if (-not [System.IO.Path]::IsPathRooted($candidate)) {
                $candidate = Join-Path $Config.Dir $candidate
            }
        } else {
            $dir = $Config.Dir
            for ($i = 0; $i -lt 3 -and $dir; $i++) {
                if ((Split-Path -Leaf $dir) -eq $Config.ProjectName) {
                    $candidate = Join-Path $dir '..'
                    break
                }
                $parent = Split-Path -Parent $dir
                if (-not $parent -or $parent -eq $dir) { break }
                $dir = $parent
            }
            # Fallback: the historical "two levels above the config" rule.
            if (-not $candidate) { $candidate = Join-Path $Config.Dir '..\..' }
        }
    }

    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw ("Workspaces root does not exist: $candidate`n" +
               "Set `"workspacesRoot`" in $($Config.Path), pass --workspaces-root <path>,`n" +
               "or set `$env:$EnvVarName.")
    }
    # Canonicalise: bind-mount paths in devcontainer.json must be absolute, and
    # path comparisons must not depend on how the user spelled the argument.
    return (Resolve-Path -LiteralPath $candidate).Path.TrimEnd('\')
}

function Get-DevContainerConfig {
    [CmdletBinding()]
    param(
        # Path to devcontainers-config.json, already resolved by Resolve-DevContainerConfigPath.
        [Parameter(Mandatory = $true)][string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Project config not found: $Path"
    }

    # Strip full-line "//" comments. Deliberately anchored to the start of the
    # line (leading whitespace allowed) so that "//" inside a string value -- a
    # URL, for instance -- is left untouched.
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $stripped = ($raw -split "`r?`n" | ForEach-Object {
        if ($_ -match '^\s*//') { '' } else { $_ }
    }) -join "`n"

    try {
        $json = $stripped | ConvertFrom-Json
    } catch {
        throw ("Project config is not valid JSON: {0}`n{1}`n" +
               "(Note: only full-line '//' comments are supported, no trailing comments.)") `
              -f $Path, $_.Exception.Message
    }

    # ConvertFrom-Json returns a PSCustomObject; probing for optional keys has
    # to go through PSObject.Properties because Set-StrictMode makes a plain
    # property access on a missing member throw.
    $has = { param($name) $json.PSObject.Properties.Name -contains $name }

    $str = {
        param($name, $default = '')
        if (& $has $name) {
            $v = $json.$name
            if ($null -eq $v) { return $default }
            return [string]$v
        }
        return $default
    }

    $cfg = [ordered]@{
        Path               = (Resolve-Path -LiteralPath $Path).Path
        Dir                = (Split-Path -Parent (Resolve-Path -LiteralPath $Path).Path)
        ProjectName        = & $str 'projectName'
        ProjectShort       = & $str 'projectShort'
        BaseImage          = & $str 'baseImage'
        NodeFeatureVersion = & $str 'nodeFeatureVersion'
        # Package-manager family of the base image. "debian" (default) keeps the
        # apt/devcontainer-feature build; "rocky" switches every distro-specific
        # step of the generated Dockerfile to dnf and installs the toolchain
        # (JDK, Maven, Node, docker) directly, because the devcontainer features
        # only support Debian/Ubuntu.
        Distro             = (& $str 'distro' 'debian').ToLowerInvariant()
        # Rocky only: JDK major version (dnf package java-<n>-openjdk-devel) and
        # the Apache Maven version installed from the binary tarball. Ignored on
        # Debian, where the java:1 feature provides Maven and the base image the
        # JDK.
        JavaVersion        = & $str 'javaVersion' '21'
        MavenVersion       = & $str 'mavenVersion' '3.9.9'
        GlabVersion        = & $str 'glabVersion'
        GlabHostname       = & $str 'glabHostname'
        GhVersion          = & $str 'ghVersion'
        # Optional login shell for IntelliJ's built-in terminal. Empty (the
        # default) leaves myShellPath unset in .idea/workspace.xml, so JetBrains
        # auto-detects a shell -- and it prefers the zsh the base image ships
        # over the vscode account's /bin/bash login shell. Set an absolute
        # in-container path (e.g. /bin/bash) to pin it.
        TerminalShell      = & $str 'terminalShell'
        WorkspacesRoot     = & $str 'workspacesRoot'
        ProxyHttp          = ''
        ProxyHttps         = ''
        ProxyNoProxy       = ''
        ProxyCaCerts       = @()
        ProxyDebianHttps   = $false
        FeatureRegistry    = 'ghcr.io'
        ImageAptPackages   = $true
        ImageRecentGit     = $true
        ImageChromium      = $true
        PortOffsetStep     = 10000
        Repos              = @()
        HostPorts          = @()
        RunConfigs         = @()
        ForwardedEnvVars   = @()
        Builds             = @()
        BuildsDefined      = $false
        MonoRepo           = $false
    }

    foreach ($required in 'ProjectName', 'ProjectShort', 'BaseImage', 'NodeFeatureVersion') {
        if ([string]::IsNullOrWhiteSpace($cfg[$required])) {
            throw "Missing required setting in $($cfg.Path): $required"
        }
    }

    # Only the two package-manager families the generated Dockerfile knows how
    # to drive. "rocky" covers every RHEL-compatible base (Rocky, Alma, CentOS
    # Stream, RHEL/UBI) -- they all use dnf and the same paths.
    if ($cfg.Distro -notin @('debian', 'rocky')) {
        throw "Invalid 'distro' in $($cfg.Path): '$($cfg.Distro)' (expected 'debian' or 'rocky')"
    }

    if (& $has 'portOffsetStep') {
        $cfg.PortOffsetStep = [int]$json.portOffsetStep
    }

    if ((& $has 'repos') -and $null -ne $json.repos) {
        $cfg.Repos = @(foreach ($r in $json.repos) {
            $baseRef = ''
            if ($r.PSObject.Properties.Name -contains 'baseRef' -and $null -ne $r.baseRef) {
                $baseRef = [string]$r.baseRef
            }
            [pscustomobject]@{ Name = [string]$r.name; BaseRef = $baseRef }
        })
    }
    # Mono-repo mode: an empty repos list signals that the source workspace IS
    # the git repo. The callers synthesise a single virtual entry from it.
    $cfg.MonoRepo = ($cfg.Repos.Count -eq 0)

    if ((& $has 'hostPorts') -and $null -ne $json.hostPorts) {
        $cfg.HostPorts = @(foreach ($p in $json.hostPorts) {
            $label = ''
            if ($p.PSObject.Properties.Name -contains 'label' -and $null -ne $p.label) {
                $label = [string]$p.label
            }
            [pscustomobject]@{ Port = [int]$p.port; Label = $label }
        })
    }

    if ((& $has 'runConfigs') -and $null -ne $json.runConfigs) {
        $cfg.RunConfigs = @($json.runConfigs | ForEach-Object { [string]$_ })
    }

    if ((& $has 'forwardedEnvVars') -and $null -ne $json.forwardedEnvVars) {
        $cfg.ForwardedEnvVars = @($json.forwardedEnvVars | ForEach-Object { [string]$_ })
    }

    # Build list: a single "builds" array whose entries each carry exactly one of
    # "mvn-goal" (Type=mvn, run as `mvn ${MVN_FLAGS} <goal>`) or "command"
    # (Type=cmd, run verbatim). BuildsDefined records whether the key was present,
    # so an explicit "builds": [] disables warmup builds without triggering the
    # mono-repo auto-build (same as the Bash side).
    if (& $has 'builds') {
        $cfg.BuildsDefined = $true
        if ($null -ne $json.builds) {
            $cfg.Builds = @(foreach ($b in $json.builds) {
                $hasGoal = ($b.PSObject.Properties.Name -contains 'mvn-goal') -and ($null -ne $b.'mvn-goal')
                $hasCmd  = ($b.PSObject.Properties.Name -contains 'command')  -and ($null -ne $b.command)
                if ($hasGoal -eq $hasCmd) {
                    throw "Invalid 'builds' entry in $($cfg.Path) (repo=$($b.repo)): set exactly one of 'mvn-goal' / 'command'"
                }
                if ($hasGoal) {
                    [pscustomobject]@{ Repo = [string]$b.repo; Type = 'mvn'; Value = [string]$b.'mvn-goal' }
                } else {
                    [pscustomobject]@{ Repo = [string]$b.repo; Type = 'cmd'; Value = [string]$b.command }
                }
            })
        }
    }

    # Corporate proxy / TLS interception. All optional; absent means "not behind
    # a proxy" and every downstream block is omitted from the generated files.
    if ((& $has 'proxy') -and $null -ne $json.proxy) {
        $p = $json.proxy
        $pHas = { param($n) $p.PSObject.Properties.Name -contains $n }
        if ((& $pHas 'http') -and $p.http) { $cfg.ProxyHttp = [string]$p.http }
        if ((& $pHas 'https') -and $p.https) { $cfg.ProxyHttps = [string]$p.https }
        if ((& $pHas 'noProxy') -and $p.noProxy) { $cfg.ProxyNoProxy = [string]$p.noProxy }
        if ((& $pHas 'debianUseHttps') -and $p.debianUseHttps) { $cfg.ProxyDebianHttps = [bool]$p.debianUseHttps }
        # Distro-neutral spelling of the same switch (apt sources on Debian,
        # dnf repo baseurls on Rocky). Wins over the legacy key when both exist.
        if ((& $pHas 'useHttpsRepos') -and $p.useHttpsRepos) { $cfg.ProxyDebianHttps = [bool]$p.useHttpsRepos }
        if ((& $pHas 'caCertificates') -and $null -ne $p.caCertificates) {
            $cfg.ProxyCaCerts = @($p.caCertificates | ForEach-Object { [string]$_ })
        }
    }

    # Registry the devcontainer features come from, and the optional image build
    # steps. Defaults keep the previous behaviour exactly; a switch only counts
    # as "off" when it is explicitly set to false.
    if ((& $has 'featureRegistry') -and $json.featureRegistry) {
        $cfg.FeatureRegistry = [string]$json.featureRegistry
    }
    if ((& $has 'imageBuild') -and $null -ne $json.imageBuild) {
        $ib = $json.imageBuild
        $ibHas = { param($n) $ib.PSObject.Properties.Name -contains $n }
        if (& $ibHas 'aptPackages') { $cfg.ImageAptPackages = [bool]$ib.aptPackages }
        # Distro-neutral alias (apt-get on Debian, dnf on Rocky).
        if (& $ibHas 'packages')    { $cfg.ImageAptPackages = [bool]$ib.packages }
        if (& $ibHas 'recentGit')   { $cfg.ImageRecentGit = [bool]$ib.recentGit }
        if (& $ibHas 'chromium')    { $cfg.ImageChromium = [bool]$ib.chromium }
    }

    return [pscustomobject]$cfg
}
