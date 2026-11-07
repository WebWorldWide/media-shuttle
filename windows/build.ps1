[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$SkipTests,
    [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$project = Join-Path $repoRoot 'src\MediaShuttle\MediaShuttle.csproj'
$tests = Join-Path $repoRoot 'tests\MediaShuttle.Core.Tests\MediaShuttle.Core.Tests.csproj'
$installerScript = Join-Path $repoRoot 'installer\MediaShuttle.iss'
$artifacts = Join-Path $repoRoot 'artifacts'
$publishRoot = Join-Path $artifacts 'publish\win-x64'
$buildOutput = Join-Path $repoRoot 'src\MediaShuttle\bin\Release\net8.0-windows10.0.19041.0\win-x64'
$iconPath = Join-Path $repoRoot 'src\MediaShuttle\Assets\MediaShuttle.ico'

[xml]$projectXml = Get-Content -LiteralPath $project -Raw
$version = [string]$projectXml.Project.PropertyGroup.Version
if ([string]::IsNullOrWhiteSpace($version)) {
    throw "The application version is missing from $project."
}

$releaseZip = Join-Path $artifacts "MediaShuttle-v$version-win-x64.zip"
$installer = Join-Path $artifacts "MediaShuttle-Setup-v$version-win-x64.exe"
$checksums = Join-Path $artifacts 'SHA256SUMS-windows.txt'

if ($Clean -and [IO.Directory]::Exists($artifacts)) {
    Remove-Item -LiteralPath $artifacts -Recurse -Force
}
if ([IO.Directory]::Exists($publishRoot)) {
    Remove-Item -LiteralPath $publishRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null

# The icon is a committed asset, built from windows/icon by build-icon.sh. It used to
# be drawn here at build time, which meant the build could only ever ship the mark that
# one script knew how to draw.
if (-not [IO.File]::Exists($iconPath)) {
    throw "The application icon is missing: $iconPath. Rebuild it with windows/icon/build-icon.sh."
}

dotnet restore $project
if ($LASTEXITCODE -ne 0) { throw "Package restore failed with exit code $LASTEXITCODE." }

if (-not $SkipTests) {
    dotnet run --project $tests -c Release
    if ($LASTEXITCODE -ne 0) { throw "Core tests failed with exit code $LASTEXITCODE." }
}

dotnet publish $project -c Release -r win-x64 --self-contained true --no-restore -o $publishRoot `
    -p:WindowsAppSDKSelfContained=true `
    -p:PublishSingleFile=false `
    -p:PublishReadyToRun=false
if ($LASTEXITCODE -ne 0) { throw "WinUI 3 publish failed with exit code $LASTEXITCODE." }

# These resources are generated beside the normal build output rather than copied by
# dotnet publish. An unpackaged WinUI app cannot construct its window without them.
foreach ($resourceName in @('MediaShuttle.pri', 'App.xbf', 'MainWindow.xbf')) {
    $resourcePath = Join-Path $buildOutput $resourceName
    if (-not [IO.File]::Exists($resourcePath)) {
        throw "Required WinUI resource was not produced: $resourcePath"
    }
    Copy-Item -LiteralPath $resourcePath -Destination (Join-Path $publishRoot $resourceName) -Force
}

if (-not [IO.File]::Exists((Join-Path $publishRoot 'MediaShuttle.exe'))) {
    throw 'Publish did not produce MediaShuttle.exe.'
}

if (Test-Path -LiteralPath $releaseZip) { Remove-Item -LiteralPath $releaseZip -Force }
Compress-Archive -Path (Join-Path $publishRoot '*') -DestinationPath $releaseZip -CompressionLevel Optimal

$releaseFiles = @($releaseZip)
if (-not $SkipInstaller) {
    $isccCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
    )
    $iscc = $isccCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $iscc) {
        $isccCommand = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
        if ($isccCommand) { $iscc = $isccCommand.Source }
    }
    if (-not $iscc) {
        throw 'Inno Setup 6 is required to build the installer. Install JRSoftware.InnoSetup with winget, or use -SkipInstaller for a portable-only build.'
    }

    if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force }
    & $iscc "/DSourceDir=$publishRoot" "/DOutputDir=$artifacts" "/DAppVersion=$version" $installerScript
    if ($LASTEXITCODE -ne 0) { throw "Installer build failed with exit code $LASTEXITCODE." }
    if (-not [IO.File]::Exists($installer)) { throw "Installer was not produced: $installer" }
    $releaseFiles += $installer
}

$checksumLines = foreach ($file in $releaseFiles) {
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash *$([IO.Path]::GetFileName($file))"
}
Set-Content -LiteralPath $checksums -Value $checksumLines -Encoding ASCII

Write-Output "Published: $publishRoot"
foreach ($file in $releaseFiles) { Write-Output "Packaged: $file" }
Write-Output "Checksums: $checksums"
