[CmdletBinding()]
param(
    [string]$DeviceSerial,
    [string]$PhoneAddress,
    [switch]$BuildOnly,
    [switch]$CheckOnly
)
$ErrorActionPreference = "Stop"
if ($BuildOnly -and $CheckOnly) { throw "Choose either -BuildOnly or -CheckOnly." }
$watchRepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$watchDirectory = Join-Path $watchRepoRoot "apps/pebble-watch"
$wslOutput = @(& wsl.exe --exec wslpath -a -- ($watchRepoRoot -replace '\\', '/'))
if ($LASTEXITCODE -ne 0 -or $wslOutput.Count -eq 0) { throw "Could not locate the watch project in WSL." }
$wslInstaller = "$($wslOutput[-1].Trim())/tooling/install-watch-release.sh"

# Reuse the versioned production release target. Never install after a failed build.
& wsl.exe --exec bash -l $wslInstaller build
if ($LASTEXITCODE -ne 0) { throw "Watch release build failed; installation was not attempted." }
$package = Get-Content -LiteralPath (Join-Path $watchDirectory "package.json") -Raw | ConvertFrom-Json
$releaseName = "mappy-watch-$($package.version)-phone.pbw"
$releasePath = Join-Path $watchDirectory "dist/$releaseName"
if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) { throw "Release PBW is missing: $releasePath" }
Write-Host "Release PBW: $releasePath"
if ($BuildOnly) { return }

if (-not $PhoneAddress) {
    $adbCommand = Get-Command adb.exe -ErrorAction SilentlyContinue
    $adbPath = if ($adbCommand) { $adbCommand.Source } else {
        Join-Path $env:LOCALAPPDATA "Android/Sdk/platform-tools/adb.exe"
    }
    if (-not (Test-Path -LiteralPath $adbPath -PathType Leaf)) {
        throw "Install Android platform-tools or supply -PhoneAddress <phone-IP:port> with its Pebble developer connection enabled."
    }
    $deviceOutput = @(& $adbPath devices)
    if ($LASTEXITCODE -ne 0) { throw "ADB device discovery failed." }
    $devices = @($deviceOutput | ForEach-Object {
        if ($_ -match '^(\S+)\s+device\s*$' -and $Matches[1] -notlike 'emulator-*') { $Matches[1] }
    })
    if ($DeviceSerial) {
        if ($DeviceSerial -notin $devices) { throw "Android device '$DeviceSerial' is not connected and authorized (emulators are excluded)." }
    } elseif ($devices.Count -eq 1) {
        $DeviceSerial = $devices[0]
    } elseif ($devices.Count -eq 0) {
        throw "Connect an Android phone by USB, enable USB debugging, and accept its authorization prompt. Or supply -PhoneAddress <phone-IP:port>."
    } else {
        throw "Multiple phones are connected: $($devices -join ', '). Run with -DeviceSerial <serial>."
    }
    $addresses = @(& $adbPath -s $DeviceSerial shell ip -o -4 addr show wlan0)
    if ($LASTEXITCODE -ne 0) { throw "Could not read the phone's Wi-Fi address. Supply -PhoneAddress <phone-IP:port>." }
    $wifiAddress = [regex]::Match(($addresses -join [Environment]::NewLine), '\binet\s+(\d+\.\d+\.\d+\.\d+)/').Groups[1].Value
    if (-not $wifiAddress) { throw "Connect the phone to the PC's local network, or supply -PhoneAddress <phone-IP:port>." }
    # The same API used by Pebble Tool's --adb transport.
    $response = @(& $adbPath -s $DeviceSerial shell am broadcast -a coredevices.coreapp.DEV_CONNECTION -n coredevices.coreapp/coredevices.coreapp.debug.DevConnectionReceiver)
    if ($LASTEXITCODE -ne 0) { throw "The Pebble developer-connection request failed." }
    $portMatch = [regex]::Match(($response -join [Environment]::NewLine), 'result=0,\s*data="(\d+)"')
    if (-not $portMatch.Success) {
        $reason = [regex]::Match(($response -join [Environment]::NewLine), 'data="([^"]+)"').Groups[1].Value
        if ($reason) { throw "Pebble app: $reason. Connect the watch in the Pebble app, then run the task again." }
        throw "The Pebble app did not start its developer connection. Open/update the Pebble app, connect the watch, or enable its developer connection and supply -PhoneAddress."
    }
    $PhoneAddress = "{0}:{1}" -f $wifiAddress, $portMatch.Groups[1].Value
    Write-Host "Phone: $DeviceSerial ($PhoneAddress)"
}
if ($PhoneAddress -notmatch '^[a-zA-Z0-9.-]+(?::[0-9]{1,5})?$') {
    throw "PhoneAddress must be a host/IP, optionally followed by :port (not a URL)."
}

$operation = if ($CheckOnly) { "check" } else { "install" }
& wsl.exe --exec bash -l $wslInstaller $operation $PhoneAddress $releaseName
if ($LASTEXITCODE -ne 0) { throw "Watch $operation failed. The release PBW is available at $releasePath." }
if ($CheckOnly) { Write-Host "Watch connection verified. No app was installed." }
else { Write-Host "Release watch app installed successfully." }
