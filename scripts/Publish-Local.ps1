param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$RuntimeIdentifier = "win-x64",
    [ValidateSet("Lite", "Standalone", "Both")]
    [string]$Variant = "Both",
    [string]$DotnetPath = "dotnet"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repositoryRoot "src\CodexTokenOverlay\CodexTokenOverlay.csproj"
$artifactsRoot = Join-Path $repositoryRoot "artifacts"
$runtimeNoticePath = Join-Path $repositoryRoot "packaging\windows\INSTALL-DOTNET-RUNTIME.txt"
$resolvedArtifactsRoot = [System.IO.Path]::GetFullPath($artifactsRoot)

function Remove-ArtifactPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $artifactsPrefix = $resolvedArtifactsRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedPath.Equals($resolvedArtifactsRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $resolvedPath.StartsWith($artifactsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理 artifacts 目录之外的路径：$resolvedPath"
    }

    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

function New-ReleaseArchive {
    param(
        [Parameter(Mandatory = $true)][string]$PublishDirectory,
        [Parameter(Mandatory = $true)][string]$AssetName,
        [Parameter(Mandatory = $true)][bool]$IsLite
    )

    $stagingDirectory = Join-Path $artifactsRoot $AssetName
    $archivePath = $stagingDirectory + ".zip"
    Remove-ArtifactPath -Path $stagingDirectory
    Remove-ArtifactPath -Path $archivePath
    Remove-ArtifactPath -Path ($archivePath + ".sha256")

    New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PublishDirectory "CodexTokenOverlay.exe") -Destination $stagingDirectory
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "README.md") -Destination $stagingDirectory
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "README.zh-CN.md") -Destination $stagingDirectory
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "LICENSE") -Destination $stagingDirectory
    if ($IsLite) {
        Copy-Item -LiteralPath $runtimeNoticePath -Destination $stagingDirectory
    }

    Compress-Archive -Path (Join-Path $stagingDirectory "*") -DestinationPath $archivePath -CompressionLevel Optimal
    $archiveHash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
    $checksumPath = $archivePath + ".sha256"
    [System.IO.File]::WriteAllText(
        $checksumPath,
        ($archiveHash.Hash.ToLowerInvariant() + "  " + (Split-Path -Leaf $archivePath) + "`n"),
        [System.Text.UTF8Encoding]::new($false))

    $archiveSize = (Get-Item -LiteralPath $archivePath).Length
    Write-Host "发布包已生成：$archivePath ($archiveSize bytes)"
    Write-Host "校验文件已生成：$checksumPath"
}

New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null

# v0.2.1 起独立版恢复无后缀的兼容名称，清理预发布阶段使用过的旧后缀产物。
$obsoleteStandaloneBase = Join-Path $artifactsRoot ("CodexTokenOverlay-" + $RuntimeIdentifier + "-standalone")
foreach ($obsoletePath in @(
        $obsoleteStandaloneBase,
        ($obsoleteStandaloneBase + ".zip"),
        ($obsoleteStandaloneBase + ".zip.sha256")
    )) {
    Remove-ArtifactPath -Path $obsoletePath
}

$buildLite = $Variant -in @("Lite", "Both")
$buildStandalone = $Variant -in @("Standalone", "Both")

if ($buildLite) {
    $litePublishDirectory = Join-Path $artifactsRoot ("publish-" + $RuntimeIdentifier + "-lite")
    Remove-ArtifactPath -Path $litePublishDirectory

    & $DotnetPath publish $projectPath -c Release -r $RuntimeIdentifier --self-contained false -o $litePublishDirectory `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=false `
        -p:EnableCompressionInSingleFile=false `
        -p:DebugType=None `
        -p:DebugSymbols=false
    if ($LASTEXITCODE -ne 0) {
        throw "Lite 发布构建失败。"
    }

    $liteExecutable = Join-Path $litePublishDirectory "CodexTokenOverlay.exe"
    $liteSize = (Get-Item -LiteralPath $liteExecutable).Length
    if ($liteSize -ge 1MB) {
        throw "Lite EXE 超过 1 MiB：$liteSize bytes"
    }
    & (Join-Path $PSScriptRoot "Test-PeArchitecture.ps1") `
        -ExecutablePath $liteExecutable `
        -Architecture $RuntimeIdentifier.Substring($RuntimeIdentifier.IndexOf('-') + 1)

    # 当前机器可直接执行 x64 探针；Arm64 交叉产物由 CI 继续验证构建和 PE 架构。
    if ($RuntimeIdentifier -eq "win-x64") {
        & (Join-Path $PSScriptRoot "Test-PublishedExecutable.ps1") -ExecutablePath $liteExecutable
    }

    New-ReleaseArchive `
        -PublishDirectory $litePublishDirectory `
        -AssetName ("CodexTokenOverlay-" + $RuntimeIdentifier + "-lite") `
        -IsLite $true
}

if ($buildStandalone) {
    $standalonePublishDirectory = Join-Path $artifactsRoot ("publish-" + $RuntimeIdentifier + "-standalone")
    Remove-ArtifactPath -Path $standalonePublishDirectory

    & $DotnetPath publish $projectPath -c Release -r $RuntimeIdentifier --self-contained true -o $standalonePublishDirectory `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true `
        -p:EnableCompressionInSingleFile=true `
        -p:PublishTrimmed=false `
        -p:DebugType=None `
        -p:DebugSymbols=false
    if ($LASTEXITCODE -ne 0) {
        throw "Standalone 发布构建失败。"
    }

    & (Join-Path $PSScriptRoot "Test-PeArchitecture.ps1") `
        -ExecutablePath (Join-Path $standalonePublishDirectory "CodexTokenOverlay.exe") `
        -Architecture $RuntimeIdentifier.Substring($RuntimeIdentifier.IndexOf('-') + 1)

    New-ReleaseArchive `
        -PublishDirectory $standalonePublishDirectory `
        -AssetName ("CodexTokenOverlay-" + $RuntimeIdentifier) `
        -IsLite $false
}
