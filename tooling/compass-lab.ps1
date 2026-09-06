[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'install', 'capture')]
    [string]$Command = 'build',
    [string]$PhoneAddress,
    [string]$DeviceSerial
)
$ErrorActionPreference = 'Stop'
$compassRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$translated = @(& wsl.exe --exec wslpath -a -- ($compassRoot -replace '\\', '/'))
if ($LASTEXITCODE -ne 0 -or !$translated.Count) { throw 'Cannot translate workspace path for WSL.' }
$wslRoot = $translated[-1].Trim()
if (!$wslRoot.StartsWith('/')) { throw 'Invalid WSL workspace path.' }

if ($Command -in @('build', 'install')) {
    $build = 'set -e; cd "$1/apps/compass-lab"; unset COMPASS_LAB_TEST_INPUT; pebble build; mkdir -p dist; cp build/compass-lab.pbw dist/compass-lab-0.1.0.pbw'
    & wsl.exe --exec bash -lc $build compass-lab $wslRoot
    if ($LASTEXITCODE -ne 0) { throw 'Compass Lab build failed; installation was not attempted.' }
    Write-Host "PBW: $compassRoot\apps\compass-lab\dist\compass-lab-0.1.0.pbw"
    if ($Command -eq 'build') { return }
}

# USB is used only to discover the phone and open its Pebble developer bridge.
# Logging/installation goes through the phone's LAN connection to the watch.
if (!$PhoneAddress) {
    $adbCommand = Get-Command adb.exe -ErrorAction SilentlyContinue
    $adbPath = if ($adbCommand) { $adbCommand.Source } else {
        Join-Path $env:LOCALAPPDATA 'Android/Sdk/platform-tools/adb.exe'
    }
    if (!(Test-Path -LiteralPath $adbPath -PathType Leaf)) {
        throw 'Supply -PhoneAddress IP:port, or install Android platform-tools and connect the phone by USB.'
    }
    $deviceOutput = @(& $adbPath devices)
    if ($LASTEXITCODE -ne 0) { throw 'ADB could not list devices.' }
    $devices = @($deviceOutput | ForEach-Object {
        if ($_ -match '^(\S+)\s+device\s*$' -and $Matches[1] -notlike 'emulator-*') { $Matches[1] }
    })
    if ($DeviceSerial) {
        if ($DeviceSerial -notin $devices) { throw 'Requested Android device is not connected and authorized.' }
    } elseif ($devices.Count -eq 1) {
        $DeviceSerial = $devices[0]
    } else {
        throw 'Connect one Android phone with USB debugging, or supply -DeviceSerial or -PhoneAddress.'
    }
    $addresses = @(& $adbPath -s $DeviceSerial shell ip -o -4 addr show wlan0)
    if ($LASTEXITCODE -ne 0) { throw 'Could not read phone Wi-Fi address.' }
    $wifi = [regex]::Match(($addresses -join "`n"), '\binet\s+(\d+\.\d+\.\d+\.\d+)/').Groups[1].Value
    if (!$wifi) { throw 'Connect phone and PC to the same Wi-Fi, or supply -PhoneAddress.' }
    $reply = @(& $adbPath -s $DeviceSerial shell am broadcast -a coredevices.coreapp.DEV_CONNECTION -n coredevices.coreapp/coredevices.coreapp.debug.DevConnectionReceiver)
    if ($LASTEXITCODE -ne 0) { throw 'Could not open Pebble developer connection.' }
    $port = [regex]::Match(($reply -join "`n"), 'result=0,\s*data="(\d+)"').Groups[1].Value
    if (!$port) { throw 'Connect the watch in the Pebble app and enable its developer connection; alternatively supply -PhoneAddress IP:port.' }
    $PhoneAddress = "${wifi}:$port"
}
if ($PhoneAddress -notmatch '^[a-zA-Z0-9.-]+(?::[0-9]{1,5})?$') {
    throw 'PhoneAddress must be a hostname or IPv4 address with optional :port.'
}
if ($Command -eq 'install') {
    $install = 'set -e; cd "$1/apps/compass-lab"; unset PEBBLE_EMULATOR PEBBLE_ADB PEBBLE_BT_SERIAL PEBBLE_QEMU PEBBLE_PHONE PEBBLE_CLOUDPEBBLE; exec pebble install --phone "$2" dist/compass-lab-0.1.0.pbw'
    & wsl.exe --exec bash -lc $install compass-lab $wslRoot $PhoneAddress
} else {
    $capture = 'set -e; cd "$1"; unset PEBBLE_EMULATOR PEBBLE_ADB PEBBLE_BT_SERIAL PEBBLE_QEMU PEBBLE_PHONE PEBBLE_CLOUDPEBBLE; exec python3 tooling/compass-lab.py capture --phone "$2"'
    & wsl.exe --exec bash -lc $capture compass-lab $wslRoot $PhoneAddress
}
if ($LASTEXITCODE -ne 0) { throw "Compass Lab $Command failed (exit $LASTEXITCODE)." }
