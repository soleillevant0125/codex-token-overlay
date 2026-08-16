param(
    [string]$DotnetPath = "dotnet",
    [string]$TargetFramework = "net10.0-windows"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repositoryRoot "src\CodexTokenOverlay\CodexTokenOverlay.csproj"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("CodexTokenOverlayTests-" + [Guid]::NewGuid().ToString("N"))
$threadId = "11111111-2222-3333-4444-555555555555"
$sessionDirectory = Join-Path $testRoot "sessions\2026\07\17"
$sessionPath = Join-Path $sessionDirectory ("rollout-2026-07-17T00-00-00-" + $threadId + ".jsonl")
$probePath = Join-Path $testRoot "probe.json"
$threadA = "aaaaaaaa-1111-2222-3333-444444444444"
$threadB = "bbbbbbbb-1111-2222-3333-444444444444"
$threadAPath = Join-Path $sessionDirectory ("rollout-2026-07-17T00-01-00-" + $threadA + ".jsonl")
$threadBPath = Join-Path $sessionDirectory ("rollout-2026-07-17T00-02-00-" + $threadB + ".jsonl")
$childThreadId = "cccccccc-1111-2222-3333-444444444444"
$childPath = Join-Path $sessionDirectory ("rollout-2026-07-17T00-03-00-" + $childThreadId + ".jsonl")
$switchProbePath = Join-Path $testRoot "thread-switch-probe.json"
$originalCodexHome = $env:CODEX_HOME

try {
    New-Item -ItemType Directory -Path $sessionDirectory -Force | Out-Null

    # 只使用合成数据，测试仓库不会包含任何真实 Codex 会话内容。
    $sessionMeta = '{"type":"session_meta","payload":{"id":"' + $threadId + '","originator":"Codex Desktop","source":"vscode"}}'
    $tokenEvent = '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":12345,"input_tokens":10000,"cached_input_tokens":7000,"output_tokens":2345,"reasoning_output_tokens":345},"last_token_usage":{"total_tokens":2048},"model_context_window":128000}}}'
    [System.IO.File]::WriteAllLines(
        $sessionPath,
        [string[]]@($sessionMeta, '{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}', $tokenEvent),
        [System.Text.UTF8Encoding]::new($false))

    $childSessionMeta = '{"type":"session_meta","payload":{"id":"' + $childThreadId + '","parent_thread_id":"' + $threadId + '","originator":"Codex Desktop","source":{"subagent":{"thread_spawn":{}}}}}'
    $childTokenEvent = '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":5000,"input_tokens":4000,"cached_input_tokens":3000,"output_tokens":1000,"reasoning_output_tokens":100},"last_token_usage":{"total_tokens":512},"model_context_window":128000}}}'
    [System.IO.File]::WriteAllLines(
        $childPath,
        [string[]]@($childSessionMeta, '{"type":"turn_context","payload":{"model":"gpt-5.6-luna"}}', $childTokenEvent),
        [System.Text.UTF8Encoding]::new($false))

    $threadATokenEvent = '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":11111,"input_tokens":10000,"cached_input_tokens":7000,"output_tokens":1111,"reasoning_output_tokens":111},"last_token_usage":{"total_tokens":1024},"model_context_window":128000}}}'
    $threadBTokenEvent = '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":22222,"input_tokens":20000,"cached_input_tokens":14000,"output_tokens":2222,"reasoning_output_tokens":222},"last_token_usage":{"total_tokens":2048},"model_context_window":128000}}}'
    $threadASessionMeta = '{"type":"session_meta","payload":{"id":"' + $threadA + '","originator":"Codex Desktop","source":"vscode"}}'
    $threadBSessionMeta = '{"type":"session_meta","payload":{"id":"' + $threadB + '","originator":"Codex Desktop","source":"vscode"}}'
    [System.IO.File]::WriteAllLines(
        $threadAPath,
        [string[]]@($threadASessionMeta, $threadATokenEvent),
        [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllLines(
        $threadBPath,
        [string[]]@($threadBSessionMeta, $threadBTokenEvent),
        [System.Text.UTF8Encoding]::new($false))

    $threadBWriteUtc = [DateTime]::UtcNow.AddMinutes(-10)
    $threadAWriteUtc = $threadBWriteUtc.AddMinutes(5)
    [System.IO.File]::SetLastWriteTimeUtc($threadBPath, $threadBWriteUtc)
    [System.IO.File]::SetLastWriteTimeUtc($threadAPath, $threadAWriteUtc)
    $threadAWriteTicks = [System.IO.File]::GetLastWriteTimeUtc($threadAPath).Ticks
    $threadBWriteTicks = [System.IO.File]::GetLastWriteTimeUtc($threadBPath).Ticks

    & $DotnetPath build $projectPath -c Release --nologo "-p:TargetFramework=$TargetFramework"
    if ($LASTEXITCODE -ne 0) {
        throw "项目构建失败。"
    }

    $applicationDll = Join-Path $repositoryRoot "src\CodexTokenOverlay\bin\Release\$TargetFramework\CodexTokenOverlay.dll"
    $applicationAssembly = [System.Reflection.Assembly]::LoadFrom($applicationDll)
    $probeRunnerType = $applicationAssembly.GetType("CodexTokenOverlay.ProbeRunner", $false)
    if ($null -eq $probeRunnerType) {
        throw "ProbeRunner 统一探针入口不存在。"
    }
    $tryRun = $probeRunnerType.GetMethod(
        "TryRun",
        [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static)
    if ($null -eq $tryRun) {
        throw "ProbeRunner.TryRun 入口不存在。"
    }
    $normalStartupArguments = [System.Collections.Generic.List[string]]::new()
    $normalStartupInvocation = New-Object object[] 2
    $normalStartupInvocation[0] = $normalStartupArguments
    $normalStartupInvocation[1] = [string](Join-Path $testRoot "sessions")
    $normalStartupResult = $tryRun.Invoke(
        $null,
        $normalStartupInvocation)
    if ($normalStartupResult -ne $false) {
        throw "正常 UI 启动不应被探针入口接管。"
    }

    # 先从统一入口确认新参数会被探针接管，避免缺失实现时误入 WinForms 启动路径。
    $switchProbeArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @("--thread-switch-probe", $switchProbePath, $threadA, $threadB)) {
        $switchProbeArguments.Add($argument)
    }
    $switchProbeInvocation = New-Object object[] 2
    $switchProbeInvocation[0] = $switchProbeArguments
    $switchProbeInvocation[1] = [string](Join-Path $testRoot "sessions")
    $switchProbeHandled = $tryRun.Invoke($null, $switchProbeInvocation)
    if ($switchProbeHandled -ne $true -or -not (Test-Path -LiteralPath $switchProbePath)) {
        throw "线程切换探针结果缺失。"
    }
    Remove-Item -LiteralPath $switchProbePath -Force

    & $DotnetPath $applicationDll --thread-switch-probe $switchProbePath $threadA $threadB --sessions (Join-Path $testRoot "sessions")
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $switchProbePath)) {
        throw "线程切换探针执行失败。"
    }

    $switchResult = Get-Content -LiteralPath $switchProbePath -Encoding UTF8 -Raw | ConvertFrom-Json
    $switchChecks = @(
        $switchResult.FirstSnapshot.ThreadId -eq $threadA
        $switchResult.FirstSnapshot.TotalTokens -eq 11111
        $switchResult.SecondSnapshot.ThreadId -eq $threadB
        $switchResult.SecondSnapshot.TotalTokens -eq 22222
        $switchResult.SecondVersion -gt $switchResult.FirstVersion
        [System.IO.File]::GetLastWriteTimeUtc($threadAPath).Ticks -eq $threadAWriteTicks
        [System.IO.File]::GetLastWriteTimeUtc($threadBPath).Ticks -eq $threadBWriteTicks
    )
    if ($switchChecks -contains $false) {
        throw "静止线程切换结果与预期不一致。"
    }

    & $DotnetPath $applicationDll --probe $probePath --sessions (Join-Path $testRoot "sessions")
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $probePath)) {
        throw "日志探针执行失败。"
    }

    $snapshot = Get-Content -LiteralPath $probePath -Encoding UTF8 -Raw | ConvertFrom-Json
    $checks = @(
        $snapshot.ThreadId -eq $threadId
        $snapshot.TotalTokens -eq 17345
        $snapshot.InputTokens -eq 14000
        $snapshot.CachedInputTokens -eq 10000
        $snapshot.OutputTokens -eq 3345
        $snapshot.ReasoningOutputTokens -eq 445
        $snapshot.ContextUsedTokens -eq 2048
        $snapshot.ContextWindowTokens -eq 128000
        $snapshot.UncachedInputTokens -eq 4000
        $snapshot.PricingUsages.Count -eq 2
        ($snapshot.PricingUsages.Model -contains 'gpt-5.6-sol')
        ($snapshot.PricingUsages.Model -contains 'gpt-5.6-luna')
        @($snapshot.PricingUsages | Where-Object IsMainAgent).Count -eq 1
        @($snapshot.PricingUsages | Where-Object { -not $_.IsMainAgent }).Count -eq 1
    )
    if ($checks -contains $false) {
        throw "解析结果与合成日志不一致。"
    }

    # 再验证 CODEX_HOME 自动发现，不要求用户把程序放在特定目录。
    Remove-Item -LiteralPath $probePath -Force
    $env:CODEX_HOME = $testRoot
    & $DotnetPath $applicationDll --probe $probePath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $probePath)) {
        throw "CODEX_HOME 自动发现测试失败。"
    }
    $autoDiscoveredSnapshot = Get-Content -LiteralPath $probePath -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($autoDiscoveredSnapshot.ThreadId -ne $threadId -or $autoDiscoveredSnapshot.TotalTokens -ne 17345) {
        throw "CODEX_HOME 自动发现结果不正确。"
    }

    Write-Host "日志解析测试通过。"
}
finally {
    if ($null -eq $originalCodexHome) {
        Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    }
    else {
        $env:CODEX_HOME = $originalCodexHome
    }

    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $isInsideTemporaryRoot = $resolvedTestRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)
    $hasExpectedPrefix = (Split-Path -Leaf $resolvedTestRoot).StartsWith("CodexTokenOverlayTests-", [StringComparison]::Ordinal)
    if ($isInsideTemporaryRoot -and $hasExpectedPrefix) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
