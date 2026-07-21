param(
    [switch] $IncludePrerelease,

    [string] $PackageVersion
)

$ErrorActionPreference = "Stop"

$packageId = "Microsoft.Windows.Console.ConPTY"
$lowerPackageId = $packageId.ToLowerInvariant()
$feedRoot = "https://api.nuget.org/v3-flatcontainer"
$indexUrl = "$feedRoot/$lowerPackageId/index.json"
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "herdr-conpty-resolve-$([guid]::NewGuid().ToString('N'))"
$microsoftAuthorCertificate = "566A31882BE208BE4422F7CFD66ED09F5D4524A5994F50CCC8B05EC0528C1353"

function ConvertTo-VersionRecord([string] $Version) {
    try {
        $parsed = [System.Management.Automation.SemanticVersion]::new($Version)
    } catch {
        throw "Unsupported NuGet version returned for ${packageId}: $Version"
    }
    [pscustomobject]@{
        Text = $Version.ToLowerInvariant()
        Parsed = $parsed
        Stable = [string]::IsNullOrEmpty($parsed.PreReleaseLabel)
    }
}

New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
try {
    $index = Invoke-RestMethod -UseBasicParsing -Uri $indexUrl
    $versions = @($index.versions | ForEach-Object { ConvertTo-VersionRecord $_ })
    if (-not [string]::IsNullOrWhiteSpace($PackageVersion)) {
        $requestedVersion = $PackageVersion.ToLowerInvariant()
        $versions = @($versions | Where-Object Text -eq $requestedVersion)
    } elseif (-not $IncludePrerelease) {
        $versions = @($versions | Where-Object Stable)
    }
    if ($versions.Count -eq 0) {
        throw "NuGet returned no matching versions for $packageId"
    }

    $latest = $versions | Sort-Object Parsed | Select-Object -Last 1
    $packageVersion = $latest.Text.ToLowerInvariant()
    $packageUrl = "$feedRoot/$lowerPackageId/$packageVersion/$lowerPackageId.$packageVersion.nupkg"
    $packagePath = Join-Path $tempDir "$lowerPackageId.$packageVersion.nupkg"
    $zipPath = Join-Path $tempDir "package.zip"
    $expandedPath = Join-Path $tempDir "package"

    Invoke-WebRequest -UseBasicParsing -Uri $packageUrl -OutFile $packagePath
    $verifyOutput = & dotnet nuget verify $packagePath --all --certificate-fingerprint $microsoftAuthorCertificate 2>&1
    $verifyExitCode = $LASTEXITCODE
    $verifyOutput | ForEach-Object { Write-Host $_ }
    if ($verifyExitCode -ne 0) {
        throw "NuGet signature verification failed for $packageId $packageVersion"
    }

    Copy-Item -LiteralPath $packagePath -Destination $zipPath
    Expand-Archive -LiteralPath $zipPath -DestinationPath $expandedPath
    $nuspecPath = Get-ChildItem -LiteralPath $expandedPath -Filter '*.nuspec' -File | Select-Object -First 1
    if ($null -eq $nuspecPath) {
        throw "Downloaded package does not contain a nuspec"
    }
    [xml] $nuspec = Get-Content -LiteralPath $nuspecPath.FullName -Raw
    $metadata = $nuspec.SelectSingleNode("/*[local-name()='package']/*[local-name()='metadata']")
    $actualId = $metadata.SelectSingleNode("*[local-name()='id']").InnerText
    $actualVersion = $metadata.SelectSingleNode("*[local-name()='version']").InnerText.ToLowerInvariant()
    if ($actualId -ne $packageId -or $actualVersion -ne $packageVersion) {
        throw "NuGet identity mismatch: expected $packageId $packageVersion, got $actualId $actualVersion"
    }

    $requiredFiles = @(
        (Join-Path $expandedPath 'runtimes\win-x64\native\conpty.dll'),
        (Join-Path $expandedPath 'build\native\runtimes\x64\OpenConsole.exe'),
        (Join-Path $expandedPath 'build\native\runtimes\arm64\OpenConsole.exe')
    )
    foreach ($requiredFile in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "NuGet package is missing required file: $requiredFile"
        }
    }

    [pscustomobject]@{
        Version = $packageVersion
        Sha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
        PackageUrl = $packageUrl
        IsPrerelease = -not $latest.Stable
    }
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
