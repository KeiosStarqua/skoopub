#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only Windows HID/mouse driver diagnostics for skoopub-mouse.

.DESCRIPTION
    Inspects the PnP device, driver INF/version/provider, the device parent chain,
    mouse/HID/USB class filters (third-party hooks), driver image signatures and
    recent Kernel-PnP/USB/HID event-log entries. Nothing is changed: no driver,
    registry value, service or cafe-management software is modified.

.EXAMPLE
    .\apps\mouse\driver.ps1 inspect
    .\apps\mouse\driver.ps1 filters
    .\apps\mouse\driver.ps1 report -Out "$env:TEMP\driver-report.json"
#>
[CmdletBinding()]
param(
    [ValidateSet('inspect', 'stack', 'filters', 'integrity', 'events', 'report')]
    [string]$Action = 'report',
    [string]$MouseVidPid = 'VID_046D&PID_C08F',
    [int]$Days = 7,
    [switch]$Deep,
    [switch]$Json,
    [string]$Out
)

$ErrorActionPreference = 'Stop'

function Get-OutputDir {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = Join-Path $env:USERPROFILE 'AppData\Local' }
    return (Join-Path $base 'skoop\mouse')
}

function Get-MouseDevices {
    $pattern = [regex]::Escape($MouseVidPid)
    $present = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue
    $matches = @($present | Where-Object {
        $_.InstanceId -match $pattern -or ($_.Class -eq 'Mouse' -and $_.FriendlyName -match 'mouse')
    })
    if ($matches.Count -eq 0) {
        $matches = @($present | Where-Object { $_.Class -eq 'Mouse' })
    }
    return $matches
}

function Get-PropertyValue {
    param([string]$InstanceId, [string]$Key)
    try {
        $value = (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $Key -ErrorAction Stop).Data
        return $value
    } catch {
        return $null
    }
}

function Get-DeviceInspect {
    $rows = @()
    foreach ($device in Get-MouseDevices) {
        $rows += [pscustomobject]@{
            Name        = $device.FriendlyName
            Class       = $device.Class
            Status      = $device.Status
            Problem     = $device.Problem
            InstanceId  = $device.InstanceId
            Parent      = Get-PropertyValue $device.InstanceId 'DEVPKEY_Device_Parent'
            Service     = Get-PropertyValue $device.InstanceId 'DEVPKEY_Device_Service'
            InfPath     = Get-PropertyValue $device.InstanceId 'DEVPKEY_Device_DriverInfPath'
            DriverVersion = Get-PropertyValue $device.InstanceId 'DEVPKEY_Device_DriverVersion'
            DriverProvider = Get-PropertyValue $device.InstanceId 'DEVPKEY_Device_DriverProvider'
            DriverDate  = Get-PropertyValue $device.InstanceId 'DEVPKEY_Device_DriverDate'
            BusReported = Get-PropertyValue $device.InstanceId 'DEVPKEY_Device_BusReportedDeviceDesc'
        }
    }
    return $rows
}

function Get-DeviceStack {
    $rows = @()
    $seen = @{}
    foreach ($device in Get-MouseDevices) {
        $current = $device.InstanceId
        $depth = 0
        while ($current -and $depth -lt 12 -and -not $seen.ContainsKey($current)) {
            $seen[$current] = $true
            $pnp = Get-PnpDevice -InstanceId $current -ErrorAction SilentlyContinue
            $parent = Get-PropertyValue $current 'DEVPKEY_Device_Parent'
            $name = ''
            $class = ''
            $status = ''
            if ($pnp) {
                $name = $pnp.FriendlyName
                $class = $pnp.Class
                $status = $pnp.Status
            }
            $rows += [pscustomobject]@{
                Depth      = $depth
                Name       = $name
                Class      = $class
                Status     = $status
                Service    = Get-PropertyValue $current 'DEVPKEY_Device_Service'
                InstanceId = $current
            }
            $current = $parent
            $depth++
        }
    }
    return $rows
}

