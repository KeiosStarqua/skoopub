#Requires -Version 5.1
<#
.SYNOPSIS
    Set up a temporary SSH key + Herdr remote for a machine on your tailnet.

.DESCRIPTION
    Meant for a public/internet-cafe Windows machine after `tailscale up`:

      - Lists the machines on the tailnet with `tailscale status --json` and asks
        you to choose the one that has Herdr inside. If the Windows CLI is not on
        PATH or cannot talk to the daemon, you are asked for the machine's
        Tailscale IP / MagicDNS name instead - Tailscale itself can still work.
        Use -Peer to provide that address up front and skip the listing entirely.
      - Asks for the SSH user on that machine.
      - Creates a temporary ed25519 key pair under %TEMP% (the private key never
        leaves this machine).
      - Runs ssh to add the public key to the home machine's authorized_keys.
        SSH prompts you for the password - type it when asked.
      - Adds a marked `Host <alias>` block to ~/.ssh/config using that key.
      - Registers the alias with `herdr machine add` so it appears in Herdr.

    Use -Revoke to remove the temporary key from the remote, delete the local
    key pair and remove the Host block again.

.PARAMETER Alias
    Alias for the SSH Host / Herdr machine. Defaults to the machine's DNS label.

.PARAMETER Peer
    Tailscale IP (100.x.y.z) or MagicDNS name of the machine that has Herdr.
    Accepts user@host to preset the SSH user. Skips `tailscale status --json`,
    which is useful when the Windows CLI is unavailable.

.PARAMETER KeyDir
    Folder holding the temporary key pair (default: %TEMP%\skoop-herdr-ssh).

.PARAMETER SkipMachineAdd
    Only set up SSH/config; do not run `herdr machine add`.

.PARAMETER Attach
    After registering the machine, open the remote session with
    `herdr --remote <alias>` immediately. Without this switch the script asks
    first (default No), so it never blocks an unattended bootstrap.

.PARAMETER Revoke
    Undo the setup: remove the temporary public key from the remote, delete the
    local key pair and remove the marked Host block from ~/.ssh/config.

.EXAMPLE
    .\setup-herdr-ssh.ps1

.EXAMPLE
    .\setup-herdr-ssh.ps1 -Peer muse -Alias muse

.EXAMPLE
    .\setup-herdr-ssh.ps1 -Revoke -Alias muse
#>
[CmdletBinding()]
param(
    [string]$Alias,
    [string]$Peer,
    [string]$KeyDir = (Join-Path $env:TEMP 'skoop-herdr-ssh'),
    [switch]$SkipMachineAdd,
    [switch]$Attach,
    [switch]$Revoke
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$Comment               = 'skoop-temp-herdr'

$sshDir     = Join-Path $env:USERPROFILE '.ssh'
$configPath = Join-Path $sshDir 'config'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Warn([string]$Message) { Write-Host "    $Message" -ForegroundColor Yellow }

$script:TailscaleCliError = $null
$script:TailscaleBackend  = $null

function Resolve-TailscaleCli {
    # The official Windows installer does not add the CLI to PATH. Look in the
    # usual places before giving up; the CLI is only used to list peers, never
    # to change the network, so a missing/broken one is not fatal.
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
    # Quoting the path once is correct even when it contains spaces.
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
                User   = "$($peer.HostName)"
                Online = [bool]$peer.Online
            }
        }
    }
    return @($peers | Sort-Object -Property Online -Descending)
}

function New-ManualPeer {
    # Without the CLI we cannot enumerate peers, but SSH only needs the address.
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
        User    = $target
        Online  = $true
        SshUser = $sshUser
    }
}

