[CmdletBinding()]
param(
    [switch]$SkipPackageGeneration
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$iconDirectory = Join-Path $projectRoot 'icon'
$sourceSvg = Join-Path $iconDirectory 'drawing.svg'
$launcherPng = Join-Path $iconDirectory 'icon_1024_1024.png'
$foregroundPng = Join-Path $iconDirectory 'icon_foreground.png'
$monochromePng = Join-Path $iconDirectory 'icon_monochrome.png'
$notificationDrawable = Join-Path $projectRoot 'android/app/src/main/res/drawable/ic_stat_mappy.xml'
$invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Remove-SvgLayer {
    param(
        [Parameter(Mandatory)]
        [xml]$Document,

        [Parameter(Mandatory)]
        [string]$Id
    )

    $layer = $Document.SelectSingleNode("//*[@id='$Id']")
    if ($null -eq $layer) {
        throw "SVG layer '$Id' was not found in $sourceSvg."
    }
    [void]$layer.ParentNode.RemoveChild($layer)
}

function Export-SvgPng {
    param(
        [Parameter(Mandatory)]
        [xml]$Document,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $temporarySvg = Join-Path ([System.IO.Path]::GetTempPath()) (
        'mappy-icon-' + [System.Guid]::NewGuid().ToString('N') + '.svg'
    )
    try {
        $Document.Save($temporarySvg)
        & magick -background none -density 96 $temporarySvg -resize '1024x1024!' $Destination
        if ($LASTEXITCODE -ne 0) {
            throw "ImageMagick failed while creating $Destination."
        }
    }
    finally {
        Remove-Item -LiteralPath $temporarySvg -ErrorAction SilentlyContinue
    }
}

function Get-SvgElement {
    param(
        [Parameter(Mandatory)]
        [xml]$Document,

        [Parameter(Mandatory)]
        [string]$Id
    )

    $element = $Document.SelectSingleNode("//*[@id='$Id']")
    if ($null -eq $element) {
        throw "SVG element '$Id' was not found in $sourceSvg."
    }
    return $element
}

function Get-SvgNumber {
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlElement]$Element,

        [Parameter(Mandatory)]
        [string]$Attribute
    )

    return [double]::Parse(
        $Element.GetAttribute($Attribute),
        [System.Globalization.NumberStyles]::Float,
        $invariantCulture
    )
}

function Format-SvgNumber {
    param(
        [Parameter(Mandatory)]
        [double]$Value
    )

    return $Value.ToString('0.###', $invariantCulture)
}

function Get-EllipsePathData {
    param(
        [Parameter(Mandatory)]
        [System.Xml.XmlElement]$Ellipse
    )

    $centerX = Get-SvgNumber -Element $Ellipse -Attribute 'cx'
    $centerY = Get-SvgNumber -Element $Ellipse -Attribute 'cy'
    $radiusX = Get-SvgNumber -Element $Ellipse -Attribute 'rx'
    $radiusY = Get-SvgNumber -Element $Ellipse -Attribute 'ry'
    $right = Format-SvgNumber ($centerX + $radiusX)
    $left = Format-SvgNumber ($centerX - $radiusX)
    $centerXText = Format-SvgNumber $centerX
    $centerYText = Format-SvgNumber $centerY
    $radiusXText = Format-SvgNumber $radiusX
    $radiusYText = Format-SvgNumber $radiusY

    return "M$right,$centerYText A$radiusXText,$radiusYText 0,1 1 $left,$centerYText A$radiusXText,$radiusYText 0,1 1 $right,$centerYText Z"
}

