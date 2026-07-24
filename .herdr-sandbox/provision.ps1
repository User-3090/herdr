param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not (Test-Path -LiteralPath (Join-Path $ProjectDirectory 'Cargo.toml') -PathType Leaf)) {
    throw "Herdr Cargo.toml is missing from mapped project: $ProjectDirectory"
}

Install-PythonStack -Series '3.13'
Install-ZigStack -Version '0.15.2'
Install-RustMSVCStack -ProjectDirectory $ProjectDirectory

$libghosttyOutput = Join-Path $env:CARGO_TARGET_DIR 'zig-out'
New-Item -ItemType Directory -Path $libghosttyOutput -Force | Out-Null
$env:LIBGHOSTTY_VT_ZIG_OUT_DIR = $libghosttyOutput
[Environment]::SetEnvironmentVariable('LIBGHOSTTY_VT_ZIG_OUT_DIR', $libghosttyOutput, 'Machine')

Install-CargoNextest
Install-Just

Write-Output 'Herdr development toolchain ready.'