function Get-DriverFilters {
    $classes = @(
        [pscustomobject]@{ Name = 'Mouse';    Guid = '{4D36E96F-E325-11CE-BFC1-08002BE10318}'; Allowed = @('mouclass') },
        [pscustomobject]@{ Name = 'HIDClass'; Guid = '{745A17A0-74D3-11D0-B6FE-00A0C90F57DA}'; Allowed = @() },
        [pscustomobject]@{ Name = 'USB';      Guid = '{36FC9E60-C465-11CF-8056-444553540000}'; Allowed = @('usbccgp') }
    )
    $rows = @()
    foreach ($class in $classes) {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$($class.Guid)"
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
        $upper = @($item.UpperFilters | Where-Object { $_ })
        $lower = @($item.LowerFilters | Where-Object { $_ })
        foreach ($kind in @(
            [pscustomobject]@{ Kind = 'Upper'; Values = $upper },
            [pscustomobject]@{ Kind = 'Lower'; Values = $lower }
        )) {
            if ($kind.Values.Count -eq 0) {
                $rows += [pscustomobject]@{ Class = $class.Name; Kind = $kind.Kind; Filter = '(none)'; ThirdParty = $false }
                continue
            }
            foreach ($filter in $kind.Values) {
                $thirdParty = -not ($class.Allowed -contains $filter)
                $rows += [pscustomobject]@{ Class = $class.Name; Kind = $kind.Kind; Filter = $filter; ThirdParty = $thirdParty }
            }
        }
    }
    return $rows
}

function Expand-DriverPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    $value = $Path.Trim('"')
    $value = [Environment]::ExpandEnvironmentVariables($value)
    if ($value -match '^\\SystemRoot\\') { $value = $value -replace '^\\SystemRoot\\', "$env:SystemRoot\" }
    if ($value -match '^System32\\') { $value = Join-Path $env:SystemRoot $value }
    return $value
}

function Get-DriverIntegrity {
    $rows = @()
    $paths = @{}
    $services = Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^(hid|mou|usb|logi|rz|kbd)' -or $_.PathName -match 'hid|mou|logi|razer'
    }
    foreach ($service in $services) {
        $path = Expand-DriverPath $service.PathName
        if ($path -and -not $paths.ContainsKey($path)) {
            $paths[$path] = [pscustomobject]@{ Service = $service.Name; ImagePath = $path }
        }
    }
    foreach ($mouse in Get-MouseDevices) {
        $image = Get-PropertyValue $mouse.InstanceId 'DEVPKEY_Device_Service'
        if (-not $image) { continue }
        $service = Get-CimInstance Win32_SystemDriver -Filter "Name='$image'" -ErrorAction SilentlyContinue
        if ($service) {
            $path = Expand-DriverPath $service.PathName
            if ($path -and -not $paths.ContainsKey($path)) {
                $paths[$path] = [pscustomobject]@{ Service = $service.Name; ImagePath = $path }
            }
        }
    }
    foreach ($entry in $paths.Values) {
        $status = 'missing'
        $signer = ''
        $version = ''
        if (Test-Path -LiteralPath $entry.ImagePath) {
            try {
                $sig = Get-AuthenticodeSignature -LiteralPath $entry.ImagePath -ErrorAction Stop
                $status = "$($sig.Status)"
                if ($sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject }
            } catch {
                $status = "error: $($_.Exception.Message)"
            }
            try {
                $info = (Get-Item -LiteralPath $entry.ImagePath -ErrorAction Stop).VersionInfo
                if ($info.FileVersion) { $version = $info.FileVersion }
            } catch { }
        }
        $rows += [pscustomobject]@{
            Service   = $entry.Service
            ImagePath = $entry.ImagePath
            Signature = $status
            Signer    = $signer
            Version   = $version
        }
    }
    if ($Deep) {
        $rows += [pscustomobject]@{
            Service   = 'sfc /verifyonly'
            ImagePath = '(system scan)'
            Signature = (cmd /c 'sfc /verifyonly 2>&1' | Select-Object -Last 5) -join ' | '
            Signer    = ''
            Version   = ''
        }
    }
    return $rows
}

