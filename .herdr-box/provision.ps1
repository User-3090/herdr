param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Write-Output 'Installing Visual Studio C++ Build Tools...'
$buildToolsOverride = '--wait --quiet --norestart --nocache --installPath C:\BuildTools --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
Install-ProvisioningWinGetPackage -Role 'Visual Studio Build Tools' `
    -Id 'Microsoft.VisualStudio.2022.BuildTools' -Version '17.14.36' -Override $buildToolsOverride
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$buildToolsPath = Invoke-ProvisioningNative -Role 'Visual Studio C++ workload check' -FilePath $vswhere `
    -ArgumentList @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath')
if ([string]::IsNullOrWhiteSpace(($buildToolsPath -join ' ').Trim())) {
    throw 'Visual Studio C++ workload was not found after installation.'
}

Write-Output 'Installing Python...'
Install-ProvisioningWinGetPackage -Role 'Python' -Id 'Python.Python.3.13' -Version '3.13.14'
$pythonVersion = Assert-ProvisioningCommand -Role 'Python' -Name 'python.exe' -VersionArguments @('--version') -ExpectedPattern '^Python 3\.13\.14$'

Write-Output 'Installing Zig...'
Install-ProvisioningWinGetPackage -Role 'Zig' -Id 'zig.zig' -Version '0.15.2'
$zigVersion = Assert-ProvisioningCommand -Role 'Zig' -Name 'zig.exe' -VersionArguments @('version') -ExpectedPattern '^0\.15\.2$'

Write-Output 'Installing Rustup and the repository toolchain...'
Install-ProvisioningWinGetPackage -Role 'Rustup' -Id 'Rustlang.Rustup' -Version '1.29.0'
$cargoDirectory = Join-Path $env:USERPROFILE '.cargo\bin'
if ($env:Path.Split(';') -inotcontains $cargoDirectory) {
    $env:Path = $cargoDirectory + ';' + $env:Path
}
Invoke-ProvisioningNative -Role 'Rust toolchain installation' -FilePath 'rustup.exe' `
    -ArgumentList @('toolchain', 'install', '1.96.1', '--profile', 'minimal', '--component', 'rustfmt', '--component', 'clippy', '--target', 'x86_64-pc-windows-msvc') | Out-Null
Invoke-ProvisioningNative -Role 'Rust default toolchain selection' -FilePath 'rustup.exe' `
    -ArgumentList @('default', '1.96.1') | Out-Null
$rustVersion = Assert-ProvisioningCommand -Role 'Rust' -Name 'rustc.exe' -VersionArguments @('--version') -ExpectedPattern '^rustc 1\.96\.1 '
$cargoVersion = Assert-ProvisioningCommand -Role 'Cargo' -Name 'cargo.exe' -VersionArguments @('--version') -ExpectedPattern '^cargo 1\.96\.1 '

Write-Output 'Installing Cargo Nextest and Just...'
Install-ProvisioningWinGetPackage -Role 'Cargo Nextest' -Id 'nextest.cargo-nextest' -Version '0.9.140'
$nextestVersion = Assert-ProvisioningCommand -Role 'Cargo Nextest' -Name 'cargo-nextest.exe' -VersionArguments @('--version') -ExpectedPattern '^cargo-nextest 0\.9\.140 '
Install-ProvisioningWinGetPackage -Role 'Just' -Id 'Casey.Just' -Version '1.57.0'
$justVersion = Assert-ProvisioningCommand -Role 'Just' -Name 'just.exe' -VersionArguments @('--version') -ExpectedPattern '^just 1\.57\.0$'

if (-not (Test-Path -LiteralPath (Join-Path $ProjectDirectory 'Cargo.toml') -PathType Leaf)) {
    throw "Herdr Cargo.toml is missing from mapped project: $ProjectDirectory"
}
$env:CARGO_TARGET_DIR = 'C:\HerdrBoxCache\herdr-target'
New-Item -ItemType Directory -Path $env:CARGO_TARGET_DIR -Force | Out-Null
Push-Location $ProjectDirectory
try {
    Invoke-ProvisioningNative -Role 'Herdr portable PTY vendor test' -FilePath 'python.exe' `
        -ArgumentList @('-m', 'unittest', 'scripts.test_vendor_portable_pty') | Out-Null
    Invoke-ProvisioningNative -Role 'Herdr formatting check' -FilePath 'cargo.exe' `
        -ArgumentList @('fmt', '--check') | Out-Null
    Invoke-ProvisioningNative -Role 'Herdr Windows clippy check' -FilePath 'cargo.exe' `
        -ArgumentList @('clippy', '--bin', 'herdr', '--locked', '--target', 'x86_64-pc-windows-msvc', '--', '-D', 'warnings') | Out-Null
    Invoke-ProvisioningNative -Role 'Herdr Windows tests' -FilePath 'cargo.exe' `
        -ArgumentList @('test', '--locked', '--target', 'x86_64-pc-windows-msvc', '--bin', 'herdr', 'windows_') | Out-Null
    Invoke-ProvisioningNative -Role 'Herdr Windows build' -FilePath 'cargo.exe' `
        -ArgumentList @('build', '--locked', '--target', 'x86_64-pc-windows-msvc') | Out-Null
} finally {
    Pop-Location
}

Write-Output "Python ready: $pythonVersion"
Write-Output "Zig ready: $zigVersion"
Write-Output "Rust ready: $rustVersion"
Write-Output "Cargo ready: $cargoVersion"
Write-Output "Cargo Nextest ready: $nextestVersion"
Write-Output "Just ready: $justVersion"
