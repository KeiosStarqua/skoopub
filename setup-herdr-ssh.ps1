#Requires -Version 5.1
<#
.SYNOPSIS
    Pick a machine from your tailnet and save it in Herdr over Tailscale SSH.

.DESCRIPTION
    Run this after signing in to Tailscale. It is the one-prompt path to a
    Herdr remote machine:

      - Lists peers from `tailscale status --json` and asks you to choose one.
        The CLI is resolved from PATH, Program Files and Scoop; if it cannot
        list peers, you are asked for the machine's Tailscale IP or MagicDNS
        name instead. Tailscale itself can still work without the CLI.
      - Silently probes a few SSH user names (from your git identity, the
        Windows user and root) to find one Tailscale SSH permits. No prompt,
        no password and no generated keys.
      - Runs `herdr machine add <user>@<machine> --label <machine>`, which
        prepares the remote Herdr server and stores the machine profile, so it
        shows up in the sidebar of every open Herdr client. Nothing is shelled
        into with `herdr --remote`, so this also works from inside a Herdr pane.
        An already-saved target is left untouched, which keeps re-runs safe.

    Nothing about a particular machine is stored in this repo: no name, no
    tailnet IP and no private key.

.PARAMETER Peer
    Tailscale IP or MagicDNS name of the target machine. Accepts user@host to
    preset the SSH user. Skips enumeration and the selection prompt.

.PARAMETER User
    SSH user to try first on the remote machine (otherwise auto-detected).

.EXAMPLE
    .\setup-herdr-ssh.ps1

.EXAMPLE
    .\setup-herdr-ssh.ps1 -Peer <machine-name>
