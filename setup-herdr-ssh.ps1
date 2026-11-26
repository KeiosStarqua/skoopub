#Requires -Version 5.1
<#
.SYNOPSIS
    Set up a temporary SSH key + Herdr remote for a machine on your tailnet.

.DESCRIPTION
    Meant for a public/internet-cafe Windows machine after `tailscale up`:

      - Lists the machines on the tailnet and asks you to choose the one that
        has Herdr inside.
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

.PARAMETER KeyDir
    Folder holding the temporary key pair (default: %TEMP%\skoop-herdr-ssh).

.PARAMETER SkipMachineAdd
    Only set up SSH/config; do not run `herdr machine add`.

.PARAMETER Revoke
    Undo the setup: remove the temporary public key from the remote, delete the
    local key pair and remove the marked Host block from ~/.ssh/config.

.EXAMPLE
    .\setup-herdr-ssh.ps1

.EXAMPLE
    .\setup-herdr-ssh.ps1 -Revoke -Alias muse
#>
[CmdletBinding()]
param(
    [string]$Alias,
    [string]$KeyDir = (Join-Path $env:TEMP 'skoop-herdr-ssh'),
    [switch]$SkipMachineAdd,
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

function Get-TailnetPeers {
    if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) { return @() }
    $raw = (& cmd /c 'tailscale status --json 2>&1' | Out-String)
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
    try { $status = $raw | ConvertFrom-Json } catch { return @() }
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

$peers = @(Get-TailnetPeers)
if ($peers.Count -eq 0) {
    Write-Warn 'No tailnet machines found. Run `tailscale up`, sign in, then re-run this script.'
    return
}
$peer = Select-Peer -Peers $peers
if (-not $peer) { return }

$name = if ($Alias) { $Alias } else { $peer.Alias }
$answer = Read-Host ("SSH user on {0} [{1}]" -f $peer.Dns, $env:USERNAME)
$user = if ($answer) { $answer } else { $env:USERNAME }

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

if (-not (Install-TempPublicKey -User $user -Ip $peer.Ip -PublicKey $publicKey)) {
    Write-Warn 'Remote authorization did not complete; stopping before the Herdr step.'
    return
}

Set-SshAlias -AliasName $name -Ip $peer.Ip -User $user -Key $key
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

Write-Host ''
Write-Host "Done. Use 'herdr --remote $name' or pick the machine in the Herdr sidebar." -ForegroundColor Green
Write-Host "This key is temporary: run '.\\setup-herdr-ssh.ps1 -Revoke -Alias $name' before leaving." -ForegroundColor Green
