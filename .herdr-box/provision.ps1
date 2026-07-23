param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$herdrProvisioningStopwatch = [Diagnostics.Stopwatch]::StartNew()

function Get-HerdrWebResponseText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response
    )

    if ($null -eq $Response.Content) {
        throw 'Unexpected empty web response content.'
    }
    if ($Response.Content -is [byte[]]) {
        return [Text.Encoding]::UTF8.GetString([byte[]]$Response.Content)
    }
    if ($Response.Content -is [string]) {
        return [string]$Response.Content
    }
    throw "Unexpected web response content type: $($Response.Content.GetType().FullName)"
}

function Get-HerdrVisualStudioTargetFromChannel {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Channel,
        [Parameter(Mandatory = $true)]
        [string]$SourceDescription
    )

    $channel = $Channel
    if ([string]$channel.manifestVersion -cne '1.1' -or
        [string]$channel.info.manifestName -cne 'VisualStudio.17.Release' -or
        [string]$channel.info.manifestType -cne 'channel' -or
        [string]$channel.info.productLine -cne 'Dev17' -or
        [string]$channel.info.productLineVersion -cne '2022' -or
        [string]$channel.info.productMilestone -cne 'RTW' -or
        [string]$channel.info.productMilestoneIsPreRelease -cne 'False') {
        throw "Visual Studio channel metadata is unexpected: $SourceDescription"
    }
    $products = @($channel.channelItems | Where-Object {
        [string]$_.type -ceq 'ChannelProduct' -and
        [string]$_.id -ceq 'Microsoft.VisualStudio.Product.BuildTools'
    })
    $manifests = @($channel.channelItems | Where-Object {
        [string]$_.type -ceq 'Manifest' -and
        [string]$_.id -ceq 'Microsoft.VisualStudio.Manifests.VisualStudio'
    })
    $setups = @($channel.channelItems | Where-Object {
        [string]$_.type -ceq 'Bootstrapper' -and
        [string]$_.id -ceq 'VisualStudio.17.Release.Bootstrappers.Setup'
    })
    if ($products.Count -ne 1 -or $manifests.Count -ne 1 -or $setups.Count -ne 1) {
        throw "Visual Studio channel did not resolve one Build Tools product, manifest, and setup bootstrapper: $SourceDescription"
    }
    $catalogPayloads = @($manifests[0].payloads | Where-Object { [string]$_.fileName -ceq 'VisualStudio.vsman' })
    $setupPayloads = @($setups[0].payloads | Where-Object { [string]$_.fileName -ceq 'vs_Setup.exe' })
    if ($catalogPayloads.Count -ne 1 -or $setupPayloads.Count -ne 1) {
        throw "Visual Studio channel payload selection is ambiguous: $SourceDescription"
    }
    $buildVersion = [string]$channel.info.buildVersion
    $semanticVersion = [string]$channel.info.productSemanticVersion
    if ([string]::IsNullOrWhiteSpace($buildVersion) -or
        [string]::IsNullOrWhiteSpace($semanticVersion) -or
        [string]$products[0].version -cne $buildVersion -or
        [string]$manifests[0].version -cne $buildVersion) {
        throw "Visual Studio channel version fields disagree: $SourceDescription"
    }
    foreach ($payload in @($catalogPayloads[0], $setupPayloads[0])) {
        $uri = [Uri][string]$payload.url
        if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'download.visualstudio.microsoft.com' -or
            [string]$payload.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "Visual Studio channel payload is unsafe in $SourceDescription`: $($payload.fileName)"
        }
    }
    return [pscustomobject]@{
        ChannelID = [string]$channel.info.id
        BuildVersion = $buildVersion
        SemanticVersion = $semanticVersion
        ProductVersion = [string]$products[0].version
        CatalogSHA256 = ([string]$catalogPayloads[0].sha256).ToUpperInvariant()
        SetupVersion = [string]$setups[0].version
        SetupSHA256 = ([string]$setupPayloads[0].sha256).ToUpperInvariant()
    }
}