#>
[CmdletBinding()]
param(
    [string]$Peer,
    [string]$User
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Warn([string]$Message) { Write-Host "    $Message" -ForegroundColor Yellow }

$script:TailscaleCliError = $null
$script:TailscaleBackend  = $null

function Resolve-TailscaleCli {
    # The official Windows installer does not add the CLI to PATH. Peer listing
    # is the only CLI-dependent step, so a missing CLI is not fatal.
    $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @()
    if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe' }
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Tailscale\tailscale.exe' }
    $scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
    $candidates += Join-Path $scoopRoot 'apps\tailscale\current\tailscale.exe'

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Test-TailscaleRunning {
    if (Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue) { return $true }
    return [bool](Get-Process -Name 'tailscaled', 'tailscale-ipn' -ErrorAction SilentlyContinue)
}

function Get-TailscaleStatus {
    $cli = Resolve-TailscaleCli
    if (-not $cli) {
        $script:TailscaleCliError = 'tailscale.exe was not found (PATH, Program Files or Scoop)'
        return $null
    }

    # cmd /c merges stderr without PS 5.1 turning it into a terminating error.
    $raw = (& cmd /c ('"{0}" status --json 2>&1' -f $cli) | Out-String)
    if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) {
        $line = ($raw -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if (-not $line) { $line = "exit code $LASTEXITCODE" }
        $script:TailscaleCliError = $line.Trim()
        return $null
    }
    try { return ($raw | ConvertFrom-Json) } catch {
        $script:TailscaleCliError = "could not parse 'tailscale status --json' output"
        return $null
    }
}

function Get-TailnetPeers {
    $status = Get-TailscaleStatus
    if (-not $status) { return @() }
    if ($status.BackendState) { $script:TailscaleBackend = "$($status.BackendState)" }
    if ($status.BackendState -and $status.BackendState -ne 'Running') { return @() }

    $peers = @()
    if ($status.Peer) {
        # `tailscale status --json` exposes peers as an object keyed by nodekey.
        foreach ($prop in $status.Peer.PSObject.Properties) {
            $peer = $prop.Value
            $ips = @($peer.TailscaleIPs)
            $ipv4 = $ips | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
            if (-not $ipv4) { $ipv4 = $ips | Select-Object -First 1 }
            $dns = "$($peer.DNSName)".TrimEnd('.')
            $label = ($dns -split '\.')[0]
            if (-not $label -or $label -eq 'localhost') { $label = "$($peer.HostName)" }
            $peers += [pscustomobject]@{
                Alias  = $label
                Dns    = $dns
                Ip     = "$ipv4"
                User   = ''
                Online = [bool]$peer.Online
            }
        }
    }
    return @($peers | Sort-Object -Property Online -Descending)
}

function New-ManualPeer {
    param([string]$Target)
    $target = "$Target".Trim()
    $sshUser = ''
    if ($target -match '^([^@]+)@(.+)$') { $sshUser = $Matches[1]; $target = $Matches[2] }
    $target = $target.TrimEnd('.')
    $label = if ($target -match '^\d+\.\d+\.\d+\.\d+$') { $target } else { ($target -split '\.')[0] }
    if (-not $label) { $label = $target }
    return [pscustomobject]@{
        Alias   = $label
        Dns     = $target
        Ip      = $target
        User    = $sshUser
        Online  = $true
    }
}

function Read-ManualPeer {
    if (-not [Environment]::UserInteractive) {
        Write-Warn 'Non-interactive shell - skipping Herdr remote setup.'
        return @()
    }
    Write-Host '    Enter the Tailscale IP (100.x.y.z) or MagicDNS name of the machine'
    Write-Host '    that has Herdr, or press Enter to skip.'
    $target = Read-Host 'Tailnet machine'
    if (-not $target) { return @() }
    return @(New-ManualPeer -Target $target)
}

function Select-Peer {
    param([object[]]$Peers)

    $labels = @()
    for ($i = 0; $i -lt $Peers.Count; $i++) {
        $p = $Peers[$i]
        $state = if ($p.Online) { 'online' } else { 'offline' }
        $labels += ('{0} ({1}) - {2}' -f $p.Dns, $p.Ip, $state)
    }
    if (-not [Environment]::UserInteractive) {
        Write-Warn 'Non-interactive shell - skipping Herdr remote setup.'
        return $null
    }

    # gum gives a real interactive picker (arrow keys / filtering). cmd /c
    # merges stderr so PS 5.1 does not turn gum output into a terminating error.
    $gum = Get-Command gum -ErrorAction SilentlyContinue
    if ($gum -and $env:SKOOP_NO_GUM -ne '1') {
        Write-Host 'Choose the machine that has Herdr inside:'
        $quoted = @($labels | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $cmdLine = '"{0}" choose --header "Herdr machine" {1} 2>&1' -f $gum.Source, $quoted
        try {
            $raw = (& cmd /c $cmdLine | Out-String)
            $lines = @($raw -split "`r?`n" | ForEach-Object { $_ -replace "`e\[[0-9;?]*[a-zA-Z]", '' })
            for ($i = 0; $i -lt $labels.Count; $i++) {
                if (@($lines | Where-Object { $_.Trim() -eq $labels[$i] }).Count -gt 0) {
                    return $Peers[$i]
                }
            }
            Write-Ok 'gum did not return a machine - using the numbered list'
        } catch {
            Write-Ok "gum picker failed ($($_.Exception.Message)) - using the numbered list"
        }
    }

    Write-Host 'Choose the machine that has Herdr inside:'
    for ($i = 0; $i -lt $Peers.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $labels[$i])
    }
    $answer = Read-Host 'Machine number (Enter to cancel)'
    if (-not $answer -or $answer -notmatch '^\d+$') { return $null }
    $n = [int]$answer
    if ($n -lt 1 -or $n -gt $Peers.Count) { throw "Invalid machine number: $answer" }
    return $Peers[$n - 1]
}

function Get-SshUserCandidates {
    param([string]$Preferred)

    $list = New-Object 'System.Collections.Generic.List[string]'
    function Add-Candidate([string]$value) {
        if ($value -and $value -notmatch '[@\s]' -and -not $list.Contains($value)) {
            $list.Add($value)
        }
    }

    if ($Preferred) { Add-Candidate $Preferred }
    $gitName = (& git config --global user.name 2>$null | Select-Object -First 1)
    if ($gitName) {
        Add-Candidate (($gitName -replace '[^A-Za-z0-9._-]', '').ToLowerInvariant())
    }
    $gitEmail = (& git config --global user.email 2>$null | Select-Object -First 1)
    if ($gitEmail -and $gitEmail -match '^([^@]+)@') { Add-Candidate $Matches[1].ToLowerInvariant() }
    if ($env:USERNAME) {
        Add-Candidate $env:USERNAME.ToLowerInvariant()
        Add-Candidate $env:USERNAME
    }
    Add-Candidate 'root'
    return $list.ToArray()
}

function Test-DirectSsh {
    param([string]$SshUser, [string]$HostName)

    $target = "$SshUser@$HostName"
    # BatchMode: never prompt for a password. Tailscale SSH answers with its
    # own auth; a rejected user exits non-zero with a policy message.
    $out = (& cmd /c ('ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "{0}" "echo __SKOOP_SSH_OK__" 2>&1' -f $target) | Out-String)
    return ($LASTEXITCODE -eq 0 -and $out -match '__SKOOP_SSH_OK__')
}

# --- Main --------------------------------------------------------------------
# Do not reuse $Peer here: it is a [string] parameter, so assigning a peer
# object to it would coerce the object to a string and lose its properties.
$selected = $null
if ($Peer) {
    $selected = New-ManualPeer -Target $Peer
} else {
    $peers = @(Get-TailnetPeers)
    if ($peers.Count -gt 0) {
        $selected = Select-Peer -Peers $peers
    } elseif ($script:TailscaleCliError) {
        Write-Warn "Tailscale CLI is not usable here: $($script:TailscaleCliError)"
        if (Test-TailscaleRunning) {
            Write-Warn 'Tailscale itself is running - the CLI is only used to list machines.'
            $manual = @(Read-ManualPeer)
            if ($manual.Count -gt 0) { $selected = $manual[0] }
        } else {
            Write-Warn 'Tailscale does not look installed or running either; skipping the Herdr remote setup.'
        }
    } elseif ($script:TailscaleBackend -and $script:TailscaleBackend -ne 'Running') {
        Write-Warn "Tailscale is not connected (state: $($script:TailscaleBackend)). Sign in from the Tailscale tray icon (or run ``tailscale up``), then re-run."
    } else {
        Write-Warn 'No tailnet machines found. Sign in to Tailscale, then re-run this script.'
    }
}
if (-not $selected) {
    Write-Ok 'Skipping the Herdr remote setup.'
    return
}

$hostName = if ($selected.Dns) { $selected.Dns } else { $selected.Ip }
$preferred = if ($User) { $User } elseif ($selected.User) { $selected.User } else { '' }
$sshUser = $null
foreach ($candidate in @(Get-SshUserCandidates -Preferred $preferred)) {
    Write-Ok "trying Tailscale SSH as $candidate@$hostName"
    if (Test-DirectSsh -SshUser $candidate -HostName $hostName) {
        $sshUser = $candidate
        break
    }
}

if (-not $sshUser) {
    Write-Warn "No permitted SSH user found on $hostName."
    Write-Warn 'On that machine run: tailscale set --ssh=true  (and check the tailnet SSH policy).'
    Write-Warn 'Or re-run this script with -User <name>.'
    return
}

Write-Ok "Tailscale SSH works as $sshUser@$hostName"
$herdr = Get-Command herdr -ErrorAction SilentlyContinue
if (-not $herdr) {
    Write-Warn ("herdr is not on PATH - add the machine manually with: herdr machine add {0}@{1} --label {1}" -f $sshUser, $hostName)
    return
}

# Save the machine inside Herdr instead of shelling in with `herdr --remote`:
# `herdr machine add` prepares the remote server, keeps the profile in the
# sidebar and works from inside a Herdr pane (no "nested herdr" refusal).
$target = "{0}@{1}" -f $sshUser, $hostName
$label  = if ($selected.Alias) { $selected.Alias } else { $hostName }

Write-Step "Adding $hostName to Herdr"
$listOutput = (& cmd /c ('"{0}" machine list 2>&1' -f $herdr.Source) | Out-String)
$alreadySaved = $false
foreach ($line in ($listOutput -split "`r?`n")) {
    $fields = @($line -split "`t")
    if ($fields.Count -ge 3 -and $fields[2].Trim() -eq $target) { $alreadySaved = $true; break }
}

if ($alreadySaved) {
    Write-Ok "already saved as $target - leaving the Herdr profile alone"
} else {
    $addOutput = (& cmd /c ('"{0}" machine add "{1}" --label "{2}" 2>&1' -f $herdr.Source, $target, $label) | Out-String)
    $addExit = $LASTEXITCODE
    foreach ($line in ($addOutput -split "`r?`n")) {
        if ($line.Trim()) { Write-Ok $line.Trim() }
    }
    if ($addExit -ne 0) {
        Write-Warn "herdr machine add failed (non-fatal); retry with: herdr machine add $target --label `"$label`""
        return
    }
    Write-Ok "saved as $label - open Herdr and pick it from the sidebar"
}
