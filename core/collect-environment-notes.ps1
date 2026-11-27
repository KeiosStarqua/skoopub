<#
.SYNOPSIS
Collects a private environment snapshot and optionally uploads it to, or reads it
from, a remote host.

.DESCRIPTION
Read-only collector for host, software and network metadata. No machine name,
address, user, brand or path is baked into this file: every label, remote target
and search pattern is a parameter. Notes are written to a local staging folder,
copied to a private remote folder with scp when -RemoteHost is supplied, and the
staging folder is deleted after a successful upload unless -KeepLocal is set.

Generated notes contain potentially sensitive data. Never commit them to this
repository or any other public Git repository. Keep the remote folder private.

.PARAMETER OutDir
Local staging directory. Defaults to a temp folder.

.PARAMETER Label
Simple folder name used under -RemoteDir. Must contain only letters, digits,
dots, dashes and underscores.

.PARAMETER RemoteHost
ssh destination (user@host). When given, notes are uploaded after collection.

.PARAMETER RemoteDir
Remote parent folder. Defaults to ~/skoop-notes. Must be a simple shell path.

.PARAMETER ProcessPattern
Optional patterns; matching processes are recorded with path and command line.

.PARAMETER ServicePattern
Optional patterns; matching services are recorded with their path.

.PARAMETER ScanRoot
Optional roots whose immediate children are listed, for discovering local suites.

.PARAMETER PublicIpUrl
JSON endpoint returning an ip object; pass an empty string to skip egress lookup.

.PARAMETER Redact
Strings replaced with [redacted] in every generated note.

.PARAMETER KeepLocal
Keep the staging folder after upload. By default it is removed on success.

.PARAMETER DryRun
Collect and write locally, but do not upload.

.PARAMETER ReadRemote
Read the private notes from the remote host and print them. No local collection.

.EXAMPLE
.\core\collect-environment-notes.ps1 -DryRun -OutDir "$env:TEMP\env-notes"

.EXAMPLE
.\core\collect-environment-notes.ps1 -RemoteHost me@example.com -Label 2026-11-27

.EXAMPLE
.\core\collect-environment-notes.ps1 -RemoteHost me@example.com -Label 2026-11-27 -ReadRemote
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $env:TEMP 'skoop-environment-notes'),
    [string]$Label = 'snapshot',
    [string]$RemoteHost,
    [string]$RemoteDir = '~/skoop-notes',
    [string[]]$ProcessPattern = @(),
    [string[]]$ServicePattern = @(),
    [string[]]$ScanRoot = @(),
    [string]$PublicIpUrl = 'https://ipinfo.io/json',
    [string[]]$Redact = @(),
    [switch]$KeepLocal,
    [switch]$DryRun,
    [switch]$ReadRemote
)

$ErrorActionPreference = 'Stop'

function Test-SimpleToken {
    param([string]$Value, [string]$Name, [string]$Pattern)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch $Pattern) {
        throw "$Name must match $Pattern"
    }
}

function Protect-NoteText {
    param([string]$Text)
    foreach ($needle in $Redact) {
        if (-not [string]::IsNullOrEmpty($needle)) {
            $Text = $Text -replace [regex]::Escape($needle), '[redacted]'
        }
    }
    return $Text
}

function Write-NoteFile {
    param([string]$Name, [string]$Body)
    $Body = Protect-NoteText $Body
    $Body = ($Body -replace "`r`n", "`n").TrimEnd() + "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $OutDir $Name), $Body, $utf8NoBom)
}

