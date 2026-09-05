[CmdletBinding()]
param(
    [string]$DeviceSerial,
    [string]$PhoneAddress,
    [switch]$BuildOnly,
    [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
if ($BuildOnly -and $CheckOnly) { throw "Choose either BuildOnly or CheckOnly." }

$watchRepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$watchDirectory = Join-Path $watchRepoRoot "apps/pebble-watch"
$wslOutput = @(& wsl.exe --exec wslpath -a -- ($watchRepoRoot -replace '\\', '/'))
if ($LASTEXITCODE -ne 0 -or $wslOutput.Count -eq 0) {
    throw "Could not translate the repository path for WSL."
}
$wslRoot = $wslOutput[-1].Trim()
if (-not $wslRoot.StartsWith("/")) { throw "WSL returned an invalid repository path." }
$wslInstaller = "$wslRoot/tooling/install-watch-release.sh"

& wsl.exe --exec bash -l $wslInstaller build
if ($LASTEXITCODE -ne 0) { throw "Watch release build failed; installation was not attempted." }
$package = Get-Content -LiteralPath (Join-Path $watchDirectory "package.json") -Raw | ConvertFrom-Json
$releaseName = "mappy-watch-$($package.version)-phone.pbw"
$releasePath = Join-Path $watchDirectory "dist/$releaseName"
if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) {
    throw "Build did not produce $releasePath."
}
Write-Host "Release PBW: $releasePath"
if ($BuildOnly) { return }

if (-not $PhoneAddress) {
    $adbCommand = Get-Command adb.exe -ErrorAction SilentlyContinue
    $adbPath = if ($adbCommand) { $adbCommand.Source } else {
        Join-Path $env:LOCALAPPDATA "Android/Sdk/platform-tools/adb.exe"
    }
    if (-not (Test-Path -LiteralPath $adbPath -PathType Leaf)) {
        throw "Install Android platform-tools, or supply -PhoneAddress with the Pebble developer connection address."
    }
    $deviceOutput = @(& $adbPath devices)
    if ($LASTEXITCODE -ne 0) { throw "ADB could not list devices." }
    $devices = @($deviceOutput | ForEach-Object {
        if ($_ -match '^(\S+)\s+device\s*$' -and $Matches[1] -notlike 'emulator-*') { $Matches[1] }
    })
    if ($DeviceSerial) {
        if ($DeviceSerial -notin $devices) { throw "Android device $DeviceSerial is not connected and authorized." }
    } elseif ($devices.Count -eq 1) {
        $DeviceSerial = $devices[0]
    } elseif ($devices.Count -eq 0) {
        throw "Connect an Android phone by USB and authorize USB debugging, or supply -PhoneAddress."
    } else {
        throw "Multiple phones are connected ($($devices -join ', ')). Set -DeviceSerial in launch.json args."
    }

    $addresses = @(& $adbPath -s $DeviceSerial shell ip -o -4 addr show wlan0)
    if ($LASTEXITCODE -ne 0) { throw "Could not read the phone Wi-Fi address." }
    $wifiAddress = [regex]::Match(($addresses -join [Environment]::NewLine), '\binet\s+(\d+\.\d+\.\d+\.\d+)/').Groups[1].Value
    if (-not $wifiAddress) { throw "Connect the phone and PC to the same LAN, or supply -PhoneAddress." }

    # Windows ADB forwarding is not WSL localhost under NAT. Use the phone's LAN endpoint.
    $response = @(& $adbPath -s $DeviceSerial shell am broadcast -a coredevices.coreapp.DEV_CONNECTION -n coredevices.coreapp/coredevices.coreapp.debug.DevConnectionReceiver)
    if ($LASTEXITCODE -ne 0) { throw "Could not start the Pebble app developer connection." }
    $responseText = $response -join [Environment]::NewLine
    $portMatch = [regex]::Match($responseText, 'result=0,\s*data="(\d+)"')
    if (-not $portMatch.Success) {
        $reason = [regex]::Match($responseText, 'data="([^"]+)"').Groups[1].Value
        if ($reason) { throw "Pebble app: $reason. Connect the watch in the Pebble app, then launch again." }
        throw "Open or update the Pebble app and connect the watch, or enable its developer connection and supply -PhoneAddress."
    }
    $PhoneAddress = "{0}:{1}" -f $wifiAddress, $portMatch.Groups[1].Value
    Write-Host "Phone: $DeviceSerial ($PhoneAddress)"
}
if ($PhoneAddress -notmatch '^[a-zA-Z0-9.-]+(?::[0-9]{1,5})?$') {
    throw "PhoneAddress must be a hostname or IPv4 address with optional :port, not a URL."
}
$operation = if ($CheckOnly) { "check" } else { "install" }
& wsl.exe --exec bash -l $wslInstaller $operation $PhoneAddress $releaseName
if ($LASTEXITCODE -ne 0) { throw "Watch $operation failed. Release PBW is available at $releasePath." }
if ($CheckOnly) { Write-Host "Watch connection verified. No app was installed." }
else { Write-Host "Release watch app installed successfully." }