function Read-ManualPeer {
    if (-not [Environment]::UserInteractive) {
        Write-Warn 'Non-interactive shell - skipping Herdr SSH setup.'
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

    Write-Host 'Choose the machine that has Herdr inside:'
    for ($i = 0; $i -lt $Peers.Count; $i++) {
        $p = $Peers[$i]
        $state = if ($p.Online) { 'online' } else { 'offline' }
        Write-Host ('  [{0}] {1} ({2}) - {3}' -f ($i + 1), $p.Dns, $p.Ip, $state)
    }
    if (-not [Environment]::UserInteractive) {
        Write-Warn 'Non-interactive shell - skipping Herdr SSH setup.'
        return $null
    }
    $answer = Read-Host 'Machine number (Enter to cancel)'
    if (-not $answer -or $answer -notmatch '^\d+$') { return $null }
    $n = [int]$answer
    if ($n -lt 1 -or $n -gt $Peers.Count) { throw "Invalid machine number: $answer" }
    return $Peers[$n - 1]
}

function Get-ConfigBlock {
    param([string[]]$Lines, [string]$AliasName)

    $start = "# >>> skoop-herdr $AliasName"
    $end   = "# <<< skoop-herdr $AliasName"
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -eq $start) {
            $j = $i
            while ($j -lt $Lines.Count -and $Lines[$j] -ne $end) { $j++ }
            $block = @($Lines[$i..$j])
            $hostLine = $block | Where-Object { $_ -match '^\s*HostName\s+' } | Select-Object -First 1
            $userLine = $block | Where-Object { $_ -match '^\s*User\s+' } | Select-Object -First 1
            return @{
                Start = $i
                End   = $j
                Host  = "$hostLine" -replace '^\s*HostName\s+', ''
                User  = "$userLine" -replace '^\s*User\s+', ''
            }
        }
    }
    return $null
}

function Remove-ConfigBlock {
    param([string[]]$Lines, [int]$Start, [int]$End)

    $out = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($i -lt $Start -or $i -gt $End) { $out += $Lines[$i] }
    }
    return $out
}

function Write-SshConfig {
    param([string[]]$Lines)

    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    # UTF8 without BOM: OpenSSH rejects a BOM before the first Host directive.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($configPath, (($Lines -join "`n") + "`n"), $utf8NoBom)
}

function Set-SshAlias {
    param([string]$AliasName, [string]$Ip, [string]$User, [string]$Key)

    $lines = if (Test-Path -LiteralPath $configPath) { @(Get-Content -LiteralPath $configPath) } else { @() }
    $old = Get-ConfigBlock -Lines $lines -AliasName $AliasName
    if ($old) { $lines = @(Remove-ConfigBlock -Lines $lines -Start $old.Start -End $old.End) }

    $body = (($lines | Where-Object { $_.Trim() }) -join "`n").TrimEnd()
    $block = @(
        "# >>> skoop-herdr $AliasName",
        "Host $AliasName",
        "    HostName $Ip",
        "    User $User",
        "    IdentityFile $Key",
        "    IdentitiesOnly yes",
        "# <<< skoop-herdr $AliasName"
    ) -join "`n"
    $desired = if ($body) { "$body`n`n$block" } else { $block }

    $existing = if (Test-Path -LiteralPath $configPath) { (Get-Content -Raw -LiteralPath $configPath).TrimEnd() } else { '' }
    if ($existing -eq $desired) {
        Write-Ok "$configPath already up to date"
    } else {
        Write-SshConfig -Lines @($desired)
        Write-Ok "added Host $AliasName -> $User@$Ip"
    }
}

function Install-TempPublicKey {
    param([string]$User, [string]$Ip, [string]$PublicKey)

    $remote = "$User@$Ip"
    Write-Step "Authorizing the temporary key on $remote"
    Write-Host '    SSH will ask for your password - type it to install the key on your home machine.'
    # Pass the key inside a single-quoted remote string; it contains no quotes.
    $remoteCmd = "mkdir -p ~/.ssh && echo '$PublicKey' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
    & ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no $remote $remoteCmd
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Could not install the key on $remote (ssh exit $LASTEXITCODE)."
        Write-Warn "On your home machine, run: echo '$PublicKey' >> ~/.ssh/authorized_keys"
        return $false
    }
    Write-Ok 'temporary public key installed on the remote machine'
    return $true
}