function Get-HostNote {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $drives = (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', '
    $lines = @(
        '# Host',
        '',
        "- Captured UTC: $((Get-Date).ToUniversalTime().ToString('o'))",
        "- Computer name: $env:COMPUTERNAME",
        "- DNS host name: $([System.Net.Dns]::GetHostName())",
        "- User: $env:USERNAME",
        "- PowerShell: $($PSVersionTable.PSVersion)",
        "- OS: $($os.Caption) $($os.Version)",
        "- Script path: $PSScriptRoot",
        "- Filesystem drives: $drives"
    )
    return ($lines -join "`n")
}

function Get-SoftwareNote {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Software')
    $lines.Add('')
    $lines.Add('## Package managers found')
    foreach ($tool in @('scoop', 'winget', 'choco')) {
        $command = Get-Command $tool -ErrorAction SilentlyContinue
        if ($command) {
            $lines.Add("- ${tool}: $($command.Source)")
        }
        else {
            $lines.Add("- ${tool}: not found")
        }
    }

    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        $lines.Add('')
        $lines.Add('## Scoop apps')
        $raw = (& scoop list 2>$null 6>$null | Out-String)
        $clean = $raw -replace "[$([char]27)]\[[0-9;]*m", ''
        $lines.Add($clean.TrimEnd())
    }

    $lines.Add('')
    $lines.Add('## Uninstall registry')
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = foreach ($path in $uninstallPaths) {
        Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            Select-Object DisplayName, DisplayVersion, Publisher
    }
    $lines.Add(($apps | Sort-Object DisplayName -Unique | Format-Table -AutoSize | Out-String -Width 220).TrimEnd())

    $lines.Add('')
    $lines.Add('## Running process names')
    $lines.Add(((Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', '))

    if ($ProcessPattern.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## Matching processes (full details)')
        $matches = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $text = "$($_.Name) $($_.ExecutablePath) $($_.CommandLine)"
            $hit = $false
            foreach ($pattern in $ProcessPattern) {
                if ($text -match $pattern) { $hit = $true; break }
            }
            $hit
        }
        foreach ($match in $matches) {
            $lines.Add("- $($match.ProcessId) $($match.Name)")
            $lines.Add("  path: $($match.ExecutablePath)")
            $lines.Add("  cmd: $($match.CommandLine)")
        }
    }

    if ($ServicePattern.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## Matching services')
        $matches = Get-Service -ErrorAction SilentlyContinue | Where-Object {
            $text = "$($_.Name) $($_.DisplayName)"
            $hit = $false
            foreach ($pattern in $ServicePattern) {
                if ($text -match $pattern) { $hit = $true; break }
            }
            $hit
        }
        foreach ($match in $matches) {
            $lines.Add("- $($match.Name) [$($match.Status)] $($match.DisplayName)")
        }
    }

    if ($ScanRoot.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## Scan roots (immediate children)')
        foreach ($root in $ScanRoot) {
            $lines.Add("- $root")
            if (Test-Path $root) {
                foreach ($child in (Get-ChildItem $root -Force -ErrorAction SilentlyContinue | Select-Object -First 100)) {
                    $lines.Add("  - $($child.Name)")
                }
            }
            else {
                $lines.Add('  - (missing)')
            }
        }
    }

    return ($lines -join "`n")
}

function Get-NetworkNote {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Network')
    $lines.Add('')
    $lines.Add('## IPv4 configuration')
    $configs = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4Address } | ForEach-Object {
        [PSCustomObject]@{
            Interface = $_.InterfaceAlias
            Index     = $_.InterfaceIndex
            IPv4      = ($_.IPv4Address.IPAddress -join ', ')
            Prefix    = ($_.IPv4Address.PrefixLength -join ', ')
            Gateway   = ($_.IPv4DefaultGateway.NextHop -join ', ')
            DNS       = ($_.DNSServer.ServerAddresses -join ', ')
        }
    }
    $lines.Add(($configs | Format-Table -AutoSize | Out-String -Width 220).TrimEnd())

    $lines.Add('')
    $lines.Add('## Adapters')
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object Status, Name |
        Select-Object Name, InterfaceIndex, Status, LinkSpeed, MacAddress
    $lines.Add(($adapters | Format-Table -AutoSize | Out-String -Width 200).TrimEnd())

    if (-not [string]::IsNullOrWhiteSpace($PublicIpUrl)) {
        $lines.Add('')
        $lines.Add('## Public egress')
        try {
            $info = Invoke-RestMethod -Uri $PublicIpUrl -TimeoutSec 12
            $lines.Add(($info | Select-Object ip, city, region, country, loc, org, timezone | Format-List | Out-String).TrimEnd())
        }
        catch {
            $lines.Add("- unavailable: $($_.Exception.Message)")
        }
    }

    if (Get-Command tailscale -ErrorAction SilentlyContinue) {
        $lines.Add('')
        $lines.Add('## Tailscale status')
        $tail = (& tailscale status 2>&1 | Out-String)
        $lines.Add($tail.TrimEnd())
    }

    $lines.Add('')
    $lines.Add('## Established connections by remote address')
    $connections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Group-Object RemoteAddress | Sort-Object Count -Descending | Select-Object -First 20 Count, Name
    $lines.Add(($connections | Format-Table -AutoSize | Out-String -Width 200).TrimEnd())

    $lines.Add('')
    $lines.Add('## Local sinkhole entries')
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $sinks = @(Get-Content $hostsPath -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^\s*127\.0\.0\.1' -and $_ -notmatch 'localhost' })
    $lines.Add("- 127.0.0.1 hosts entries (excluding localhost): $($sinks.Count)")
    foreach ($entry in ($sinks | Select-Object -First 10)) {
        $lines.Add("  $entry")
    }

    return ($lines -join "`n")
}