function Export-NotificationVector {
    param(
        [Parameter(Mandatory)]
        [xml]$Document
    )

    $route = Get-SvgElement -Document $Document -Id 'path2'
    $startMarker = Get-SvgElement -Document $Document -Id 'path10-8'
    $destinationMarker = Get-SvgElement -Document $Document -Id 'path10-8-5'

    $startCenterX = Get-SvgNumber -Element $startMarker -Attribute 'cx'
    $startCenterY = Get-SvgNumber -Element $startMarker -Attribute 'cy'
    $startRadiusX = Get-SvgNumber -Element $startMarker -Attribute 'rx'
    $startRadiusY = Get-SvgNumber -Element $startMarker -Attribute 'ry'
    $destinationCenterX = Get-SvgNumber -Element $destinationMarker -Attribute 'cx'
    $destinationCenterY = Get-SvgNumber -Element $destinationMarker -Attribute 'cy'
    $destinationRadiusX = Get-SvgNumber -Element $destinationMarker -Attribute 'rx'
    $destinationRadiusY = Get-SvgNumber -Element $destinationMarker -Attribute 'ry'

    $minimumX = [Math]::Min(
        $startCenterX - $startRadiusX,
        $destinationCenterX - $destinationRadiusX
    )
    $maximumX = [Math]::Max(
        $startCenterX + $startRadiusX,
        $destinationCenterX + $destinationRadiusX
    )
    $minimumY = [Math]::Min(
        $startCenterY - $startRadiusY,
        $destinationCenterY - $destinationRadiusY
    )
    $maximumY = [Math]::Max(
        $startCenterY + $startRadiusY,
        $destinationCenterY + $destinationRadiusY
    )
    $glyphWidth = $maximumX - $minimumX
    $glyphHeight = $maximumY - $minimumY
    $viewportSize = [Math]::Ceiling([Math]::Max($glyphWidth, $glyphHeight) * 1.22)
    $originX = (($minimumX + $maximumX) / 2) - ($viewportSize / 2)
    $originY = (($minimumY + $maximumY) / 2) - ($viewportSize / 2)

    $viewportText = Format-SvgNumber $viewportSize
    $translationX = Format-SvgNumber (-$originX)
    $translationY = Format-SvgNumber (-$originY)
    $routeData = ($route.GetAttribute('d').Trim() -replace '\s+', ' ')
    $startMarkerData = Get-EllipsePathData -Ellipse $startMarker
    $destinationMarkerData = Get-EllipsePathData -Ellipse $destinationMarker

    $vectorXml = @"
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="$viewportText"
    android:viewportHeight="$viewportText">
    <group
        android:translateX="$translationX"
        android:translateY="$translationY">
        <path
            android:fillColor="#00000000"
            android:pathData="$routeData"
            android:strokeColor="#FFFFFFFF"
            android:strokeLineCap="round"
            android:strokeLineJoin="round"
            android:strokeWidth="8" />
        <path
            android:fillColor="#FFFFFFFF"
            android:pathData="$startMarkerData" />
        <path
            android:fillColor="#FFFFFFFF"
            android:pathData="$destinationMarkerData" />
    </group>
</vector>
"@

    [System.IO.File]::WriteAllText(
        $notificationDrawable,
        $vectorXml,
        [System.Text.UTF8Encoding]::new($false)
    )
}

if (-not (Test-Path -LiteralPath $sourceSvg -PathType Leaf)) {
    throw "Icon source was not found at $sourceSvg."
}
if ($null -eq (Get-Command magick -ErrorAction SilentlyContinue)) {
    throw 'ImageMagick 7 is required. Install it and ensure magick is on PATH.'
}

[xml]$launcherDocument = Get-Content -Raw -LiteralPath $sourceSvg
Export-SvgPng -Document $launcherDocument -Destination $launcherPng
Export-NotificationVector -Document $launcherDocument

[xml]$foregroundDocument = Get-Content -Raw -LiteralPath $sourceSvg
Remove-SvgLayer -Document $foregroundDocument -Id 'layer1'
Export-SvgPng -Document $foregroundDocument -Destination $foregroundPng

[xml]$monochromeDocument = Get-Content -Raw -LiteralPath $sourceSvg
Remove-SvgLayer -Document $monochromeDocument -Id 'layer1'
Remove-SvgLayer -Document $monochromeDocument -Id 'layer2'
$monochromeDocument.DocumentElement.SetAttribute('viewBox', '0 42 220 220')

$route = $monochromeDocument.SelectSingleNode("//*[@id='path2']")
if ($null -eq $route) {
    throw "Route path 'path2' was not found in $sourceSvg."
}
$route.SetAttribute(
    'style',
    'fill:none;stroke:#ffffff;stroke-width:8;stroke-linecap:round;stroke-linejoin:round'
)

foreach ($marker in $monochromeDocument.SelectNodes("//*[@id='layer4']/*")) {
    $marker.SetAttribute('style', 'fill:#ffffff;stroke:none')
}
Export-SvgPng -Document $monochromeDocument -Destination $monochromePng

if ($SkipPackageGeneration) {
    Write-Host 'Prepared launcher PNGs and the Android notification VectorDrawable.'
    exit 0
}

if ($null -eq (Get-Command fvm -ErrorAction SilentlyContinue)) {
    throw 'FVM is required for this project. Install it and ensure fvm is on PATH.'
}

Push-Location $projectRoot
try {
    & fvm flutter pub get
    if ($LASTEXITCODE -ne 0) {
        throw 'flutter pub get failed.'
    }

    & fvm dart run flutter_launcher_icons
    if ($LASTEXITCODE -ne 0) {
        throw 'flutter_launcher_icons failed.'
    }
}
finally {
    Pop-Location
}

Write-Host 'Updated Android launcher icons and prepared notification icon source assets.'