function Revoke-TempSetup {
    param([string]$AliasName)

    $lines = if (Test-Path -LiteralPath $configPath) { @(Get-Content -LiteralPath $configPath) } else { @() }
    $block = Get-ConfigBlock -Lines $lines -AliasName $AliasName
    if (-not $block) {
        Write-Warn "No skoop-herdr block for '$AliasName' in $configPath"
        return
    }

    $key = Join-Path $KeyDir 'id_ed25519'
    if (Test-Path "$key.pub") {
        $publicKey = (Get-Content -LiteralPath "$key.pub" -Raw).Trim()
        Write-Step "Removing the temporary key from $($block.User)@$($block.Host)"
        $remoteCmd = "grep -v -F '$publicKey' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.skoop.tmp && mv ~/.ssh/authorized_keys.skoop.tmp ~/.ssh/authorized_keys"
        & ssh -i $key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "$($block.User)@$($block.Host)" $remoteCmd
        if ($LASTEXITCODE -ne 0) { Write-Warn "Could not remove the remote key (ssh exit $LASTEXITCODE); remove it from authorized_keys by hand." }
    }
    Remove-Item -LiteralPath "$key", "$key.pub" -Force -ErrorAction SilentlyContinue

    $lines = @(Remove-ConfigBlock -Lines $lines -Start $block.Start -End $block.End)
    Write-SshConfig -Lines $lines
    Write-Ok "removed Host $AliasName and the local key pair"
    Write-Host '    Also drop the saved machine in Herdr: herdr machine list -> herdr machine remove <id>' -ForegroundColor Yellow
}

# --- Main --------------------------------------------------------------------
if ($Revoke) {
    $name = if ($Alias) { $Alias } else { Read-Host 'Alias to revoke' }
    if (-not $name) { throw 'An alias is required for -Revoke.' }
    Revoke-TempSetup -AliasName $name
    return
}

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
            Write-Warn 'Tailscale does not look installed or running either; skipping the Herdr SSH setup.'
        }
    } elseif ($script:TailscaleBackend -and $script:TailscaleBackend -ne 'Running') {
        Write-Warn "Tailscale is not connected (state: $($script:TailscaleBackend)). Sign in from the Tailscale tray icon (or run ``tailscale up``), then re-run."
    } else {
        Write-Warn 'No tailnet machines found. Sign in to Tailscale, then re-run this script.'
    }
}
if (-not $selected) {
    Write-Ok 'Skipping the Herdr SSH setup.'
    return
}

$name = if ($Alias) { $Alias } else { $selected.Alias }
$defaultUser = if ($selected.SshUser) { $selected.SshUser } else { $env:USERNAME }
$answer = Read-Host ("SSH user on {0} [{1}]" -f $selected.Dns, $defaultUser)
$user = if ($answer) { $answer } else { $defaultUser }

New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
$key = Join-Path $KeyDir 'id_ed25519'
if (-not (Test-Path $key)) {
    Write-Step 'Creating a temporary SSH key pair on this machine'
    & cmd /c ('ssh-keygen -t ed25519 -N "" -C "{0}" -f "{1}"' -f $Comment, $key) | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$key.pub")) { throw 'ssh-keygen failed.' }
    Write-Ok "key pair created under $KeyDir"
} else {
    Write-Ok "reusing the temporary key at $key"
}
$publicKey = (Get-Content -LiteralPath "$key.pub" -Raw).Trim()

if (-not (Install-TempPublicKey -User $user -Ip $selected.Ip -PublicKey $publicKey)) {
    Write-Warn 'Remote authorization did not complete; stopping before the Herdr step.'
    return
}

Set-SshAlias -AliasName $name -Ip $selected.Ip -User $user -Key $key
Write-Ok "test it with: ssh $name"

if (-not $SkipMachineAdd) {
    $herdr = Get-Command herdr -ErrorAction SilentlyContinue
    if (-not $herdr) {
        Write-Warn 'herdr is not on PATH - skipping machine registration.'
    } else {
        Write-Step "Registering $name with Herdr"
        & herdr machine add $name
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "herdr machine add failed (non-fatal); run it yourself: herdr machine add $name"
        }
    }
}

# --- Attach to the chosen Herdr machine (opt-in) ----------------------------
if (($Attach -or -not $SkipMachineAdd) -and (Get-Command herdr -ErrorAction SilentlyContinue)) {
    if (-not $Attach -and [Environment]::UserInteractive) {
        $attachAnswer = Read-Host "Attach to $name with 'herdr --remote' now? [y/N]"
        if ($attachAnswer -match '^(y|yes)$') { $Attach = $true }
    }
    if ($Attach) {
        Write-Step "Attaching to $name"
        & herdr --remote $name
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "herdr --remote failed (non-fatal); retry with: herdr --remote $name"
        }
    }
}

Write-Host ''
Write-Host "Done. Use 'herdr --remote $name' or pick the machine in the Herdr sidebar." -ForegroundColor Green
Write-Host "This key is temporary: run '.\\setup-herdr-ssh.ps1 -Revoke -Alias $name' before leaving." -ForegroundColor Green
