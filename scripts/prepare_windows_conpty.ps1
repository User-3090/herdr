param(
    [Parameter(Mandatory = $true)]
    [string] $Destination,

    [ValidateSet("x64", "x86", "arm64")]
    [string] $Architecture = "x64",

    [string] $PackageVersion = "1.24.260710001",

    [string] $PackageSha256 = "175640566a3b59c4b132070ee96c2c77e5ab7edd2e92732a5eb3610bbf63d90e"
)

$ErrorActionPreference = "Stop"

$PackageVersion = $PackageVersion.ToLowerInvariant()
$PackageSha256 = $PackageSha256.ToLowerInvariant()
if ($PackageVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9a-z.-]+)?$') {
    throw "Invalid Microsoft.Windows.Console.ConPTY package version: $PackageVersion"
}
if ($PackageSha256 -notmatch '^[0-9a-f]{64}$') {
    throw "Invalid Microsoft.Windows.Console.ConPTY package SHA-256: $PackageSha256"
}
$packageUrl = "https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/$packageVersion/microsoft.windows.console.conpty.$packageVersion.nupkg"
$destinationPath = [System.IO.Path]::GetFullPath($Destination)
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "herdr-conpty-$([guid]::NewGuid().ToString('N'))"

New-Item -ItemType Directory -Force -Path $destinationPath | Out-Null
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

try {
    $packagePath = Join-Path $tempDir "conpty.nupkg"
    $zipPath = Join-Path $tempDir "conpty.zip"
    $expandedPath = Join-Path $tempDir "package"

    Invoke-WebRequest -UseBasicParsing -Uri $packageUrl -OutFile $packagePath
    $actualSha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $packageSha256) {
        throw "Microsoft.Windows.Console.ConPTY package hash mismatch: expected $packageSha256, got $actualSha256"
    }

    Copy-Item -LiteralPath $packagePath -Destination $zipPath
    Expand-Archive -LiteralPath $zipPath -DestinationPath $expandedPath

    $dll = Join-Path $expandedPath "runtimes\win-$Architecture\native\conpty.dll"
    $hostArchitectures = @(
        switch ($Architecture) {
            "x86" { "x86"; "x64"; "arm64" }
            "x64" { "x64"; "arm64" }
            "arm64" { "arm64" }
        }
    )
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
        throw "ConPTY package does not contain the expected DLL: $dll"
    }
    foreach ($hostArchitecture in $hostArchitectures) {
        $consoleHost = Join-Path $expandedPath "build\native\runtimes\$hostArchitecture\OpenConsole.exe"
        if (-not (Test-Path -LiteralPath $consoleHost -PathType Leaf)) {
            throw "ConPTY package does not contain the expected console host: $consoleHost"
        }
    }

    $legacyRootHost = Join-Path $destinationPath "OpenConsole.exe"
    if (Test-Path -LiteralPath $legacyRootHost) {
        Remove-Item -LiteralPath $legacyRootHost -Force
    }
    foreach ($hostArchitecture in $hostArchitectures) {
        $hostDirectory = Join-Path $destinationPath $hostArchitecture
        New-Item -ItemType Directory -Force -Path $hostDirectory | Out-Null
        $consoleHost = Join-Path $expandedPath "build\native\runtimes\$hostArchitecture\OpenConsole.exe"
        Copy-Item -LiteralPath $consoleHost -Destination (Join-Path $hostDirectory "OpenConsole.exe") -Force
    }
    Copy-Item -LiteralPath $dll -Destination (Join-Path $destinationPath "conpty.dll") -Force

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $license = Join-Path $repoRoot "vendor\licenses\Microsoft.Windows.Console.ConPTY.LICENSE.txt"
    Copy-Item -LiteralPath $license -Destination $destinationPath -Force

    @(
        "package=Microsoft.Windows.Console.ConPTY"
        "version=$packageVersion"
        "architecture=$Architecture"
        "host_architectures=$($hostArchitectures -join ',')"
        "sha256=$packageSha256"
        "source=https://www.nuget.org/packages/Microsoft.Windows.Console.ConPTY/$packageVersion"
    ) | Set-Content -LiteralPath (Join-Path $destinationPath "Microsoft.Windows.Console.ConPTY.BUILD_INFO.txt") -Encoding ascii

    @(
        "Herdr Windows 10 experimental bundle"
        ""
        "Keep herdr.exe, conpty.dll, and the architecture host directories together."
        "Herdr loads this exact app-local ConPTY package and falls back to Windows system ConPTY"
        "when conpty.dll is absent. A partial package is treated as an installation error."
        ""
        "This is an experimental fork build, not an official upstream Herdr release."
    ) | Set-Content -LiteralPath (Join-Path $destinationPath "README-WINDOWS10-EXPERIMENTAL.txt") -Encoding ascii
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
