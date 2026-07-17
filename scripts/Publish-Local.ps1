param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$RuntimeIdentifier = "win-x64",
    [string]$DotnetPath = "dotnet"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repositoryRoot "src\CodexTokenOverlay\CodexTokenOverlay.csproj"
$artifactsRoot = Join-Path $repositoryRoot "artifacts"
$publishDirectory = Join-Path $artifactsRoot ("publish-" + $RuntimeIdentifier)
$stagingDirectory = Join-Path $artifactsRoot ("CodexTokenOverlay-" + $RuntimeIdentifier)
$archivePath = $stagingDirectory + ".zip"

foreach ($path in @($publishDirectory, $stagingDirectory)) {
    if (Test-Path -LiteralPath $path) {
        $resolvedArtifacts = [System.IO.Path]::GetFullPath($artifactsRoot)
        $resolvedPath = [System.IO.Path]::GetFullPath($path)
        if (-not $resolvedPath.StartsWith($resolvedArtifacts, [StringComparison]::OrdinalIgnoreCase)) {
            throw "拒绝清理 artifacts 目录之外的路径：$resolvedPath"
        }
        Remove-Item -LiteralPath $resolvedPath -Recurse -Force
    }
}
if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
}

& $DotnetPath publish $projectPath -c Release -r $RuntimeIdentifier --self-contained true -o $publishDirectory `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    -p:PublishTrimmed=false `
    -p:DebugType=None `
    -p:DebugSymbols=false
if ($LASTEXITCODE -ne 0) {
    throw "发布构建失败。"
}

New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $publishDirectory "CodexTokenOverlay.exe") -Destination $stagingDirectory
Copy-Item -LiteralPath (Join-Path $repositoryRoot "README.md") -Destination $stagingDirectory
Copy-Item -LiteralPath (Join-Path $repositoryRoot "README.zh-CN.md") -Destination $stagingDirectory
Copy-Item -LiteralPath (Join-Path $repositoryRoot "LICENSE") -Destination $stagingDirectory

Compress-Archive -Path (Join-Path $stagingDirectory "*") -DestinationPath $archivePath -CompressionLevel Optimal
$archiveHash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
$checksumPath = $archivePath + ".sha256"
[System.IO.File]::WriteAllText(
    $checksumPath,
    ($archiveHash.Hash.ToLowerInvariant() + "  " + (Split-Path -Leaf $archivePath) + "`n"),
    [System.Text.UTF8Encoding]::new($false))

Write-Host "发布包已生成：$archivePath"
Write-Host "校验文件已生成：$checksumPath"