function Get-HerdrVisualStudioCurrentTarget {
    $channelURI = 'https://aka.ms/vs/17/release/channel'
    $response = Invoke-WebRequest -Uri $channelURI -UseBasicParsing -ErrorAction Stop
    $channelText = Get-HerdrWebResponseText -Response $response
    $channel = $channelText | ConvertFrom-Json
    return Get-HerdrVisualStudioTargetFromChannel -Channel $channel -SourceDescription $channelURI
}

function Test-HerdrVisualStudioTargetEqual {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Left,
        [Parameter(Mandatory = $true)]
        [object]$Right
    )

    return [string]$Left.ChannelID -ceq [string]$Right.ChannelID -and
        [string]$Left.BuildVersion -ceq [string]$Right.BuildVersion -and
        [string]$Left.SemanticVersion -ceq [string]$Right.SemanticVersion -and
        [string]$Left.ProductVersion -ceq [string]$Right.ProductVersion -and
        [string]$Left.CatalogSHA256 -ceq [string]$Right.CatalogSHA256 -and
        [string]$Left.SetupVersion -ceq [string]$Right.SetupVersion -and
        [string]$Left.SetupSHA256 -ceq [string]$Right.SetupSHA256
}

function Assert-HerdrVisualStudioBootstrapper {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedSHA256
    )

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -cne $ExpectedSHA256) {
        throw "Visual Studio bootstrapper hash mismatch: $actualHash"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate) {
        throw "Visual Studio bootstrapper signature is invalid: $($signature.Status)"
    }
    $publisher = $signature.SignerCertificate.GetNameInfo(
        [Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if ($publisher -cne 'Microsoft Corporation' -or
        $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw "Unexpected Visual Studio bootstrapper publisher: $publisher"
    }
    $eku = @($signature.SignerCertificate.Extensions |
        Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
        ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value })
    if ('1.3.6.1.5.5.7.3.3' -notin $eku) {
        throw 'Visual Studio bootstrapper certificate lacks the Code Signing EKU.'
    }
}

function Save-HerdrVisualStudioBootstrapper {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $request = [Net.HttpWebRequest]::Create('https://aka.ms/vs/17/release/vs_buildtools.exe')
    $request.AllowAutoRedirect = $true
    $request.MaximumAutomaticRedirections = 5
    $request.UserAgent = 'herdr-box'
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $response = $request.GetResponse()
        $finalURI = [Uri]$response.ResponseUri
        if ($finalURI.Scheme -cne 'https' -or $finalURI.Host -cne 'download.visualstudio.microsoft.com' -or
            $finalURI.AbsolutePath -notmatch '/([A-Fa-f0-9]{64})/vs_BuildTools\.exe$') {
            throw "Visual Studio evergreen bootstrapper redirected to an unsafe URI: $finalURI"
        }
        $expectedHash = $Matches[1].ToUpperInvariant()
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $inputStream.CopyTo($outputStream)
        $outputStream.Flush()
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
    Assert-HerdrVisualStudioBootstrapper -Path $Destination -ExpectedSHA256 $expectedHash
    return [pscustomobject]@{ Url = [string]$finalURI.AbsoluteUri; SHA256 = $expectedHash }
}

function Get-HerdrVisualStudioRequiredArtifacts {
    return @(
        'vs_BuildTools.exe',
        'layout.json',
        'response.json',
        'Catalog.json',
        'ChannelManifest.json',
        'vs_installer.opc',
        'vs_installer.version.json',
        'Certificates\manifestRootCertificate.cer',
        'Certificates\manifestCounterSignRootCertificate.cer',
        'Certificates\vs_installer_opc.RootCertificate.cer'
    )
}

function Assert-HerdrVisualStudioLayoutIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Layout,
        [Parameter(Mandatory = $true)]
        [object]$Target,
        [switch]$GuestLocal
    )

    if (-not (Test-Path -LiteralPath $Layout -PathType Container)) {
        throw "Visual Studio layout directory is missing: $Layout"
    }
    if (-not $GuestLocal) {
        Assert-ProvisioningCachePath -Path $Layout
    }
    $catalogPath = Join-Path $Layout 'Catalog.json'
    $channelManifestPath = Join-Path $Layout 'ChannelManifest.json'
    $layoutPath = Join-Path $Layout 'layout.json'
    foreach ($path in @($catalogPath, $channelManifestPath, $layoutPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Visual Studio layout identity file is missing: $path"
        }
        if (-not $GuestLocal) {
            Assert-ProvisioningCachePath -Path $path
        }
    }

    $localChannel = [IO.File]::ReadAllText($channelManifestPath) | ConvertFrom-Json
    $localTarget = Get-HerdrVisualStudioTargetFromChannel -Channel $localChannel `
        -SourceDescription $channelManifestPath
    if (-not (Test-HerdrVisualStudioTargetEqual -Left $Target -Right $localTarget)) {
        throw 'Visual Studio layout channel identity does not match the resolved Current target.'
    }
    $actualCatalogHash = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualCatalogHash -cne $Target.CatalogSHA256) {
        throw "Visual Studio layout catalog hash does not match the resolved Current target: $actualCatalogHash"
    }
    $catalog = [IO.File]::ReadAllText($catalogPath) | ConvertFrom-Json
    if ([string]$catalog.info.manifestName -cne 'VisualStudio' -or
        [string]$catalog.info.manifestType -cne 'installer' -or
        [string]$catalog.info.buildVersion -cne $Target.BuildVersion -or
        [string]$catalog.info.productSemanticVersion -cne $Target.SemanticVersion -or
        [string]$catalog.info.productLine -cne 'Dev17' -or
        [string]$catalog.info.productLineVersion -cne '2022' -or
        [string]$catalog.info.productMilestone -cne 'RTW' -or
        [string]$catalog.info.productMilestoneIsPreRelease -cne 'False' -or
        [string]::IsNullOrWhiteSpace([string]$catalog.info.requiredEngineVersion)) {
        throw 'Visual Studio layout catalog identity is unexpected.'
    }
    $layoutText = [IO.File]::ReadAllText($layoutPath)
    $layoutConfig = $layoutText | ConvertFrom-Json
    if ([string]$layoutConfig.channelId -cne 'VisualStudio.17.Release' -or
        [string]$layoutConfig.productId -cne 'Microsoft.VisualStudio.Product.BuildTools' -or
        [string]$layoutConfig.arch -cne 'x64' -or
        $layoutText -notmatch 'Microsoft\.VisualStudio\.Workload\.VCTools' -or
        $layoutText -notmatch 'includeRecommended' -or
        $layoutText -match 'includeOptional') {
        throw 'Visual Studio layout configuration identity is unexpected.'
    }
}

function Test-HerdrVisualStudioUnpublishedLayoutSlot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Slot,
        [Parameter(Mandatory = $true)]
        [object]$Target
    )

    try {
        $layout = Join-Path $Slot 'layout'
        $bootstrapper = Join-Path $layout 'vs_BuildTools.exe'
        if (-not (Test-Path -LiteralPath $bootstrapper -PathType Leaf)) { return $false }
        Assert-ProvisioningCachePath -Path $bootstrapper
        Assert-HerdrVisualStudioLayoutIdentity -Layout $layout -Target $Target
        return $true
    } catch {
        return $false
    }
}

function Copy-HerdrVisualStudioLayoutToGuest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $copyStopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        Assert-ProvisioningCachePath -Path $Source
        foreach ($item in @(Get-ChildItem -LiteralPath $Source -Recurse -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Visual Studio layout contains a reparse point: $($item.FullName)"
            }
        }
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        New-Item -ItemType Directory -Path $Destination | Out-Null
        foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
            Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
        }
        foreach ($relativePath in @(Get-HerdrVisualStudioRequiredArtifacts)) {
            $sourcePath = Join-Path $Source $relativePath
            $destinationPath = Join-Path $Destination $relativePath
            if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                throw "Guest-local Visual Studio layout artifact is missing: $relativePath"
            }
            $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToUpperInvariant()
            $destinationHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($sourceHash -cne $destinationHash) {
                throw "Guest-local Visual Studio layout artifact hash mismatch: $relativePath"
            }
        }
    } finally {
        $copyStopwatch.Stop()
        Write-ProvisioningTiming -Role 'Visual Studio layout guest materialization' `
            -Seconds $copyStopwatch.Elapsed.TotalSeconds
    }
}

