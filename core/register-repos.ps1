#Requires -Version 5.1
<#
.SYNOPSIS
    Scan a folder of git checkouts and register them in manifests/repos.json.

.DESCRIPTION
    Walks the immediate subdirectories of -ScanRoot (default ~/repos), reads
    each checkout's `origin` URL and current branch with git, and merges the
    result into the manifest used by install.ps1 to clone repos on a new
    machine. Existing entries that are not present in the scan are preserved,
    so the list stays useful when run from a public PC with only some checkouts.

    A repo without an origin is registered with an empty URL and skipped by the
    installer. A detached HEAD ("HEAD") does not overwrite a recorded branch.
    The manifest is only rewritten when something actually changed; a timestamped
    .bak copy is kept unless -NoBackup is passed. Nothing is pushed or cloned.
#>
[CmdletBinding()]
param(
    [string] $ScanRoot = (Join-Path $env:USERPROFILE 'repos'),
    # Resolved in the body: $PSScriptRoot is empty during param binding in PS 5.1.
    [string] $Manifest = '',
    [switch] $DryRun,
    [switch] $NoBackup
)

$ErrorActionPreference = 'Stop'

if (-not $Manifest) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
    $Manifest = Join-Path (Split-Path -Parent $scriptDir) 'manifests\repos.json'
}

function Invoke-Git {
    param([string] $RepoPath, [string[]] $Arguments)
    $quoted = (@($Arguments) | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $out = (& cmd /c ('git -C "{0}" {1} 2>nul' -f $RepoPath, $quoted) | Out-String).Trim()
    return @{ Ok = ($LASTEXITCODE -eq 0); Value = $out }
}

if (-not (Test-Path -LiteralPath $ScanRoot)) {
    throw "ScanRoot not found: $ScanRoot"
}

$comment = 'Repos registered by core/register-repos.ps1. install.ps1 clones any missing checkout into ~/repos; entries without a url are skipped.'
$items = @()
if (Test-Path -LiteralPath $Manifest) {
    try { $existing = Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json }
    catch { throw "Could not read $Manifest`: $($_.Exception.Message)" }
    if ($existing._comment) { $comment = $existing._comment }
    foreach ($repo in @($existing.repos)) {
        if (-not $repo.name) { continue }
        $entry = [ordered]@{ name = $repo.name }
        $entry['url'] = if ($repo.url) { $repo.url } else { '' }
        $entry['branch'] = if ($repo.branch) { $repo.branch } else { '' }
        if ($repo.note) { $entry['note'] = $repo.note }
        $items += [pscustomobject] $entry
    }
}

$added = @()
$updated = @()
$seen = @()

foreach ($dir in (Get-ChildItem -LiteralPath $ScanRoot -Directory -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName '.git'))) { continue }
    $origin = Invoke-Git -RepoPath $dir.FullName -Arguments @('remote', 'get-url', 'origin')
    $branch = Invoke-Git -RepoPath $dir.FullName -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    $url = if ($origin.Ok) { $origin.Value } else { '' }
    $name = $branch.Value
    if (-not $name -or $name -eq 'HEAD') { $name = '' } # detached HEAD: keep recorded/default branch
    $seen += $dir.Name

    $found = $items | Where-Object { $_.name -eq $dir.Name } | Select-Object -First 1
    if ($found) {
        $changed = $false
        if ($url -and $found.url -ne $url) { $found.url = $url; $changed = $true }
        if ($name -and $found.branch -ne $name) { $found.branch = $name; $changed = $true }
        if (-not $url -and -not $found.note) {
            $found | Add-Member -NotePropertyName note -NotePropertyValue 'Local-only checkout (no origin); skipped by the installer.' -ErrorAction SilentlyContinue
            $changed = $true
        }
        if ($changed) { $updated += $dir.Name }
    } else {
        $entry = [ordered]@{ name = $dir.Name; url = $url; branch = $name }
        if (-not $url) { $entry['note'] = 'Local-only checkout (no origin); skipped by the installer.' }
        $items += [pscustomobject] $entry
        $added += $dir.Name
    }
}

$result = [ordered]@{ _comment = $comment; repos = @($items) }
$newText = ($result | ConvertTo-Json -Depth 5) + "`n"
$oldText = if (Test-Path -LiteralPath $Manifest) { [IO.File]::ReadAllText($Manifest) } else { '' }
$normalize = { param($s) ($s -replace "`r`n", "`n").TrimEnd() }

Write-Host ("Scanned {0} git checkouts in {1}" -f $seen.Count, $ScanRoot)
if ($added.Count) { Write-Host ("  added: {0}" -f ($added -join ', ')) }
if ($updated.Count) { Write-Host ("  updated: {0}" -f ($updated -join ', ')) }
$missing = @($items | Where-Object { $seen -notcontains $_.name } | ForEach-Object { $_.name })
if ($missing.Count) { Write-Host ("  kept from manifest (not on this machine): {0}" -f ($missing -join ', ')) -ForegroundColor DarkGray }

if ((& $normalize $oldText) -eq (& $normalize $newText)) {
    Write-Host 'Manifest already up to date; nothing written.'
    return
}
if ($DryRun) {
    Write-Host 'DRYRUN: manifest would be updated (nothing written).' -ForegroundColor DarkGray
    return
}
if (-not $NoBackup -and (Test-Path -LiteralPath $Manifest)) {
    $backup = '{0}.bak.{1}' -f $Manifest, (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $Manifest -Destination $backup -Force
    Write-Host "Backup: $backup"
}
[IO.File]::WriteAllText($Manifest, $newText, (New-Object Text.UTF8Encoding $false))
Write-Host "Wrote $Manifest"
