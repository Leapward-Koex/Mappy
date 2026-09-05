[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DeviceSerial,
    [string]$JavaHome = $env:JAVA_HOME,
    [switch]$IncludeCorpus
)

$ErrorActionPreference = "Stop"
$tileRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$previousSerial = $env:ANDROID_SERIAL
$previousJava = $env:JAVA_HOME
$previousBenchmark = $env:MAPPY_TILE_BENCHMARK
try {
    # A separate application ID preserves the installed app and its preferences.
    $env:ANDROID_SERIAL = $DeviceSerial
    if ($JavaHome) { $env:JAVA_HOME = $JavaHome }
    if ($IncludeCorpus) { $env:MAPPY_TILE_BENCHMARK = "1" }
    Push-Location (Join-Path $tileRoot "apps/mobile-companion/android")
    try {
        $tileExtraArgs = if ($IncludeCorpus) { @("--rerun-tasks") } else { @() }
        & .\gradlew.bat :app:testDebugUnitTest :app:connectedDebugAndroidTest `
            '-PmappyTileBenchmark=true' `
            '-Pandroid.testInstrumentationRunnerArguments.class=com.leapwardkoex.mappy.TilePipelineInstrumentedTest' `
            --console=plain @tileExtraArgs
        if ($LASTEXITCODE -ne 0) { throw "Android tile checks failed (exit $LASTEXITCODE)." }
    } finally { Pop-Location }
} finally {
    $env:ANDROID_SERIAL = $previousSerial
    $env:JAVA_HOME = $previousJava
    $env:MAPPY_TILE_BENCHMARK = $previousBenchmark
}