function Test-HerdrVisualStudioLayoutSlot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Slot,
        [Parameter(Mandatory = $true)]
        [object]$Target
    )

    try {
        if (-not (Test-Path -LiteralPath $Slot -PathType Container)) { return $false }
        Assert-ProvisioningCachePath -Path $Slot
        $layout = Join-Path $Slot 'layout'
        $descriptorPath = Join-Path $Slot 'complete.json'
        if (-not (Test-Path -LiteralPath $layout -PathType Container) -or
            -not (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) { return $false }
        Assert-ProvisioningCachePath -Path $layout
        Assert-ProvisioningCachePath -Path $descriptorPath
        $descriptor = [IO.File]::ReadAllText($descriptorPath) | ConvertFrom-Json
        $expectedProperties = @('artifacts', 'bootstrapperSHA256', 'bootstrapperURL', 'buildVersion',
            'catalogSHA256', 'channelID', 'productID', 'productVersion', 'schemaVersion',
            'semanticVersion', 'setupSHA256', 'setupVersion', 'workloadID')
        $actualProperties = @($descriptor.PSObject.Properties.Name | Sort-Object)
        if (($actualProperties -join '|') -cne (($expectedProperties | Sort-Object) -join '|') -or
            [int]$descriptor.schemaVersion -ne 1 -or
            [string]$descriptor.channelID -cne $Target.ChannelID -or
            [string]$descriptor.buildVersion -cne $Target.BuildVersion -or
            [string]$descriptor.semanticVersion -cne $Target.SemanticVersion -or
            [string]$descriptor.productVersion -cne $Target.ProductVersion -or
            [string]$descriptor.catalogSHA256 -cne $Target.CatalogSHA256 -or
            [string]$descriptor.setupVersion -cne $Target.SetupVersion -or
            [string]$descriptor.setupSHA256 -cne $Target.SetupSHA256 -or
            [string]$descriptor.productID -cne 'Microsoft.VisualStudio.Product.BuildTools' -or
            [string]$descriptor.workloadID -cne 'Microsoft.VisualStudio.Workload.VCTools') {
            return $false
        }
        $required = @(Get-HerdrVisualStudioRequiredArtifacts)
        $artifactProperties = @($descriptor.artifacts.PSObject.Properties)
        if ($artifactProperties.Count -ne $required.Count) { return $false }
        foreach ($relativePath in $required) {
            $path = Join-Path $layout $relativePath
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
            Assert-ProvisioningCachePath -Path $path
            $expectedHashProperty = $descriptor.artifacts.PSObject.Properties[$relativePath]
            if ($null -eq $expectedHashProperty) { return $false }
            $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($actualHash -cne [string]$expectedHashProperty.Value) { return $false }
        }
        $bootstrapper = Join-Path $layout 'vs_BuildTools.exe'
        Assert-HerdrVisualStudioBootstrapper -Path $bootstrapper `
            -ExpectedSHA256 ([string]$descriptor.bootstrapperSHA256)
        Assert-HerdrVisualStudioLayoutIdentity -Layout $layout -Target $Target
        return $true
    } catch {
        return $false
    }
}

function Test-HerdrVisualStudioStoredLayoutSlot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Slot
    )

    try {
        $descriptorPath = Join-Path $Slot 'complete.json'
        if (-not (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) { return $false }
        Assert-ProvisioningCachePath -Path $descriptorPath
        $descriptor = [IO.File]::ReadAllText($descriptorPath) | ConvertFrom-Json
        $storedTarget = [pscustomobject]@{
            ChannelID = [string]$descriptor.channelID
            BuildVersion = [string]$descriptor.buildVersion
            SemanticVersion = [string]$descriptor.semanticVersion
            ProductVersion = [string]$descriptor.productVersion
            CatalogSHA256 = [string]$descriptor.catalogSHA256
            SetupVersion = [string]$descriptor.setupVersion
            SetupSHA256 = [string]$descriptor.setupSHA256
        }
        return Test-HerdrVisualStudioLayoutSlot -Slot $Slot -Target $storedTarget
    } catch {
        return $false
    }
}

function Assert-HerdrVisualStudioInstalled {
    $vswhere = [string](Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe')
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw "Visual Studio installer locator is missing: $vswhere"
    }
    $installationPath = Invoke-ProvisioningNative -Role 'Visual Studio C++ workload check' -FilePath $vswhere `
        -ArgumentList @('-latest', '-products', '*', '-requires',
            'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath')
    if ([string]::IsNullOrWhiteSpace(($installationPath -join ' ').Trim())) {
        throw 'Visual Studio C++ workload was not found after offline installation.'
    }
}

function Install-HerdrVisualStudioBuildTools {
    $visualStudioStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $cacheRoot = 'C:\HerdrBoxCache\vsbt'
    $guestStageRoot = 'C:\HerdrVisualStudioStage'
    $guestStage = Join-Path $guestStageRoot ([Guid]::NewGuid().ToString('N'))
    $guestBootstrapper = Join-Path $guestStage 'vs_BuildTools.exe'
    $guestLayout = 'C:\HerdrVisualStudioLayout'
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $guestStage -Force | Out-Null
    Assert-ProvisioningCachePath -Path $cacheRoot
    $lockPath = Join-Path $cacheRoot '.lock'
    Assert-ProvisioningCachePath -Path $lockPath
    $lock = $null
    $primaryFailure = $null
    $cleanupFailure = $null
    try {
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $target = Get-HerdrVisualStudioCurrentTarget
        $slotA = Join-Path $cacheRoot 'a'
        $slotB = Join-Path $cacheRoot 'b'
        $matchingSlots = @(@($slotA, $slotB) | Where-Object {
            Test-HerdrVisualStudioLayoutSlot -Slot $_ -Target $target
        })
        if ($matchingSlots.Count -gt 1) {
            $matchingSlots = @($matchingSlots | Select-Object -First 1)
        }
        $cacheHit = $matchingSlots.Count -eq 1
        if ($cacheHit) {
            $selectedSlot = $matchingSlots[0]
            Write-Output "Visual Studio Build Tools layout cache hit: $($target.BuildVersion)"
        } else {
            Write-Output "Visual Studio Build Tools layout cache miss: $($target.BuildVersion)"
            $bootstrapperInfo = Save-HerdrVisualStudioBootstrapper -Destination $guestBootstrapper
            $recoverableSlots = @(@($slotA, $slotB) | Where-Object {
                Test-HerdrVisualStudioUnpublishedLayoutSlot -Slot $_ -Target $target
            })
            if ($recoverableSlots.Count -gt 0) {
                $selectedSlot = $recoverableSlots[0]
                $layout = Join-Path $selectedSlot 'layout'
                $cachedBootstrapper = Join-Path $layout 'vs_BuildTools.exe'
                Assert-HerdrVisualStudioBootstrapper -Path $cachedBootstrapper `
                    -ExpectedSHA256 $bootstrapperInfo.SHA256
                Invoke-ProvisioningNative -Role 'Visual Studio Build Tools recovered layout verification' `
                    -FilePath $guestBootstrapper `
                    -ArgumentList @('--layout', $layout, '--verify', '--passive', '--wait') | Out-Null
                Write-Output "Recovered unpublished Visual Studio Build Tools layout: $($target.BuildVersion)"
            } else {
                $slotAValid = Test-HerdrVisualStudioStoredLayoutSlot -Slot $slotA
                $slotBValid = Test-HerdrVisualStudioStoredLayoutSlot -Slot $slotB
                if ($slotAValid) {
                    $selectedSlot = $slotB
                } elseif ($slotBValid) {
                    $selectedSlot = $slotA
                } else {
                    $selectedSlot = $slotA
                }
                if (Test-Path -LiteralPath $selectedSlot) {
                    Assert-ProvisioningCachePath -Path $selectedSlot
                    Remove-Item -LiteralPath $selectedSlot -Recurse -Force
                }
                $layout = Join-Path $selectedSlot 'layout'
                New-Item -ItemType Directory -Path $layout -Force | Out-Null
                Assert-ProvisioningCachePath -Path $selectedSlot
                Assert-ProvisioningCachePath -Path $layout
                $cachedBootstrapper = Join-Path $layout 'vs_BuildTools.exe'
                Invoke-ProvisioningNative -Role 'Visual Studio Build Tools layout download' -FilePath $guestBootstrapper `
                    -ArgumentList @('--layout', $layout, '--add', 'Microsoft.VisualStudio.Workload.VCTools',
                        '--includeRecommended', '--lang', 'en-US', '--passive', '--wait') | Out-Null
                if (-not (Test-Path -LiteralPath $cachedBootstrapper -PathType Leaf)) {
                    Copy-Item -LiteralPath $guestBootstrapper -Destination $cachedBootstrapper
                }
                Assert-ProvisioningCachePath -Path $cachedBootstrapper
                Assert-HerdrVisualStudioBootstrapper -Path $cachedBootstrapper -ExpectedSHA256 $bootstrapperInfo.SHA256
                Invoke-ProvisioningNative -Role 'Visual Studio Build Tools layout verification' -FilePath $guestBootstrapper `
                    -ArgumentList @('--layout', $layout, '--verify', '--passive', '--wait') | Out-Null
                Assert-HerdrVisualStudioLayoutIdentity -Layout $layout -Target $target
            }
            $currentAfterDownload = Get-HerdrVisualStudioCurrentTarget
            if (-not (Test-HerdrVisualStudioTargetEqual -Left $target -Right $currentAfterDownload)) {
                throw 'Visual Studio Current channel changed while the layout was downloading; prior layout remains active.'
            }
        }

        $layout = Join-Path $selectedSlot 'layout'
        $cachedBootstrapper = Join-Path $layout 'vs_BuildTools.exe'
        if ($cacheHit) {
            $descriptor = [IO.File]::ReadAllText((Join-Path $selectedSlot 'complete.json')) | ConvertFrom-Json
            $expectedBootstrapperHash = [string]$descriptor.bootstrapperSHA256
        } else {
            $expectedBootstrapperHash = [string]$bootstrapperInfo.SHA256
        }
        Write-ProvisioningProgress -Message 'Visual Studio Build Tools guest-local layout materialization'
        Copy-HerdrVisualStudioLayoutToGuest -Source $layout -Destination $guestLayout
        $guestLayoutBootstrapper = Join-Path $guestLayout 'vs_BuildTools.exe'
        Assert-HerdrVisualStudioBootstrapper -Path $guestLayoutBootstrapper `
            -ExpectedSHA256 $expectedBootstrapperHash
        Assert-HerdrVisualStudioLayoutIdentity -Layout $guestLayout -Target $target -GuestLocal
        Invoke-ProvisioningNative -Role 'Visual Studio Build Tools guest-local layout verification' `
            -FilePath $guestLayoutBootstrapper `
            -ArgumentList @('--layout', $guestLayout, '--verify', '--passive', '--wait') | Out-Null
        $channelManifest = Join-Path $guestLayout 'ChannelManifest.json'
        $catalog = Join-Path $guestLayout 'Catalog.json'
        Invoke-ProvisioningNative -Role 'Visual Studio Build Tools offline installation' -FilePath $guestLayoutBootstrapper `
            -ArgumentList @('--noWeb', '--noUpdateInstaller', '--wait', '--quiet', '--norestart', '--nocache',
                '--installPath', 'C:\BuildTools', '--channelId', 'VisualStudio.17.Release',
                '--productId', 'Microsoft.VisualStudio.Product.BuildTools', '--channelUri', $channelManifest,
                '--installChannelUri', $channelManifest, '--installCatalogUri', $catalog,
                '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--includeRecommended',
                '--addProductLang', 'en-US') | Out-Null
        Assert-HerdrVisualStudioInstalled

        if (-not $cacheHit) {
            $requiredArtifacts = @(Get-HerdrVisualStudioRequiredArtifacts)
            $artifactHashes = [ordered]@{}
            foreach ($relativePath in $requiredArtifacts) {
                $path = Join-Path $layout $relativePath
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    throw "Visual Studio layout artifact is missing: $relativePath"
                }
                Assert-ProvisioningCachePath -Path $path
                $artifactHashes[$relativePath] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
            }
            $descriptor = [ordered]@{
                schemaVersion = 1
                channelID = $target.ChannelID
                buildVersion = $target.BuildVersion
                semanticVersion = $target.SemanticVersion
                productVersion = $target.ProductVersion
                catalogSHA256 = $target.CatalogSHA256
                setupVersion = $target.SetupVersion
                setupSHA256 = $target.SetupSHA256
                bootstrapperURL = $bootstrapperInfo.Url
                bootstrapperSHA256 = $bootstrapperInfo.SHA256
                productID = 'Microsoft.VisualStudio.Product.BuildTools'
                workloadID = 'Microsoft.VisualStudio.Workload.VCTools'
                artifacts = $artifactHashes
            } | ConvertTo-Json -Depth 4 -Compress
            $temporaryDescriptor = Join-Path $selectedSlot 'complete.json.tmp'
            $completeDescriptor = Join-Path $selectedSlot 'complete.json'
            [IO.File]::WriteAllText($temporaryDescriptor, $descriptor, (New-Object Text.UTF8Encoding($false)))
            if (Test-Path -LiteralPath $completeDescriptor) {
                Assert-ProvisioningCachePath -Path $completeDescriptor
                Remove-Item -LiteralPath $completeDescriptor -Force
            }
            Move-Item -LiteralPath $temporaryDescriptor -Destination $completeDescriptor
            if (-not (Test-HerdrVisualStudioLayoutSlot -Slot $selectedSlot -Target $target)) {
                Remove-Item -LiteralPath $completeDescriptor -Force -ErrorAction SilentlyContinue
                throw 'Published Visual Studio Build Tools layout validation failed.'
            }
        }
        foreach ($slot in @($slotA, $slotB)) {
            if ($slot -ine $selectedSlot -and (Test-Path -LiteralPath $slot)) {
                Assert-ProvisioningCachePath -Path $slot
                Remove-Item -LiteralPath $slot -Recurse -Force
            }
        }
    } catch {
        $primaryFailure = $_
    } finally {
        if ($null -ne $lock) {
            try { $lock.Dispose() } catch { $cleanupFailure = $_ }
        }
        try {
            $fullGuestLayout = [IO.Path]::GetFullPath($guestLayout).TrimEnd('\')
            if ($fullGuestLayout -cne 'C:\HerdrVisualStudioLayout') {
                throw "Unexpected Visual Studio guest layout cleanup path: $fullGuestLayout"
            }
            if (Test-Path -LiteralPath $fullGuestLayout) {
                Remove-Item -LiteralPath $fullGuestLayout -Recurse -Force
            }
        } catch {
            Write-Warning "Visual Studio guest-layout cleanup was deferred: $($_.Exception.Message)"
        }
        try {
            $fullGuestStage = [IO.Path]::GetFullPath($guestStage).TrimEnd('\')
            $fullGuestStageRoot = [IO.Path]::GetFullPath($guestStageRoot).TrimEnd('\')
            if (-not $fullGuestStage.StartsWith($fullGuestStageRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Visual Studio guest stage escapes its root: $fullGuestStage"
            }
            if (Test-Path -LiteralPath $fullGuestStage) {
                Remove-Item -LiteralPath $fullGuestStage -Recurse -Force
            }
        } catch {
            Write-Warning "Visual Studio guest-stage cleanup was deferred: $($_.Exception.Message)"
        }
        $visualStudioStopwatch.Stop()
        Write-ProvisioningTiming -Role 'Visual Studio Build Tools total' `
            -Seconds $visualStudioStopwatch.Elapsed.TotalSeconds
    }
    if ($null -ne $primaryFailure) {
        if ($null -ne $cleanupFailure) {
            Write-Warning "Visual Studio cache cleanup also failed: $($cleanupFailure.Exception.Message)"
        }
        throw $primaryFailure
    }
    if ($null -ne $cleanupFailure) { throw $cleanupFailure }
}

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

Write-Output 'Installing Python...'
Install-ProvisioningWinGetPackage -Role 'Python' -Id 'Python.Python.3.13' -InstallerType 'burn' `
    -Scope 'machine' -Adapter 'Burn' -ExecutableName 'python.exe' `
    -CommandSourceExclusion '*\Microsoft\WindowsApps\python.exe' -DeferCommandReadiness `
    -RequireAuthenticodeSignature

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
$rustStopwatch = [Diagnostics.Stopwatch]::StartNew()
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
    Wait-ProvisioningCommandAvailable -Role 'Python' -Name 'python.exe' `
        -CommandSourceExclusion '*\Microsoft\WindowsApps\python.exe' | Out-Null
    $pythonVersion = Assert-ProvisioningCommand -Role 'Python' -Name 'python.exe' `
        -VersionArguments @('--version') -ExpectedPattern '^Python 3\.13\.\d+$'
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
            $body = Get-HerdrWebResponseText -Response $response
            if ($response.StatusCode -eq 200 -and $body.Length -ge 64 -and
                $body.Substring(0, 64) -ieq '87eb76c53073e72b766083bed5530820694253b832a762d8385bda5759f03975') {
                $serverReady = $true
            } else {
                $lastProbeError = "unexpected HTTP response status=$($response.StatusCode) characters=$($body.Length)"
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
    $rustStopwatch.Stop()
    Write-ProvisioningTiming -Role 'Rust toolchain total' -Seconds $rustStopwatch.Elapsed.TotalSeconds
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

Write-Output 'Installing Visual Studio C++ Build Tools...'
Install-HerdrVisualStudioBuildTools

if (-not (Test-Path -LiteralPath (Join-Path $ProjectDirectory 'Cargo.toml') -PathType Leaf)) {
    throw "Herdr Cargo.toml is missing from mapped project: $ProjectDirectory"
}

Write-Output "Python ready: $pythonVersion"
Write-Output "Zig ready: $zigVersion"
Write-Output "Rust ready: $rustVersion"
Write-Output "Cargo ready: $cargoVersion"
Write-Output "Cargo Nextest ready: $nextestVersion"
Write-Output "Just ready: $justVersion"
$herdrProvisioningStopwatch.Stop()
Write-ProvisioningTiming -Role 'Herdr project provisioning total' `
    -Seconds $herdrProvisioningStopwatch.Elapsed.TotalSeconds
