param(
    [Parameter(Mandatory = $true)]
    [string] $Destination,

    [ValidateSet("x64", "x86", "arm64")]
    [string] $Architecture = "x64"
)

$ErrorActionPreference = "Stop"

$packageVersion = "1.24.260710001"
$packageSha256 = "175640566a3b59c4b132070ee96c2c77e5ab7edd2e92732a5eb3610bbf63d90e"
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
    $host = Join-Path $expandedPath "build\native\runtimes\$Architecture\OpenConsole.exe"
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
        throw "ConPTY package does not contain the expected DLL: $dll"
    }
    if (-not (Test-Path -LiteralPath $host -PathType Leaf)) {
        throw "ConPTY package does not contain the expected console host: $host"
    }

    Copy-Item -LiteralPath $dll -Destination (Join-Path $destinationPath "conpty.dll") -Force
    Copy-Item -LiteralPath $host -Destination (Join-Path $destinationPath "OpenConsole.exe") -Force

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $license = Join-Path $repoRoot "vendor\licenses\Microsoft.Windows.Console.ConPTY.LICENSE.txt"
    Copy-Item -LiteralPath $license -Destination $destinationPath -Force

    @(
        "package=Microsoft.Windows.Console.ConPTY"
        "version=$packageVersion"
        "architecture=$Architecture"
        "sha256=$packageSha256"
        "source=https://www.nuget.org/packages/Microsoft.Windows.Console.ConPTY/$packageVersion"
    ) | Set-Content -LiteralPath (Join-Path $destinationPath "Microsoft.Windows.Console.ConPTY.BUILD_INFO.txt") -Encoding ascii

    @(
        "Herdr Windows 10 experimental bundle"
        ""
        "Keep herdr.exe, conpty.dll, and OpenConsole.exe together in this directory."
        "Herdr loads this exact sibling ConPTY pair and falls back to Windows system ConPTY"
        "when conpty.dll is absent. A partial pair is treated as an installation error."
        ""
        "This is an experimental fork build, not an official upstream Herdr release."
    ) | Set-Content -LiteralPath (Join-Path $destinationPath "README-WINDOWS10-EXPERIMENTAL.txt") -Encoding ascii
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
