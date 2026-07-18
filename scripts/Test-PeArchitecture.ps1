param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath,
    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "arm64")]
    [string]$Architecture
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$resolvedExecutable = [System.IO.Path]::GetFullPath($ExecutablePath)
if (-not (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf)) {
    throw "找不到待检查的 PE 文件：$resolvedExecutable"
}

$expectedMachine = switch ($Architecture) {
    "x64" { 0x8664 }
    "arm64" { 0xAA64 }
}

$stream = [System.IO.File]::Open(
    $resolvedExecutable,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read)
$reader = [System.IO.BinaryReader]::new($stream)
try {
    if ($reader.ReadUInt16() -ne 0x5A4D) {
        throw "文件缺少 MZ 标头：$resolvedExecutable"
    }

    $stream.Position = 0x3C
    $peOffset = $reader.ReadInt32()
    if ($peOffset -lt 0x40 -or $peOffset -gt ($stream.Length - 6)) {
        throw "PE 标头偏移无效：$peOffset"
    }

    $stream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x00004550) {
        throw "文件缺少 PE 标头：$resolvedExecutable"
    }

    $actualMachine = $reader.ReadUInt16()
    if ($actualMachine -ne $expectedMachine) {
        throw ("PE 架构不匹配，期望 {0} (0x{1:X4})，实际为 0x{2:X4}：{3}" -f `
            $Architecture,
            $expectedMachine,
            $actualMachine,
            $resolvedExecutable)
    }

    Write-Host ("PE 架构检查通过：{0} (0x{1:X4})" -f $Architecture, $actualMachine)
}
finally {
    $reader.Dispose()
    $stream.Dispose()
}
