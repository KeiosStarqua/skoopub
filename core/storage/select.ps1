#Requires -Version 5.1
<#
.SYNOPSIS
    Discover and rank fixed NTFS volumes for a Scoop installation.

.DESCRIPTION
    Dot-sourced by install.ps1. Selection is automatic by default: unhealthy,
    read-only, offline, game-labelled and non-writable volumes are skipped, as
    are volumes with less than -MinFreeGB free. Drives on another physical disk
    than Windows and dedicated "userdisk" volumes score higher. -Interactive
    shows a numbered prompt instead of picking the top score.

    Test-StorageWritable writes and flushes a small file before deleting it;
    FreeSpace alone is not trusted on public/overlay-managed machines.
#>

function Test-StorageWritable {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Bytes = 65536
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $probe = Join-Path $Path ('.skoop-storage-probe-' + [guid]::NewGuid())
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($probe, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $data = New-Object byte[] $Bytes
        $stream.Write($data, 0, $data.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        $read = [System.IO.File]::ReadAllBytes($probe)
        if ($read.Length -ne $Bytes) { return $false }
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    } finally {
        if ($stream) { $stream.Dispose() }
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
}

function Get-SkoopStorageCandidates {
    param(
        [int]$MinFreeGB = 30,
        [switch]$AllowGameDrives
    )

    $systemLetter = ([string]$env:SystemDrive).TrimEnd(':')
    $systemDisk = $null
    try { $systemDisk = (Get-Partition -DriveLetter $systemLetter -ErrorAction Stop).DiskNumber } catch { }

    $candidates = @()
    foreach ($volume in @(Get-Volume -ErrorAction Stop)) {
        $letter = $volume.DriveLetter
        if (-not $letter -or $volume.DriveType -ne 'Fixed' -or
            $volume.FileSystem -ne 'NTFS' -or $volume.HealthStatus -ne 'Healthy') { continue }
        if ($volume.SizeRemaining -lt ($MinFreeGB * 1GB)) { continue }

        $label = [string]$volume.FileSystemLabel
        if ($label -match 'GAME' -and -not $AllowGameDrives) { continue }

        $root = "$letter`:\"
        try {
            $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop
            $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
            if ($disk.IsReadOnly -or $disk.IsOffline) { continue }
        } catch { continue }

        # A reported free-space number is not proof that new files can be written.
        if (-not (Test-StorageWritable -Path $root)) { continue }

        $score = 0
        if ($null -ne $systemDisk -and $partition.DiskNumber -ne $systemDisk) { $score += 40 }
        if ($label -match 'userdisk') { $score += 50 }
        if ($letter -ne $systemLetter) { $score += 20 }
        # Cap capacity so a huge game/archive disk cannot outrank a userdisk.
        $score += [Math]::Min(20, [int]($volume.SizeRemaining / 1GB))

        $candidates += [pscustomobject]@{
            Drive      = "${letter}:"
            Label      = $label
            DiskNumber = $partition.DiskNumber
            FreeGB     = [math]::Round($volume.SizeRemaining / 1GB, 2)
            Score      = $score
            Root       = Join-Path $root 'skoopub'
        }
    }
    return $candidates
}

function Select-ScoopStorage {
    param(
        [int]$MinFreeGB = 30,
        [switch]$AllowGameDrives,
        [switch]$Interactive,
        [string]$OverrideRoot = ''
    )

    if ($OverrideRoot) {
        $drive = ([string]$OverrideRoot).Substring(0, 2)
        if (-not (Test-StorageWritable -Path $drive)) {
            throw "Storage root drive is not writable: $drive"
        }
        return [pscustomobject]@{
            Drive      = $drive
            Label      = '(manual override)'
            DiskNumber = -1
            FreeGB     = 0
            Score      = 999
            Root       = $OverrideRoot.TrimEnd('\')
        }
    }

    $candidates = @(Get-SkoopStorageCandidates -MinFreeGB $MinFreeGB -AllowGameDrives:$AllowGameDrives)
    if ($candidates.Count -eq 0) {
        throw "No suitable installation drive found (minimum $MinFreeGB GB free on a writable fixed NTFS volume)."
    }

    if ($Interactive) {
        Write-Host 'Available installation drives:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $c = $candidates[$i]
            Write-Host ('  [{0}] {1} {2} - {3:N2} GB free (score {4})' -f `
                ($i + 1), $c.Drive, $c.Label, $c.FreeGB, $c.Score)
        }
        do {
            $choice = Read-Host 'Select installation drive'
            $index = 0
            $valid = [int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $candidates.Count
        } until ($valid)
        return $candidates[$index - 1]
    }

    return ($candidates | Sort-Object Score, FreeGB -Descending | Select-Object -First 1)
}

function Show-SkoopStorageDiagnostics {
    param(
        [int]$MinFreeGB = 30,
        [switch]$AllowGameDrives
    )

    foreach ($volume in @(Get-Volume -ErrorAction Stop)) {
        if (-not $volume.DriveLetter) { continue }
        $letter = $volume.DriveLetter
        $root = "$letter`:\"
        $label = [string]$volume.FileSystemLabel
        $reasons = @()
        if ($volume.DriveType -ne 'Fixed') { $reasons += 'not fixed' }
        if ($volume.FileSystem -ne 'NTFS') { $reasons += 'not NTFS' }
        if ($volume.HealthStatus -ne 'Healthy') { $reasons += 'unhealthy' }
        if ($volume.SizeRemaining -lt ($MinFreeGB * 1GB)) { $reasons += "under ${MinFreeGB} GB free" }
        if ($label -match 'GAME' -and -not $AllowGameDrives) { $reasons += 'game drive excluded' }
        if (-not (Test-StorageWritable -Path $root)) { $reasons += 'not writable' }
        [pscustomobject]@{
            Drive    = "${letter}:"
            Label    = $label
            FreeGB   = [math]::Round($volume.SizeRemaining / 1GB, 2)
            Writable = (Test-StorageWritable -Path $root)
            Eligible = ($reasons.Count -eq 0)
            Reasons  = ($reasons -join ', ')
        }
    }
}
