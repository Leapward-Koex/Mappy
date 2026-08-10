[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$CommandArgs
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$wslRootOutput = @(& wsl.exe --exec wslpath -a -- $repoRoot)
if ($LASTEXITCODE -ne 0 -or $wslRootOutput.Count -eq 0) {
    throw "Could not translate the repository path for WSL."
}

$wslRoot = $wslRootOutput[-1].Trim()
if (-not $wslRoot.StartsWith("/")) {
    throw "WSL returned an invalid repository path: $wslRoot"
}

$runner = 'set -e; cd "$1"; shift; exec bash tooling/pebble-emulator-codex.sh "$@"'
& wsl.exe --exec bash -lc $runner mappy-pebble $wslRoot $Command @CommandArgs
exit $LASTEXITCODE
