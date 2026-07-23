param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-HerdrRustMirrorPayloads {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MirrorRoot,
        [Parameter(Mandatory = $true)]
        [object[]]$Payloads
    )

    if (-not (Test-Path -LiteralPath $MirrorRoot -PathType Container)) {
        throw "Rust mirror directory is missing: $MirrorRoot"
    }
    $mirrorInfo = Get-Item -LiteralPath $MirrorRoot -Force
    if (($mirrorInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Rust mirror root is a reparse point: $MirrorRoot"
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $MirrorRoot -Directory -Recurse -Force)) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Rust mirror directory is a reparse point: $($directory.FullName)"
        }
    }
    $files = @(Get-ChildItem -LiteralPath $MirrorRoot -File -Recurse -Force)
    if ($files.Count -ne $Payloads.Count) {
        throw "Rust mirror contains $($files.Count) files; expected $($Payloads.Count)."
    }
    foreach ($payload in $Payloads) {
        $path = Join-Path $MirrorRoot $payload.RelativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Rust mirror payload is missing: $($payload.RelativePath)"
        }
        $info = Get-Item -LiteralPath $path -Force
        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Rust mirror payload is a reparse point: $($payload.RelativePath)"
        }
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -cne $payload.Sha256) {
            throw "Rust mirror payload hash mismatch: $($payload.RelativePath)"
        }
    }
    $sidecar = [IO.File]::ReadAllText((Join-Path $MirrorRoot 'dist\channel-rust-1.96.1.toml.sha256')).Trim()
    if (-not $sidecar.StartsWith('87eb76c53073e72b766083bed5530820694253b832a762d8385bda5759f03975  channel-rust-1.96.1.toml', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Rust channel manifest sidecar content is unexpected.'
    }
}

function Test-HerdrRustMirrorCacheEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EntryDirectory,
        [Parameter(Mandatory = $true)]
        [object[]]$Payloads
    )

    try {
        if (-not (Test-Path -LiteralPath $EntryDirectory -PathType Container)) {
            return $false
        }
        $entry = Get-Item -LiteralPath $EntryDirectory -Force
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        $entryItems = @(Get-ChildItem -LiteralPath $EntryDirectory -Force)
        if ($entryItems.Count -ne 2 -or
            -not (Test-Path -LiteralPath (Join-Path $EntryDirectory 'mirror') -PathType Container)) {
            return $false
        }
        $descriptorPath = Join-Path $EntryDirectory 'complete.json'
        if (-not (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) {
            return $false
        }
        $descriptorInfo = Get-Item -LiteralPath $descriptorPath -Force
        if (($descriptorInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        $descriptor = [IO.File]::ReadAllText($descriptorPath) | ConvertFrom-Json
        $expectedProperties = @('manifestSha256', 'schemaVersion', 'target', 'toolchain')
        $actualProperties = @($descriptor.PSObject.Properties.Name | Sort-Object)
        if (($actualProperties -join '|') -cne ($expectedProperties -join '|') -or
            [int]$descriptor.schemaVersion -ne 1 -or
            [string]$descriptor.toolchain -cne '1.96.1' -or
            [string]$descriptor.target -cne 'x86_64-pc-windows-msvc' -or
            [string]$descriptor.manifestSha256 -cne '87EB76C53073E72B766083BED5530820694253B832A762D8385BDA5759F03975') {
            return $false
        }
        Assert-HerdrRustMirrorPayloads -MirrorRoot (Join-Path $EntryDirectory 'mirror') -Payloads $Payloads
        return $true
    } catch {
        return $false
    }
}

function Publish-HerdrRustMirrorCacheEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageRoot,
        [Parameter(Mandatory = $true)]
        [string]$EntryDirectory,
        [Parameter(Mandatory = $true)]
        [string]$GuestMirrorRoot,
        [Parameter(Mandatory = $true)]
        [object[]]$Payloads
    )

    Assert-ProvisioningCachePath -Path $PackageRoot
    $staging = Join-Path $PackageRoot ('.stage-' + [Guid]::NewGuid().ToString('N'))
    $stagedMirror = Join-Path $staging 'mirror'
    New-Item -ItemType Directory -Path $stagedMirror -Force | Out-Null
    Assert-ProvisioningCachePath -Path $staging
    $displaced = ''
    $promotionSucceeded = $false
    $primaryFailure = $null
    $cleanupFailure = $null
    try {
        foreach ($payload in $Payloads) {
            $source = Join-Path $GuestMirrorRoot $payload.RelativePath
            $destination = Join-Path $stagedMirror $payload.RelativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
        Assert-HerdrRustMirrorPayloads -MirrorRoot $stagedMirror -Payloads $Payloads
        $descriptor = [ordered]@{
            schemaVersion = 1
            toolchain = '1.96.1'
            target = 'x86_64-pc-windows-msvc'
            manifestSha256 = '87EB76C53073E72B766083BED5530820694253B832A762D8385BDA5759F03975'
        } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText((Join-Path $staging 'complete.json'), $descriptor, (New-Object Text.UTF8Encoding($false)))
        if (-not (Test-HerdrRustMirrorCacheEntry -EntryDirectory $staging -Payloads $Payloads)) {
            throw 'Staged Rust mirror validation failed.'
        }
        if (Test-Path -LiteralPath $EntryDirectory) {
            Assert-ProvisioningCachePath -Path $EntryDirectory
            $displaced = Join-Path $PackageRoot ('.invalid-' + [Guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $EntryDirectory -Destination $displaced
        }
        try {
            Move-Item -LiteralPath $staging -Destination $EntryDirectory
        } catch {
            $promotionFailure = $_
            $rollbackFailure = $null
            try {
                if (-not [string]::IsNullOrWhiteSpace($displaced) -and
                    (Test-Path -LiteralPath $displaced) -and
                    -not (Test-Path -LiteralPath $EntryDirectory)) {
                    Move-Item -LiteralPath $displaced -Destination $EntryDirectory
                    $displaced = ''
                }
            } catch {
                $rollbackFailure = $_
            }
            if ($null -ne $rollbackFailure) {
                Write-Warning "Rust mirror cache rollback also failed: $($rollbackFailure.Exception.Message)"
            }
            throw $promotionFailure
        }
        if (-not (Test-HerdrRustMirrorCacheEntry -EntryDirectory $EntryDirectory -Payloads $Payloads)) {
            throw 'Published Rust mirror validation failed.'
        }
        $promotionSucceeded = $true
    } catch {
        $primaryFailure = $_
    } finally {
        try {
            if (Test-Path -LiteralPath $staging) {
                Assert-ProvisioningCachePath -Path $staging
                Remove-Item -LiteralPath $staging -Recurse -Force
            }
        } catch {
            $cleanupFailure = $_
        }
        try {
            if ($promotionSucceeded -and -not [string]::IsNullOrWhiteSpace($displaced) -and
                (Test-Path -LiteralPath $displaced)) {
                Assert-ProvisioningCachePath -Path $displaced
                Remove-Item -LiteralPath $displaced -Recurse -Force
            }
        } catch {
            if ($null -eq $cleanupFailure) {
                $cleanupFailure = $_
            }
        }
    }
    if ($null -ne $primaryFailure) {
        if ($null -ne $cleanupFailure) {
            Write-Warning "Rust mirror cache cleanup also failed: $($cleanupFailure.Exception.Message)"
        }
        throw $primaryFailure
    }
    if ($null -ne $cleanupFailure) {
        throw $cleanupFailure
    }
}

Write-Output 'Installing Visual Studio C++ Build Tools...'
$buildToolsOverride = '--wait --quiet --norestart --nocache --installPath C:\BuildTools --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
Install-ProvisioningOnlineWinGetPackage -Role 'Visual Studio Build Tools' `
    -Id 'Microsoft.VisualStudio.2022.BuildTools' -Override $buildToolsOverride
$vswhere = [string](Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe')
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "Visual Studio installer locator is missing: $vswhere"
}
$buildToolsPath = Invoke-ProvisioningNative -Role 'Visual Studio C++ workload check' -FilePath $vswhere `
    -ArgumentList @('-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath')
if ([string]::IsNullOrWhiteSpace(($buildToolsPath -join ' ').Trim())) {
    throw 'Visual Studio C++ workload was not found after installation.'
}

Write-Output 'Installing Python...'
Install-ProvisioningWinGetPackage -Role 'Python' -Id 'Python.Python.3.13' -InstallerType 'burn' `
    -Scope 'machine' -Adapter 'Burn' -RequireAuthenticodeSignature
$pythonVersion = Assert-ProvisioningCommand -Role 'Python' -Name 'python.exe' -VersionArguments @('--version') -ExpectedPattern '^Python 3\.13\.\d+$'

Write-Output 'Installing Zig...'
Install-ProvisioningWinGetPackage -Role 'Zig' -Id 'zig.zig' -Version '0.15.2' `
    -InstallerType 'zip' -Adapter 'Portable' -ExecutableName 'zig.exe'
$zigVersion = Assert-ProvisioningCommand -Role 'Zig' -Name 'zig.exe' -VersionArguments @('version') -ExpectedPattern '^0\.15\.2$'

Write-Output 'Installing Rustup and the repository toolchain...'
$rustTriple = 'x86_64-pc-windows-msvc'
$rustToolchain = "1.96.1-$rustTriple"
$env:RUSTUP_HOME = 'C:\HerdrBoxTools\rustup'
$env:CARGO_HOME = 'C:\HerdrBoxTools\cargo'
$env:CARGO_TARGET_DIR = 'C:\HerdrTarget'
$env:ZIG_LOCAL_CACHE_DIR = Join-Path $env:CARGO_TARGET_DIR 'zig-local-cache'
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $env:CARGO_TARGET_DIR 'zig-global-cache'
$env:LIBGHOSTTY_VT_ZIG_OUT_DIR = Join-Path $env:CARGO_TARGET_DIR 'zig-out'
foreach ($directory in @($env:RUSTUP_HOME, $env:CARGO_HOME, $env:CARGO_TARGET_DIR,
    $env:ZIG_LOCAL_CACHE_DIR, $env:ZIG_GLOBAL_CACHE_DIR, $env:LIBGHOSTTY_VT_ZIG_OUT_DIR)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
Install-ProvisioningWinGetPackage -Role 'Rustup' -Id 'Rustlang.Rustup' -InstallerType 'exe' `
    -Adapter 'Rustup' -InstallerArguments @('-y', '-q', '--no-modify-path', '--default-host', $rustTriple,
        '--default-toolchain', 'none', '--profile', 'minimal')
$cargoDirectory = Join-Path $env:CARGO_HOME 'bin'
Add-ProvisioningMachinePath -Directory $cargoDirectory
$rustPayloads = @(
    [pscustomobject]@{ RelativePath = 'dist\channel-rust-1.96.1.toml'; Sha256 = '87EB76C53073E72B766083BED5530820694253B832A762D8385BDA5759F03975' },
    [pscustomobject]@{ RelativePath = 'dist\channel-rust-1.96.1.toml.sha256'; Sha256 = '221E9F5B196762DC5E34B757A19F614A829B094185F3A7762836EB5D88C3C515' },
    [pscustomobject]@{ RelativePath = 'dist\2026-06-30\cargo-1.96.1-x86_64-pc-windows-msvc.tar.xz'; Sha256 = 'E2C271F65AE10A2B40AEBE483A2E7C0C566557F6BAB8AB718BE32AC9383A5081' },
    [pscustomobject]@{ RelativePath = 'dist\2026-06-30\clippy-1.96.1-x86_64-pc-windows-msvc.tar.xz'; Sha256 = '9422A02A2936F433400F1581BC0F9406211FB2271722BFD18C668F719D3BE943' },
    [pscustomobject]@{ RelativePath = 'dist\2026-06-30\rust-std-1.96.1-x86_64-pc-windows-msvc.tar.xz'; Sha256 = 'F77BEF11E2C032F8AAFCDC60B4E50D21BECF06D05C027FA87D7F45BF9BD146BB' },
    [pscustomobject]@{ RelativePath = 'dist\2026-06-30\rustc-1.96.1-x86_64-pc-windows-msvc.tar.xz'; Sha256 = 'D226A2E142B4CD796DF9DB527F4F3FF79BC9CE4118B36DCD7C82B7ECA557D0B8' },
    [pscustomobject]@{ RelativePath = 'dist\2026-06-30\rustfmt-1.96.1-x86_64-pc-windows-msvc.tar.xz'; Sha256 = '016402149CB21DD57D0A12A0EA28958DC010B2F22095C922AB981C6C912CE33A' }
)
$rustCacheRoot = 'C:\HerdrBoxCache\rust'
$rustEntryName = '1.96.1-x86_64-pc-windows-msvc-87eb76c53073e72b'
$rustEntryDirectory = Join-Path $rustCacheRoot $rustEntryName
$rustGuestStage = Join-Path 'C:\HerdrRustMirrorStage' ([Guid]::NewGuid().ToString('N'))
$rustGuestMirror = Join-Path $rustGuestStage 'mirror'
$rustLock = $null
$rustServer = $null
$rustSetupSucceeded = $false
$rustPrimaryFailure = $null
$rustCleanupFailure = $null
New-Item -ItemType Directory -Path $rustCacheRoot -Force | Out-Null
Assert-ProvisioningCachePath -Path $rustCacheRoot
New-Item -ItemType Directory -Path $rustGuestMirror -Force | Out-Null
try {
    $rustLockPath = Join-Path $rustCacheRoot '.lock'
    Assert-ProvisioningCachePath -Path $rustLockPath
    $rustLock = [IO.File]::Open($rustLockPath, [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    if (Test-Path -LiteralPath $rustEntryDirectory) {
        Assert-ProvisioningCachePath -Path $rustEntryDirectory
    }
    $rustCacheHit = Test-HerdrRustMirrorCacheEntry -EntryDirectory $rustEntryDirectory -Payloads $rustPayloads
    if ($rustCacheHit) {
        Write-Output 'Rust distribution mirror cache hit: 1.96.1'
        $cachedMirrorRoot = Join-Path $rustEntryDirectory 'mirror'
        foreach ($payload in $rustPayloads) {
            $source = Join-Path $cachedMirrorRoot $payload.RelativePath
            $destination = Join-Path $rustGuestMirror $payload.RelativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
        Assert-HerdrRustMirrorPayloads -MirrorRoot $rustGuestMirror -Payloads $rustPayloads
        $rustMirrorRoot = $rustGuestMirror
    } else {
        Write-Output 'Rust distribution mirror cache miss: 1.96.1'
        foreach ($payload in $rustPayloads) {
            $destination = Join-Path $rustGuestMirror $payload.RelativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            $relativeURL = $payload.RelativePath.Replace('\', '/')
            Invoke-WebRequest -Uri "https://static.rust-lang.org/$relativeURL" -OutFile $destination `
                -UseBasicParsing -ErrorAction Stop
            $actualHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($actualHash -cne $payload.Sha256) {
                throw "Downloaded Rust mirror payload hash mismatch: $($payload.RelativePath)"
            }
        }
        Assert-HerdrRustMirrorPayloads -MirrorRoot $rustGuestMirror -Payloads $rustPayloads
        $rustMirrorRoot = $rustGuestMirror
    }

    $rustPort = 49601
    $rustDistServer = "http://127.0.0.1:$rustPort"
    $env:RUSTUP_DIST_SERVER = $rustDistServer
    $env:RUSTUP_UPDATE_ROOT = "$rustDistServer/__self_update_disabled__"
    $env:RUSTUP_AUTO_INSTALL = '0'
    $env:NO_PROXY = '127.0.0.1,localhost'
    $env:no_proxy = $env:NO_PROXY
    $pythonCommand = Get-Command 'python.exe' -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $rustServerOutput = Join-Path $rustGuestStage 'server.stdout.log'
    $rustServerError = Join-Path $rustGuestStage 'server.stderr.log'
    $rustServer = Start-Process -FilePath $pythonCommand.Source -ArgumentList @(
        '-I', '-u', '-m', 'http.server', '--bind', '127.0.0.1', '--directory', $rustMirrorRoot, [string]$rustPort
    ) -WindowStyle Hidden -RedirectStandardOutput $rustServerOutput -RedirectStandardError $rustServerError -PassThru
    $probeURI = "$rustDistServer/dist/channel-rust-1.96.1.toml.sha256"
    $probeDeadline = [DateTime]::UtcNow.AddSeconds(10)
    $serverReady = $false
    $lastProbeError = ''
    do {
        if ($rustServer.HasExited) {
            $serverFailure = if (Test-Path -LiteralPath $rustServerError) { [IO.File]::ReadAllText($rustServerError) } else { '' }
            throw "Rust mirror server exited early. $serverFailure"
        }
        try {
            $response = Invoke-WebRequest -Uri $probeURI -UseBasicParsing -TimeoutSec 1
            $body = [string]$response.Content
            if ($response.StatusCode -eq 200 -and $body.Length -ge 64 -and
                $body.Substring(0, 64) -ieq '87eb76c53073e72b766083bed5530820694253b832a762d8385bda5759f03975') {
                $serverReady = $true
            }
        } catch {
            $lastProbeError = $_.Exception.Message
        }
        if (-not $serverReady) {
            Start-Sleep -Milliseconds 100
        }
    } while (-not $serverReady -and [DateTime]::UtcNow -lt $probeDeadline)
    if (-not $serverReady) {
        throw "Rust mirror readiness timed out: $lastProbeError"
    }

    Invoke-ProvisioningNative -Role 'Rust toolchain installation' -FilePath 'rustup.exe' -ArgumentList @(
        'toolchain', 'install', $rustToolchain, '--profile', 'minimal', '--component', 'rustfmt',
        '--component', 'clippy', '--target', $rustTriple, '--no-self-update'
    ) | Out-Null
    Invoke-ProvisioningNative -Role 'Rust default toolchain selection' -FilePath 'rustup.exe' `
        -ArgumentList @('default', $rustToolchain) | Out-Null
    Invoke-ProvisioningNative -Role 'Rustup automatic self-update disable' -FilePath 'rustup.exe' `
        -ArgumentList @('set', 'auto-self-update', 'disable') | Out-Null
    Invoke-ProvisioningNative -Role 'Rustup automatic toolchain install disable' -FilePath 'rustup.exe' `
        -ArgumentList @('set', 'auto-install', 'disable') | Out-Null

    if (-not $rustCacheHit) {
        Publish-HerdrRustMirrorCacheEntry -PackageRoot $rustCacheRoot -EntryDirectory $rustEntryDirectory `
            -GuestMirrorRoot $rustGuestMirror -Payloads $rustPayloads
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $rustCacheRoot -Directory -Force)) {
        if ($directory.FullName -ine $rustEntryDirectory) {
            Assert-ProvisioningCachePath -Path $directory.FullName
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force
        }
    }
    $rustSetupSucceeded = $true
} catch {
    $rustPrimaryFailure = $_
} finally {
    if ($null -ne $rustServer) {
        try {
            if (-not $rustServer.HasExited) {
                Stop-Process -InputObject $rustServer -Force -ErrorAction Stop
            }
            if (-not $rustServer.WaitForExit(5000)) {
                throw "Rust mirror server did not stop: PID $($rustServer.Id)"
            }
        } catch {
            $rustCleanupFailure = $_
        } finally {
            try {
                $rustServer.Dispose()
            } catch {
                if ($null -eq $rustCleanupFailure) {
                    $rustCleanupFailure = $_
                }
            }
        }
    }
    if ($null -ne $rustLock) {
        try {
            $rustLock.Dispose()
        } catch {
            if ($null -eq $rustCleanupFailure) {
                $rustCleanupFailure = $_
            }
        }
    }
    if ($rustSetupSucceeded) {
        try {
            if (Test-Path -LiteralPath $rustGuestStage) {
                Remove-Item -LiteralPath $rustGuestStage -Recurse -Force
            }
        } catch {
            if ($null -eq $rustCleanupFailure) {
                $rustCleanupFailure = $_
            }
        }
    }
}
if ($null -ne $rustPrimaryFailure) {
    if ($null -ne $rustCleanupFailure) {
        Write-Warning "Rust cleanup also failed: $($rustCleanupFailure.Exception.Message)"
    }
    throw $rustPrimaryFailure
}
if ($null -ne $rustCleanupFailure) {
    throw $rustCleanupFailure
}
$rustVersion = Assert-ProvisioningCommand -Role 'Rust' -Name 'rustc.exe' -VersionArguments @('--version') -ExpectedPattern '^rustc 1\.96\.1 '
$cargoVersion = Assert-ProvisioningCommand -Role 'Cargo' -Name 'cargo.exe' -VersionArguments @('--version') -ExpectedPattern '^cargo 1\.96\.1 '

Write-Output 'Installing Cargo Nextest and Just...'
Install-ProvisioningWinGetPackage -Role 'Cargo Nextest' -Id 'nextest.cargo-nextest' `
    -InstallerType 'zip' -Adapter 'Portable' -ExecutableName 'cargo-nextest.exe'
$nextestVersion = Assert-ProvisioningCommand -Role 'Cargo Nextest' -Name 'cargo-nextest.exe' -VersionArguments @('--version') -ExpectedPattern '^cargo-nextest \d+\.\d+\.\d+ '
Install-ProvisioningWinGetPackage -Role 'Just' -Id 'Casey.Just' -InstallerType 'zip' `
    -Adapter 'Portable' -ExecutableName 'just.exe'
$justVersion = Assert-ProvisioningCommand -Role 'Just' -Name 'just.exe' -VersionArguments @('--version') -ExpectedPattern '^just \d+\.\d+\.\d+$'

if (-not (Test-Path -LiteralPath (Join-Path $ProjectDirectory 'Cargo.toml') -PathType Leaf)) {
    throw "Herdr Cargo.toml is missing from mapped project: $ProjectDirectory"
}
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