function Get-ReadmeNote {
    $lines = @(
        '# Private environment notes',
        '',
        'Generated by core/collect-environment-notes.ps1. Sensitive by design.',
        'Do not commit these files to a public repository.',
        '',
        '- host.md — host identity',
        '- software.md — package managers, installed apps, processes and services',
        '- network.md — adapters, public egress, tailnet, connections and hosts entries',
        '',
        "Remote location: $RemoteDir/$Label"
    )
    return ($lines -join "`n")
}

function Invoke-RemoteCommand {
    param([string]$Command)
    $opts = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'StrictHostKeyChecking=accept-new')
    & ssh @opts $RemoteHost $Command
    if ($LASTEXITCODE -ne 0) {
        throw "remote command failed: $Command"
    }
}

Test-SimpleToken -Value $Label -Name 'Label' -Pattern '^[A-Za-z0-9._-]+$'
Test-SimpleToken -Value $RemoteDir -Name 'RemoteDir' -Pattern '^~?[A-Za-z0-9._/~-]+$'
if ($ReadRemote -and -not $RemoteHost) {
    throw '-RemoteHost is required with -ReadRemote.'
}

if ($ReadRemote) {
    $target = "$RemoteDir/$Label"
    foreach ($name in @('README.md', 'host.md', 'software.md', 'network.md')) {
        Test-SimpleToken -Value $name -Name 'note name' -Pattern '^[A-Za-z0-9.-]+$'
        Write-Host "===== $name ====="
        Invoke-RemoteCommand -Command "cat $target/$name"
    }
    return
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Write-NoteFile -Name 'README.md' -Body (Get-ReadmeNote)
Write-NoteFile -Name 'host.md' -Body (Get-HostNote)
Write-NoteFile -Name 'software.md' -Body (Get-SoftwareNote)
Write-NoteFile -Name 'network.md' -Body (Get-NetworkNote)

$generated = @('README.md', 'host.md', 'software.md', 'network.md') -join ', '
if ($DryRun) {
    Write-Host "Collected locally in $OutDir ($generated); no upload performed."
    return
}
if (-not $RemoteHost) {
    throw '-RemoteHost is required for upload (use -DryRun for a local-only collection).'
}

$target = "$RemoteDir/$Label"
Invoke-RemoteCommand -Command "mkdir -p $RemoteDir $target && chmod 700 $RemoteDir $target"
$opts = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'StrictHostKeyChecking=accept-new')
& scp @opts -r (Join-Path $OutDir '.') "$RemoteHost`:$target/"
if ($LASTEXITCODE -ne 0) {
    throw 'scp upload failed'
}
Invoke-RemoteCommand -Command "chmod -R 700 $target && chmod 600 $target/*"

if (-not $KeepLocal) {
    Remove-Item -Recurse -Force $OutDir
}
Write-Host "Uploaded $generated to ${RemoteHost}:$target"
