# ============================================================================
# Builds the Windows setup program from installer\flutter_app.iss, and the
# release zip the in-app updater installs from.
#
# SHARED: byte-identical in extron_debugger, extron_configurator,
# instructor_contact_flutter, geo_guess_csuchico and quizzer; per-app
# settings are in app_settings.iss.
#
#   powershell -ExecutionPolicy Bypass -File installer\build_installer.ps1 -Build
#   powershell -ExecutionPolicy Bypass -File installer\build_installer.ps1 -Build -Destination \\doit-files\ATEC\CTS\StaffFiles\Program_Releases
#
# -Build runs `flutter build windows --release` first. When the repo has a
# secrets.json (or -Secrets names one) it adds --dart-define-from-file, which
# compiles the values into data\app.so - the file itself is never shipped.
# Without -Build the existing release build is packaged, secrets or not.
#
# Both land in build\installer:
#   <SetupBaseName>_setup_<version>.exe   the setup program
#   <ReleasePrefix>_<version>.zip         for the in-app updater
# ReleasePrefix (app_settings.iss) must match the app's releasePrefix in its
# FolderUpdater; it defaults to SetupBaseName. -Destination copies both there.
# -ListOnly prints what the zip would hold (the existing build plus the
# app_settings.iss [Files]) and builds nothing.
#
# Needs Inno Setup 6 (free). Install it once with:
#   winget install --id JRSoftware.InnoSetup -e
# ============================================================================
# CmdletBinding: an option this script does not have (a typo, or a flag from a
# newer copy) is an error rather than silently ignored.
[CmdletBinding()]
param(
    [switch]$Build,
    # A secrets file other than <repo>\secrets.json. Must exist when given.
    [string]$Secrets,
    # Folder to copy the setup and the zip to, e.g. the release share.
    [string]$Destination,
    # Full path to ISCC.exe, when Inno Setup is somewhere unusual.
    [string]$Iscc,
    # Only list what the zip would hold, from the existing build.
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
$installerDir = $PSScriptRoot
$repo = Split-Path $installerDir -Parent
$releaseDir = Join-Path $repo 'build\windows\x64\runner\Release'
$out = Join-Path $repo 'build\installer'

# One #define from app_settings.iss, or $null.
$appSettings = Get-Content (Join-Path $installerDir 'app_settings.iss') -Raw
function Get-IssDefine([string]$name) {
    $m = [regex]::Match($appSettings, '(?m)^\s*#define\s+' + $name + '\s+"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}
$exeName = Get-IssDefine 'AppExeName'
$setupBase = Get-IssDefine 'SetupBaseName'
$releasePrefix = Get-IssDefine 'ReleasePrefix'
if (-not $releasePrefix) { $releasePrefix = $setupBase }

if ($ListOnly) {
    $Build = $false
    $Secrets = $null
}

if ($Build) {
    if ($Secrets) {
        if (-not (Test-Path $Secrets)) { throw "Secrets file not found: $Secrets" }
        $Secrets = (Resolve-Path $Secrets).Path
    } elseif (Test-Path (Join-Path $repo 'secrets.json')) {
        $Secrets = Join-Path $repo 'secrets.json'
    }
    Push-Location $repo
    try {
        $flutterArgs = @('build', 'windows', '--release')
        if ($Secrets) {
            $flutterArgs += "--dart-define-from-file=$Secrets"
            Write-Host "Secrets: compiling in $Secrets" -ForegroundColor Cyan
        } else {
            Write-Host 'Secrets: none (no secrets.json in the repo)' -ForegroundColor Cyan
        }
        Write-Host "flutter $($flutterArgs -join ' ')"
        & flutter @flutterArgs
        if ($LASTEXITCODE -ne 0) { throw "flutter build failed ($LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
} elseif ($Secrets) {
    throw '-Secrets only applies with -Build: the existing build is packaged as it is.'
}

if (-not $ListOnly) {
    if (-not $Iscc) {
        $candidates = @(
            (Get-Command iscc.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
            (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
        ) | Where-Object { $_ -and (Test-Path $_) }
        $Iscc = $candidates | Select-Object -First 1
    }
    if (-not $Iscc) {
        Write-Host ''
        Write-Host 'Inno Setup 6 was not found. Install it once with:' -ForegroundColor Yellow
        Write-Host '  winget install --id JRSoftware.InnoSetup -e'
        Write-Host 'or download it from https://jrsoftware.org/isdl.php, then run this again.'
        exit 1
    }

    & $Iscc (Join-Path $installerDir 'flutter_app.iss')
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }

    $exePath = Join-Path $releaseDir $exeName
    $version = (Get-Item $exePath).VersionInfo.ProductVersion
    $setup = Join-Path $out "${setupBase}_setup_$version.exe"
    if (-not (Test-Path $setup)) { throw "Setup not found where expected: $setup" }
}

# ---------------------------------------------------------------------------
# The release zip: the same files the setup installs. The exclusions are read
# from flutter_app.iss so the two never drift apart; like Inno's, a pattern
# matches any file or folder name at any depth.
# ---------------------------------------------------------------------------
$iss = Get-Content (Join-Path $installerDir 'flutter_app.iss') -Raw
$excludes = [regex]::Match($iss, 'Source:\s*"\{#ReleaseDir\}[^\r\n]*?Excludes:\s*"([^"]*)"').Groups[1].Value -split ',' |
    ForEach-Object { $_.Trim() } | Where-Object { $_ }

function Test-Excluded([string]$relative, [string[]]$patterns) {
    foreach ($part in $relative -split '[\\/]') {
        foreach ($pattern in $patterns) { if ($part -like $pattern) { return $true } }
    }
    return $false
}

# Zip path (forward slashes) -> source file. A later line wins, as in Inno.
$entries = [ordered]@{}

# Every file under $dir matching $pattern (all depths when $recurse), minus
# $skip, into the zip under $destDir.
function Add-Entries([string]$dir, [string]$pattern, [bool]$recurse, [string[]]$skip, [string]$destDir) {
    $dir = (Resolve-Path $dir).Path.TrimEnd('\') + '\'
    Get-ChildItem $dir -Recurse:$recurse -File | Where-Object { $_.Name -like $pattern } | ForEach-Object {
        $relative = $_.FullName.Substring($dir.Length)
        if (-not (Test-Excluded $relative $skip)) {
            $name = if ($destDir) { Join-Path $destDir $relative } else { $relative }
            $entries[$name -replace '\\', '/'] = $_.FullName
        }
    }
}

Add-Entries $releaseDir '*' $true $excludes ''

# Everything app_settings.iss installs into {app}: single files, and folders
# (`..\device\*` with recursesubdirs, DestDir "{app}\device") with their own
# Excludes. A source that does not exist is skipped, like
# skipifsourcedoesntexist.
$filesLine = '(?m)^\s*Source:\s*"([^"]+)"\s*;\s*DestDir:\s*"\{app\}(?:\\([^"]*))?"(.*)$'
foreach ($m in [regex]::Matches($appSettings, $filesLine)) {
    $source = Join-Path $installerDir $m.Groups[1].Value
    $destDir = $m.Groups[2].Value
    $rest = $m.Groups[3].Value
    $recurse = $rest -match '\brecursesubdirs\b'
    $skip = [regex]::Match($rest, 'Excludes:\s*"([^"]*)"').Groups[1].Value -split ',' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $leaf = Split-Path $source -Leaf
    if ($leaf -match '[*?]') {
        $dir = Split-Path $source -Parent
        if (Test-Path $dir -PathType Container) { Add-Entries $dir $leaf $recurse $skip $destDir }
    } elseif (Test-Path $source -PathType Leaf) {
        $name = if ($destDir) { Join-Path $destDir $leaf } else { $leaf }
        $entries[$name -replace '\\', '/'] = (Resolve-Path $source).Path
    }
}

if ($ListOnly) {
    $entries.Keys | Where-Object { $_ -notlike 'data/*' } | ForEach-Object { Write-Host $_ }
    Write-Host "($($entries.Count) files, of which $(@($entries.Keys | Where-Object { $_ -like 'data/*' }).Count) under data/ not listed)"
    exit 0
}

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = Join-Path $out "${releasePrefix}_$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
$archive = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    foreach ($name in $entries.Keys) {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $entries[$name], $name, [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $archive.Dispose()
}

Write-Host ''
Write-Host "Setup: $setup" -ForegroundColor Green
Write-Host "Zip:   $zip ($($entries.Count) files)" -ForegroundColor Green

if ($Destination) {
    if (-not (Test-Path $Destination -PathType Container)) { throw "Destination folder not found: $Destination" }
    # The zip last: the updater may see it as soon as it lands, and a copy
    # still in progress is skipped until it is whole.
    Copy-Item $setup $Destination -Force
    Copy-Item $zip $Destination -Force
    Write-Host "Copied both to $Destination" -ForegroundColor Green
}
