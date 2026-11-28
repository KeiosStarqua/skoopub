#Requires -Version 5.1
<#
.SYNOPSIS
    Install manifests/scoop.json in the ordered phases declared by
    manifests/phases.json.

.DESCRIPTION
    scoop.json stays the single source of truth (it is still what `scoop export`
    writes), while phases.json only decides which app belongs to which phase.
    That keeps versions in one place and makes a missing assignment a hard
    error instead of a silently skipped package.

    Each app in a phase is imported from its own generated manifest so its
    install time can be reported; buckets are added on the first app only, so
    the first phase does not clone buckets that only the heavy phase uses.
    Phase 1 failures abort; later phase failures are reported and the remaining
    phases still run, so the essentials are never lost to a slow download.

    Dot-source this file from install.ps1 / core/bootstrap.ps1. Loading it has
    no side effects.

.EXAMPLE
    . .\core\scoop-phases.ps1
    Invoke-SkoopPhases -Scoop $scoop -ManifestPath .\manifests\scoop.json `
        -PhasesPath .\manifests\phases.json
#>

function Get-SkoopPhasePlan {
    # Parse scoop.json + phases.json and validate the mapping before installing
    # anything. Unknown, duplicated or unassigned apps all throw.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$PhasesPath
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "Scoop manifest not found: $ManifestPath" }
    if (-not (Test-Path -LiteralPath $PhasesPath)) { throw "Phase manifest not found: $PhasesPath" }

    $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    $phaseDoc = Get-Content -Raw -LiteralPath $PhasesPath | ConvertFrom-Json
    $phases = @($phaseDoc.phases)
    if ($phases.Count -eq 0) { throw "No phases declared in $PhasesPath" }

    $apps = @($manifest.apps)
    $appsByName = @{}
    foreach ($app in $apps) { $appsByName[[string]$app.Name] = $app }

    $buckets = @($manifest.buckets)
    $bucketsByName = @{}
    foreach ($bucket in $buckets) { $bucketsByName[[string]$bucket.Name] = $bucket }

    $assigned = @{}
    foreach ($phase in $phases) {
        if (-not $phase.Name) { throw "A phase in $PhasesPath has no Name." }
        foreach ($name in @($phase.Apps)) {
            if (-not $appsByName.ContainsKey($name)) {
                throw "Phase '$($phase.Name)' lists '$name', which is not in $ManifestPath."
            }
            if ($assigned.ContainsKey($name)) {
                throw "App '$name' is listed in both '$($assigned[$name])' and '$($phase.Name)'."
            }
            $assigned[$name] = $phase.Name
        }
        foreach ($bucketName in @($phase.Buckets)) {
            if (-not $bucketsByName.ContainsKey($bucketName)) {
                throw "Phase '$($phase.Name)' lists bucket '$bucketName', which is not in $ManifestPath."
            }
        }
    }

    $unassigned = @($apps | Where-Object { -not $assigned.ContainsKey([string]$_.Name) } | ForEach-Object { [string]$_.Name })
    if ($unassigned.Count -gt 0) {
        throw "These apps are not assigned to any phase in ${PhasesPath}: $($unassigned -join ', ')"
    }

    return [pscustomobject]@{
        Manifest      = $manifest
        Phases        = $phases
        AppsByName    = $appsByName
        BucketsByName = $bucketsByName
    }
}

function New-SkoopPhaseManifest {
    # Write a temporary scoop export ({ buckets, apps }) for one phase, in the
    # same shape `scoop export` produces, so `scoop import` can replay it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Phase,
        [string[]]$ExcludeApps = @(),
        [string[]]$OnlyApps = @(),
        [switch]$NoBuckets,
        [string]$TempDir = $env:TEMP
    )

    $apps = @()
    $names = if ($OnlyApps.Count -gt 0) { $OnlyApps } else { @($Phase.Apps) }
    foreach ($name in $names) {
        if ($ExcludeApps -contains $name) { continue }
        $apps += $Plan.AppsByName[$name]
    }

    $buckets = @()
    if (-not $NoBuckets) {
        foreach ($name in @($Phase.Buckets)) { $buckets += $Plan.BucketsByName[$name] }
    }

    $payload = [pscustomobject]@{ buckets = $buckets; apps = $apps }
    $suffix = if ($OnlyApps.Count -eq 1) { '-' + $OnlyApps[0] } else { '' }
    $path = Join-Path $TempDir ('skoop-phase-{0}{1}.json' -f $Phase.Name, $suffix)
    $json = $payload | ConvertTo-Json -Depth 20

    # BOM-less UTF-8: PowerShell 5.1's Set-Content -Encoding UTF8 adds a BOM.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $json, $utf8)
    return $path
}

function Get-SkoopInstalledApps {
    # Names of Scoop apps that have a live `current` entry. Reading the app dirs
    # avoids parsing `scoop list` (locale-dependent) and works even when the
    # scoop shim itself is not on PATH yet.
    [CmdletBinding()]
    param([string]$ScoopRoot = '')

    $roots = @()
    if ($ScoopRoot) { $roots += $ScoopRoot }
    if ($env:SCOOP) { $roots += $env:SCOOP }
    if ($env:USERPROFILE) { $roots += (Join-Path $env:USERPROFILE 'scoop') }
    if ($env:ProgramData) { $roots += (Join-Path $env:ProgramData 'scoop') }

    $appsDir = $null
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'apps'
        if (Test-Path -LiteralPath $candidate) { $appsDir = $candidate; break }
    }
    if (-not $appsDir) { return @() }

    return @(Get-ChildItem -LiteralPath $appsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'current') } |
        ForEach-Object { $_.Name })
}

function Invoke-SkoopPhases {
    <#
        Install every phase in order. -AfterPhase runs after a phase imports
        successfully (install.ps1 uses it to finish the phase 1 setup and to
        re-launch under pwsh). -StopAfterPhase ends the loop after that phase,
        which is what -EssentialsOnly uses. -SkipInstalled drops apps that are
        already present in Scoop from the generated manifests, so re-runs only
        import what is missing; -Force defeats that check (but never overrides
        an explicit -ExcludeApps such as an existing UniKey).
    #>
    [CmdletBinding()]
    param(
        [string]$Scoop = 'scoop',
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$PhasesPath,
        [string[]]$ExcludeApps = @(),
        [switch]$SkipInstalled,
        [switch]$Force,
        [string]$ScoopRoot = '',
        [scriptblock]$AfterPhase,
        [string]$StopAfterPhase = ''
    )

    $plan = Get-SkoopPhasePlan -ManifestPath $ManifestPath -PhasesPath $PhasesPath
    $effectiveExclude = @($ExcludeApps)
    if ($SkipInstalled -and -not $Force) {
        $installed = @(Get-SkoopInstalledApps -ScoopRoot $ScoopRoot)
        if ($installed.Count -gt 0) {
            $alreadyPresent = @()
            foreach ($app in @($plan.Manifest.apps)) {
                $name = [string]$app.Name
                if ($installed -contains $name -and $effectiveExclude -notcontains $name) {
                    $effectiveExclude += $name
                    $alreadyPresent += $name
                }
            }
            if ($alreadyPresent.Count -gt 0) {
                Write-Host ('    already installed, skipping: {0}' -f ($alreadyPresent -join ', ')) -ForegroundColor DarkGray
            }
        }
    }
    $failed = New-Object 'System.Collections.Generic.List[string]'
    $index = 0

    foreach ($phase in $plan.Phases) {
        $index++
        $label = if ($phase.Description) { '{0} - {1}' -f $phase.Name, $phase.Description } else { [string]$phase.Name }
        Write-Host ('==> Phase {0}/{1}: {2}' -f $index, $plan.Phases.Count, $label) -ForegroundColor Cyan

        $pending = @($Phase.Apps | Where-Object { $effectiveExclude -notcontains $_ })
        $exit = 0
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $timings = @()
        if ($pending.Count -eq 0) {
            Write-Host '    all apps already installed - skipping scoop import' -ForegroundColor DarkGray
            $timer.Stop()
            $timer = $null
        } else {
            for ($i = 0; $i -lt $pending.Count; $i++) {
                $name = [string]$pending[$i]
                # Add the phase's buckets once, on the first app's import.
                $appFile = New-SkoopPhaseManifest -Plan $plan -Phase $phase `
                    -OnlyApps @($name) -NoBuckets:($i -gt 0)
                $appTimer = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    & $Scoop import $appFile
                    $appExit = $LASTEXITCODE
                } catch {
                    $appExit = 1
                    Write-Host "    $($_.Exception.Message)" -ForegroundColor Yellow
                }
                $appTimer.Stop()
                $timings += [pscustomobject]@{
                    Name    = $name
                    Seconds = $appTimer.Elapsed.TotalSeconds
                    Ok      = ($appExit -eq 0)
                }
                if ($appExit -ne 0) { $exit = $appExit; break }
            }
            $timer.Stop()
        }

        if ($timings.Count -gt 0) {
            Write-Host '    package times:' -ForegroundColor DarkGray
            foreach ($row in $timings) {
                $status = if ($row.Ok) { '' } else { '  failed' }
                Write-Host ('      {0,-24} {1,7:n1}s{2}' -f $row.Name, $row.Seconds, $status) -ForegroundColor DarkGray
            }
        }

        if ($exit -ne 0) {
            if ($index -eq 1) {
                throw "scoop import failed for phase '$($phase.Name)' (exit $exit)."
            }
            Write-Host ("    phase '{0}' failed (exit {1}) - continuing with the next phase" -f $phase.Name, $exit) -ForegroundColor Yellow
            $failed.Add([string]$phase.Name)
        } elseif ($timer) {
            Write-Host ('    done in {0:n1}s' -f $timer.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        }

        if ($AfterPhase) { & $AfterPhase $phase $index }
        if ($StopAfterPhase -and $phase.Name -eq $StopAfterPhase) { break }
    }

    return [pscustomobject]@{
        Phases = $plan.Phases
        Failed = @($failed)
    }
}
