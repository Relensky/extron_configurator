# ============================================================================
# Builds the Windows setup program from installer\flutter_app.iss.
#
# SHARED: byte-identical in extron_debugger, extron_configurator,
# instructor_contact_flutter, geo_guess_csuchico and quizzer; per-app
# settings are in app_settings.iss.
#
#   powershell -ExecutionPolicy Bypass -File installer\build_installer.ps1 -Build
#
# -Build runs `flutter build windows --release` first (with
# --dart-define-from-file=secrets.json when the repo has one). Without it the
# existing release build is packaged. The setup lands in build\installer.
#
# Needs Inno Setup 6 (free). Install it once with:
#   winget install --id JRSoftware.InnoSetup -e
# ============================================================================
param(
    [switch]$Build,
    # Full path to ISCC.exe, when Inno Setup is somewhere unusual.
    [string]$Iscc
)

$ErrorActionPreference = 'Stop'
$installerDir = $PSScriptRoot
$repo = Split-Path $installerDir -Parent

if ($Build) {
    Push-Location $repo
    try {
        $flutterArgs = @('build', 'windows', '--release')
        if (Test-Path (Join-Path $repo 'secrets.json')) {
            $flutterArgs += '--dart-define-from-file=secrets.json'
        }
        Write-Host "flutter $($flutterArgs -join ' ')"
        & flutter @flutterArgs
        if ($LASTEXITCODE -ne 0) { throw "flutter build failed ($LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

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

$out = Join-Path $repo 'build\installer'
Get-ChildItem $out -Filter '*_setup_*.exe' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 |
    ForEach-Object { Write-Host "`nSetup: $($_.FullName)" -ForegroundColor Green }