function Get-DriverEvents {
    $since = (Get-Date).AddDays(-1 * [Math]::Max(1, $Days))
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName = 'System'; StartTime = $since; Level = 1, 2, 3
    } -ErrorAction SilentlyContinue | Where-Object {
        $_.ProviderName -match 'HID|USB|Kernel-PnP|mou|disk|volmgr|WHEA' -or
        $_.Message -match 'HID|USB|mouse|hidusb|mouhid|mouclass'
    })
    $recent = @($events | Sort-Object TimeCreated -Descending | Select-Object -First 25 | ForEach-Object {
        [pscustomobject]@{
            Time     = $_.TimeCreated
            Id       = $_.Id
            Provider = $_.ProviderName
            Level    = $_.LevelDisplayName
            Message  = (($_.Message -split "`r?`n")[0])
        }
    })
    $summary = @($events | Group-Object ProviderName, Id | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{ Count = $_.Count; Provider = $_.Name }
    })
    return [pscustomobject]@{ Summary = $summary; Recent = $recent }
}

function New-DriverReport {
    $inspect = @(Get-DeviceInspect)
    $stack = @(Get-DeviceStack)
    $filters = @(Get-DriverFilters)
    $integrity = @(Get-DriverIntegrity)
    $events = Get-DriverEvents
    return [pscustomobject]@{
        generated_at  = (Get-Date).ToString('o')
        computer      = $env:COMPUTERNAME
        mouse_vid_pid = $MouseVidPid
        inspect       = $inspect
        stack         = $stack
        filters       = $filters
        integrity     = $integrity
        events        = $events
        notes         = @(
            'Read-only: this script does not change drivers, services, registry values or cafe software.',
            'A third-party UpperFilters/LowerFilters entry sits in the HID/Mouse/USB stack even when its app is closed.',
            'Use -Deep to also run sfc /verifyonly (slow, needs an elevated shell).'
        )
    }
}

function Show-Table {
    param($InputObject, [string[]]$Columns)
    if (-not $InputObject -or @($InputObject).Count -eq 0) {
        Write-Host '    (no data)'
        return
    }
    if ($Columns) {
        $InputObject | Select-Object $Columns | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    } else {
        $InputObject | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    }
}

$result = $null
switch ($Action) {
    'inspect'   { $result = [pscustomobject]@{ action = 'inspect'; data = @(Get-DeviceInspect) } }
    'stack'     { $result = [pscustomobject]@{ action = 'stack'; data = @(Get-DeviceStack) } }
    'filters'   { $result = [pscustomobject]@{ action = 'filters'; data = @(Get-DriverFilters) } }
    'integrity' { $result = [pscustomobject]@{ action = 'integrity'; data = @(Get-DriverIntegrity) } }
    'events'    { $result = [pscustomobject]@{ action = 'events'; data = Get-DriverEvents } }
    'report'    { $result = New-DriverReport }
}

if ($Action -eq 'report' -or $Json) {
    $jsonText = $result | ConvertTo-Json -Depth 8
    if ($Action -eq 'report') {
        $path = $Out
        if (-not $path) { $path = Join-Path (Get-OutputDir) 'driver-report.json' }
        New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
        Set-Content -LiteralPath $path -Value $jsonText -Encoding UTF8
        Write-Host "driver report written to $path"
    }
    Write-Output $jsonText
    return
}

switch ($Action) {
    'inspect' { Show-Table $result.data 'Name','Class','Status','Service','InfPath','DriverVersion','DriverProvider' }
    'stack'   { Show-Table $result.data 'Depth','Name','Class','Status','Service' }
    'filters' {
        Show-Table $result.data 'Class','Kind','Filter','ThirdParty'
        $bad = @($result.data | Where-Object { $_.ThirdParty })
        if ($bad.Count -gt 0) {
            Write-Host "    third-party filter(s) detected: $(($bad | ForEach-Object { $_.Filter }) -join ', ')" -ForegroundColor Yellow
        }
    }
    'integrity' { Show-Table $result.data 'Service','Signature','Version','ImagePath' }
    'events'    {
        Write-Host 'Summary:'
        Show-Table $result.data.Summary 'Count','Provider'
        Write-Host 'Recent:'
        Show-Table $result.data.Recent 'Time','Id','Provider','Level','Message'
    }
}
