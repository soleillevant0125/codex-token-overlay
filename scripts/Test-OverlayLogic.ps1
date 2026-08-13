param(
    [ValidateSet('Settings', 'Presentation', 'Layout', 'Interaction', 'Window', 'Form', 'Attachment', 'Theme', 'All')]
    [string]$Area = 'All',
    [string]$DotnetPath = 'dotnet',
    [string]$TargetFramework = 'net10.0-windows'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$implementedAreas = @('Settings', 'Presentation', 'Layout', 'Interaction', 'Window', 'Form', 'Attachment', 'Theme')
$areas = if ($Area -eq 'All') { $implementedAreas } else { @($Area) }

$unsupportedAreas = $areas | Where-Object { $_ -notin $implementedAreas }
if ($unsupportedAreas.Count -gt 0) {
    throw "尚未实现测试区域：$($unsupportedAreas -join ', ')"
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repositoryRoot 'src\CodexTokenOverlay\CodexTokenOverlay.csproj'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'CodexTokenOverlayLogicTests-' + [Guid]::NewGuid().ToString('N'))
$applicationDll = Join-Path $repositoryRoot "src\CodexTokenOverlay\bin\Release\$TargetFramework\CodexTokenOverlay.dll"

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Rect {
    param(
        [object]$Actual,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [string]$Message
    )

    $actualText = if ($null -eq $Actual) {
        '<null>'
    }
    else {
        "$($Actual.X),$($Actual.Y),$($Actual.Width),$($Actual.Height)"
    }
    $expectedText = "$X,$Y,$Width,$Height"
    Assert-Condition ($actualText -eq $expectedText) "$Message expected=$expectedText actual=$actualText"
}

function Assert-LayoutEqual {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Message
    )

    $actualText = $Actual | ConvertTo-Json -Compress -Depth 8
    $expectedText = $Expected | ConvertTo-Json -Compress -Depth 8
    Assert-Condition ($actualText -eq $expectedText) "$Message expected=$expectedText actual=$actualText"
}

function Get-MethodCallTokens {
    param([System.Reflection.MethodBase]$Method)

    $opcodeLookup = @{}
    foreach ($field in [System.Reflection.Emit.OpCodes].GetFields([System.Reflection.BindingFlags]'Public, Static')) {
        $opcode = $field.GetValue($null)
        $value = [int]$opcode.Value
        if ($value -lt 0) { $value += 65536 }
        $opcodeLookup[$value] = $opcode
    }

    $body = $Method.GetMethodBody()
    if ($null -eq $body) { return @() }
    $bytes = $body.GetILAsByteArray()
    $offset = 0
    $tokens = @()
    while ($offset -lt $bytes.Length) {
        $first = [int]$bytes[$offset]
        $offset++
        $value = if ($first -eq 0xFE) {
            $second = [int]$bytes[$offset]
            $offset++
            0xFE00 -bor $second
        }
        else {
            $first
        }
        $opcode = $opcodeLookup[$value]
        if ($null -eq $opcode) { throw "未知 IL opcode：$value" }
        $operandStart = $offset
        $operandLength = switch ($opcode.OperandType.ToString()) {
            'InlineNone' { 0 }
            'ShortInlineBrTarget' { 1 }
            'ShortInlineI' { 1 }
            'ShortInlineVar' { 1 }
            'InlineVar' { 2 }
            'InlineI' { 4 }
            'InlineBrTarget' { 4 }
            'InlineField' { 4 }
            'InlineMethod' { 4 }
            'InlineSig' { 4 }
            'InlineString' { 4 }
            'InlineTok' { 4 }
            'InlineType' { 4 }
            'ShortInlineR' { 4 }
            'InlineI8' { 8 }
            'InlineR' { 8 }
            'InlineSwitch' { 4 + (4 * [BitConverter]::ToInt32($bytes, $offset)) }
            default { throw "不支持的 IL operand：$($opcode.OperandType)" }
        }
        if ($opcode.OperandType.ToString() -eq 'InlineMethod') {
            $tokens += [BitConverter]::ToInt32($bytes, $operandStart)
        }
        $offset += $operandLength
    }
    return $tokens
}

function Test-MethodCallChain {
    param(
        [System.Reflection.MethodInfo]$Caller,
        [System.Reflection.MethodInfo[]]$Callees,
        [int]$MaximumSpan = 4
    )

    $calls = @(
        foreach ($token in @(Get-MethodCallTokens $Caller)) {
            $Caller.Module.ResolveMethod($token)
        }
    )
    for ($start = 0; $start -lt $calls.Count; $start++) {
        if ($calls[$start].Module -ne $Callees[0].Module -or
            $calls[$start].MetadataToken -ne $Callees[0].MetadataToken) {
            continue
        }

        $callIndex = $start + 1
        for ($calleeIndex = 1; $calleeIndex -lt $Callees.Count; $calleeIndex++) {
            while ($callIndex -lt $calls.Count -and
                ($calls[$callIndex].Module -ne $Callees[$calleeIndex].Module -or
                 $calls[$callIndex].MetadataToken -ne $Callees[$calleeIndex].MetadataToken)) {
                $callIndex++
            }
            if ($callIndex -ge $calls.Count -or $callIndex - $start -gt $MaximumSpan) {
                break
            }
            $callIndex++
        }
        if ($calleeIndex -eq $Callees.Count -and $callIndex - 1 - $start -le $MaximumSpan) {
            return $true
        }
    }
    return $false
}

function Get-ProbeCase {
    param(
        [object]$Response,
        [string]$Name
    )

    $case = @($Response.Cases | Where-Object { $_.Name -eq $Name })
    if ($case.Count -ne 1) {
        throw "设置探针未返回唯一案例：$Name"
    }

    return $case[0]
}

function Copy-WindowCandidate {
    param(
        [hashtable]$Candidate,
        [hashtable]$Overrides
    )

    $copy = @{}
    foreach ($entry in $Candidate.GetEnumerator()) {
        $copy[$entry.Key] = $entry.Value
    }
    foreach ($entry in $Overrides.GetEnumerator()) {
        $copy[$entry.Key] = $entry.Value
    }
    return $copy
}

function Assert-InteractionTrace {
    param(
        [object]$Case,
        [object[]]$Expected
    )

    $actual = @($Case.Events)
    Assert-Condition ($actual.Count -eq $Expected.Count) "交互案例 $($Case.Name) 的状态轨迹长度不正确。"
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        $actualEvent = $actual[$index]
        $expectedEvent = $Expected[$index]
        Assert-Condition ($actualEvent.State -eq $expectedEvent.State) "交互案例 $($Case.Name) 的第 $index 步状态不正确。"
        Assert-Condition ($actualEvent.ShouldPollOutsideClicks -eq $expectedEvent.Polling) "交互案例 $($Case.Name) 的第 $index 步轮询状态不正确。"
        Assert-Condition ($actualEvent.IsWaitingForOpeningClickRelease -eq $expectedEvent.WaitingForRelease) "交互案例 $($Case.Name) 的第 $index 步打开点击释放状态不正确。"
        Assert-Condition ($actualEvent.StateChanged -eq $expectedEvent.StateChanged) "交互案例 $($Case.Name) 的第 $index 步状态变更结果不正确。"
    }
}

function Invoke-JsonProbe {
    param(
        [string]$Mode,
        [object[]]$Cases
    )

    $requestPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-request.json")
    $outputPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-output.json")
    $request = @{ Cases = $Cases } | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText(
        $requestPath,
        $request,
        [System.Text.UTF8Encoding]::new($false))

    $probeProcess = $null
    try {
        $argumentString = '"{0}" {1} "{2}" "{3}"' -f `
            $applicationDll.Replace('"', '\"'), `
            $Mode, `
            $outputPath.Replace('"', '\"'), `
            $requestPath.Replace('"', '\"')
        $probeProcess = Start-Process `
            -FilePath $DotnetPath `
            -ArgumentList $argumentString `
            -WindowStyle Hidden `
            -PassThru

        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            $probeProcess.WaitForExit()
            throw "设置探针未在 10 秒内生成结果：$Mode"
        }

        if ($probeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw "设置探针执行失败：$Mode"
        }

        return Get-Content -LiteralPath $outputPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    finally {
        if ($null -ne $probeProcess) {
            try {
                if (-not $probeProcess.HasExited) {
                    $probeProcess.Kill()
                    $probeProcess.WaitForExit()
                }
            }
            finally {
                $probeProcess.Dispose()
            }
        }
    }
}

function Invoke-WindowDpiAwarenessReflectionProbe {
    $probeScriptPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-window-dpi-probe.ps1")
    $outputPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-window-dpi-output.json")
    $probeScript = @'
param(
    [string]$ApplicationDll,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$assembly = [System.Reflection.Assembly]::LoadFrom($ApplicationDll)
$probeRunner = $assembly.GetType('CodexTokenOverlay.ProbeRunner', $true)
$bindingFlags = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Static
$prepare = $probeRunner.GetMethod('PrepareWindowProbeDpiAwareness', $bindingFlags)
$dpiMode = if ($null -eq $prepare) {
    '<method-missing>'
}
else {
    $null = $prepare.Invoke($null, $null)
    $application = [Type]::GetType('System.Windows.Forms.Application, System.Windows.Forms', $true)
    $application.GetProperty('HighDpiMode').GetValue($null).ToString()
}

$json = @{ DpiMode = $dpiMode } | ConvertTo-Json
[System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
'@
    [System.IO.File]::WriteAllText(
        $probeScriptPath,
        $probeScript,
        [System.Text.UTF8Encoding]::new($false))

    $probeProcess = $null
    try {
        $powershellPath = (Get-Process -Id $PID).Path
        $argumentString = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ApplicationDll "{1}" -OutputPath "{2}"' -f `
            $probeScriptPath.Replace('"', '\"'), `
            $applicationDll.Replace('"', '\"'), `
            $outputPath.Replace('"', '\"')
        $probeProcess = Start-Process `
            -FilePath $powershellPath `
            -ArgumentList $argumentString `
            -WindowStyle Hidden `
            -PassThru

        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            $probeProcess.WaitForExit()
            throw '窗口 DPI awareness 反射探针未在 10 秒内结束。'
        }

        if ($probeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw '窗口 DPI awareness 反射探针执行失败。'
        }

        return Get-Content -LiteralPath $outputPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    finally {
        if ($null -ne $probeProcess) {
            try {
                if (-not $probeProcess.HasExited) {
                    $probeProcess.Kill()
                    $probeProcess.WaitForExit()
                }
            }
            finally {
                $probeProcess.Dispose()
            }
        }
    }
}

function Invoke-KnownTargetRefreshReflectionProbe {
    $probeScriptPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-known-target-probe.ps1")
    $outputPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-known-target-output.json")
    $probeScript = @'
param(
    [string]$ApplicationDll,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$assembly = [System.Reflection.Assembly]::LoadFrom($ApplicationDll)
$locatorType = $assembly.GetType('CodexTokenOverlay.CodexWindowLocator', $true)
$candidateType = $assembly.GetType('CodexTokenOverlay.WindowCandidateFacts', $true)
$rectType = $assembly.GetType('CodexTokenOverlay.IntRect', $true)
$selectionType = $assembly.GetType('CodexTokenOverlay.CodexWindowCandidateSelection', $true)
$bindingFlags = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Static
$method = $locatorType.GetMethod('TrySelectKnownCodexTarget', $bindingFlags)
$readMethod = $locatorType.GetMethod('IsCandidateReadValid', $bindingFlags)
$identityMethod = $locatorType.GetMethod('IsKnownTargetIdentityValid', $bindingFlags)
if ($null -eq $method) {
    throw 'TrySelectKnownCodexTarget is unsupported.'
}
if ($null -eq $readMethod) {
    throw 'IsCandidateReadValid is unsupported.'
}
if ($null -eq $identityMethod) {
    throw 'IsKnownTargetIdentityValid is unsupported.'
}

function New-Rect([int]$X, [int]$Y, [int]$Width, [int]$Height) {
    return [System.Activator]::CreateInstance($rectType, @($X, $Y, $Width, $Height))
}

function New-Candidate(
    [long]$Handle,
    [uint32]$ProcessId,
    [long]$Style,
    [object]$Bounds,
    [string]$ClassName = 'Chrome_WidgetWin_1') {
    return [System.Activator]::CreateInstance($candidateType, @(
        [IntPtr]::new($Handle),
        $ProcessId,
        $true,
        $true,
        $false,
        [IntPtr]::Zero,
        $Style,
        $Bounds,
        $ClassName))
}

function Invoke-Selection([long]$PreviousHost, [uint32]$ProcessId, [object[]]$Candidates) {
    $listType = [System.Collections.Generic.List``1].MakeGenericType($candidateType)
    $list = [System.Activator]::CreateInstance($listType)
    foreach ($candidate in $Candidates) {
        $list.Add($candidate)
    }
    $arguments = @([IntPtr]::new($PreviousHost), $ProcessId, $list, $null)
    $success = [bool]$method.Invoke($null, $arguments)
    $selection = if ($success) { $arguments[3] } else { $null }
    return [pscustomobject]@{
        Success = $success
        HostHandle = if ($null -eq $selection) { $null } else { $selection.Host.Handle.ToInt64() }
        HostBounds = if ($null -eq $selection) { $null } else { $selection.Host.Bounds }
    }
}

$normalStyle = 0x240100L
$toolStyle = 0x2800A8L
$movedHost = New-Candidate 100 10 $normalStyle (New-Rect 40 60 1500 1000)
$movedTool = New-Candidate 200 10 $toolStyle (New-Rect 1320 410 410 400)
$otherProcessHost = New-Candidate 100 11 $normalStyle (New-Rect 80 90 1500 1000)

$result = @{
    RefreshWhileOverlayForeground = Invoke-Selection 100 10 @($movedHost, $movedTool)
    RejectProcessChange = Invoke-Selection 100 10 @($otherProcessHost)
    DestroyedHostFailsClosed = Invoke-Selection 100 10 @($movedTool)
    ClassReadFailureAccepted = [bool]$readMethod.Invoke($null, @(0, 1L, 0))
    StyleReadFailureAccepted = [bool]$readMethod.Invoke($null, @(20, 0L, 1400))
    ZeroStyleWithoutErrorAccepted = [bool]$readMethod.Invoke($null, @(20, 0L, 0))
    SameConfirmedIdentityAccepted = [bool]$identityMethod.Invoke($null, @(100L, [uint32]10, 100L, [uint32]10))
    ReusedHandleDifferentProcessAccepted = [bool]$identityMethod.Invoke($null, @(100L, [uint32]10, 100L, [uint32]11))
    DifferentHostSameProcessAccepted = [bool]$identityMethod.Invoke($null, @(100L, [uint32]10, 101L, [uint32]10))
}
[System.IO.File]::WriteAllText(
    $OutputPath,
    ($result | ConvertTo-Json -Depth 8),
    [System.Text.UTF8Encoding]::new($false))
'@
    [System.IO.File]::WriteAllText(
        $probeScriptPath,
        $probeScript,
        [System.Text.UTF8Encoding]::new($false))

    $probeProcess = $null
    try {
        $powershellPath = (Get-Process -Id $PID).Path
        $argumentString = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ApplicationDll "{1}" -OutputPath "{2}"' -f `
            $probeScriptPath.Replace('"', '\"'), `
            $applicationDll.Replace('"', '\"'), `
            $outputPath.Replace('"', '\"')
        $probeProcess = Start-Process `
            -FilePath $powershellPath `
            -ArgumentList $argumentString `
            -WindowStyle Hidden `
            -PassThru

        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            $probeProcess.WaitForExit()
            throw '已知 Codex 目标刷新反射探针未在 10 秒内结束。'
        }
        if ($probeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw '已知 Codex 目标刷新反射探针执行失败。'
        }
        return Get-Content -LiteralPath $outputPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    finally {
        if ($null -ne $probeProcess) {
            try {
                if (-not $probeProcess.HasExited) {
                    $probeProcess.Kill()
                    $probeProcess.WaitForExit()
                }
            }
            finally {
                $probeProcess.Dispose()
            }
        }
    }
}

function Invoke-HostSurfaceContractReflectionProbe {
    $probeScriptPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-host-surface-contract-probe.ps1")
    $outputPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-host-surface-contract-output.json")
    $probeScript = @'
param([string]$ApplicationDll, [string]$OutputPath)

$ErrorActionPreference = 'Stop'
$result = @{
    Error = $null
    SelectionProperties = @()
    TargetProperties = @()
    LayoutRequestProperties = @()
    DiagnosticProperties = @()
    HasKnownHostMethod = $false
    IgnoredOverlayThenHost = $null
    ToolBeforeHost = $null
    OtherAppBeforeHost = $null
    EmptyAfterIgnoredOverlay = $null
    VisibleInvalidBeforeHostIsKnownHost = $null
    RecoveredAfterCompleteReadsIsKnownHost = $null
    InactiveInvalidBeforeHostIsKnownHost = $null
    DestroyedDuringReadBeforeHostIsKnownHost = $null
    OwnShadowBeforeHostIsKnownHost = $null
    ForeignShadowBeforeHostIsKnownHost = $null
    CodexNonHostBeforeHostIsKnownHost = $null
    OwnUnreadableBeforeHostIsKnownHost = $null
    ForeignUnreadableBeforeHostIsKnownHost = $null
    DestroyedForeignBeforeHostIsKnownHost = $null
    ZeroIgnoredProcessDoesNotSkip = $null
    ExplicitHandleStillSkippedWithZeroProcess = $null
    HasCurrentProcessWrapper = $false
}
try {
    $assembly = [System.Reflection.Assembly]::LoadFrom($ApplicationDll)
    $locatorType = $assembly.GetType('CodexTokenOverlay.CodexWindowLocator', $false)
    $selectionType = $assembly.GetType('CodexTokenOverlay.CodexWindowCandidateSelection', $false)
    $targetType = $assembly.GetType('CodexTokenOverlay.CodexWindowTarget', $false)
    $layoutRequestType = $assembly.GetType('CodexTokenOverlay.OverlayLayoutRequest', $false)
    $candidateType = $assembly.GetType('CodexTokenOverlay.WindowSurfaceCandidate', $false)
    $rectType = $assembly.GetType('CodexTokenOverlay.IntRect', $false)
    $bindingFlags = [System.Reflection.BindingFlags]'Public, NonPublic, Static'

    if ($null -ne $selectionType) { $result.SelectionProperties = @($selectionType.GetProperties().Name | Sort-Object) }
    if ($null -ne $targetType) { $result.TargetProperties = @($targetType.GetProperties().Name | Sort-Object) }
    if ($null -ne $layoutRequestType) { $result.LayoutRequestProperties = @($layoutRequestType.GetProperties().Name | Sort-Object) }
    if ($null -ne $locatorType) {
        $result.HasKnownHostMethod = $null -ne $locatorType.GetMethod('IsPointOnKnownHost', $bindingFlags)
        $diagnosticMethod = $locatorType.GetMethod('GetForegroundWindowProbe', $bindingFlags)
        if ($null -ne $diagnosticMethod) {
            $diagnostic = $diagnosticMethod.Invoke($null, @())
            $result.DiagnosticProperties = @($diagnostic.PSObject.Properties.Name | Sort-Object)
        }
    }

    $selectionMethod = if ($null -eq $locatorType) { $null } else { $locatorType.GetMethod('SelectUnderlyingWindowAtPoint', $bindingFlags) }
    $knownHostSelectionMethod = if ($null -eq $locatorType) { $null } else { $locatorType.GetMethod('IsUnderlyingWindowKnownHost', $bindingFlags) }
    $currentProcessKnownHostMethod = if ($null -eq $locatorType) {
        $null
    } else {
        $locatorType.GetMethod('IsUnderlyingWindowKnownHostForCurrentProcess', $bindingFlags)
    }
    $result.HasCurrentProcessWrapper = $null -ne $currentProcessKnownHostMethod
    $unreadableCandidateMethod = if ($null -eq $locatorType) { $null } else { $locatorType.GetMethod('CreateUnreadableSurfaceCandidate', $bindingFlags) }
    $boundsReadProperty = if ($null -eq $candidateType) { $null } else { $candidateType.GetProperty('BoundsReadSucceeded') }
    if ($null -ne $selectionMethod -and $null -ne $candidateType -and $null -ne $rectType) {
        function New-Rect([int]$X, [int]$Y, [int]$Width, [int]$Height) {
            [System.Activator]::CreateInstance($rectType, @($X, $Y, $Width, $Height))
        }
        function New-Surface([long]$Handle, [uint32]$ProcessId, [bool]$IsVisible, [bool]$IsMinimized, [object]$Bounds, [bool]$BoundsReadSucceeded = $true) {
            $candidate = [System.Activator]::CreateInstance($candidateType, @($Handle, $ProcessId, $IsVisible, $IsMinimized, $Bounds))
            if ($null -ne $boundsReadProperty) {
                $boundsReadProperty.SetValue($candidate, $BoundsReadSucceeded)
            }
            $candidate
        }
        function Invoke-SurfaceSelection(
            [object[]]$Candidates,
            [uint32]$IgnoredProcessId) {
            $listType = [System.Collections.Generic.List``1].MakeGenericType($candidateType)
            $list = [System.Activator]::CreateInstance($listType)
            foreach ($candidate in $Candidates) { $list.Add($candidate) }
            $ignored = [System.Collections.Generic.HashSet[long]]::new()
            $null = $ignored.Add(900L)
            $selectionMethod.Invoke($null, @(
                $list,
                [Drawing.Point]::new(50, 50),
                $ignored,
                $IgnoredProcessId))
        }

        $fullBounds = New-Rect 0 0 500 400
        $overlay = New-Surface 900 40 $true $false $fullBounds
        $hostSurface = New-Surface 100 10 $true $false $fullBounds
        $tool = New-Surface 200 10 $true $false $fullBounds
        $otherApp = New-Surface 300 30 $true $false $fullBounds
        $result.IgnoredOverlayThenHost = Invoke-SurfaceSelection -Candidates @($overlay, $hostSurface) -IgnoredProcessId ([uint32]0)
        $result.ToolBeforeHost = Invoke-SurfaceSelection -Candidates @($overlay, $tool, $hostSurface) -IgnoredProcessId ([uint32]0)
        $result.OtherAppBeforeHost = Invoke-SurfaceSelection -Candidates @($overlay, $otherApp, $hostSurface) -IgnoredProcessId ([uint32]0)
        $result.EmptyAfterIgnoredOverlay = Invoke-SurfaceSelection -Candidates @($overlay) -IgnoredProcessId ([uint32]0)

        if ($null -ne $knownHostSelectionMethod -and $null -ne $boundsReadProperty) {
            function Invoke-KnownHostSelection(
                [object[]]$Candidates,
                [uint32]$IgnoredProcessId) {
                $listType = [System.Collections.Generic.List``1].MakeGenericType($candidateType)
                $list = [System.Activator]::CreateInstance($listType)
                foreach ($candidate in $Candidates) { $list.Add($candidate) }
                $ignored = [System.Collections.Generic.HashSet[long]]::new()
                $null = $ignored.Add(900L)
                [bool]$knownHostSelectionMethod.Invoke($null, @(
                    $list,
                    [Drawing.Point]::new(50, 50),
                    $ignored,
                    100L,
                    [uint32]10,
                    $IgnoredProcessId))
            }

            function Invoke-CurrentProcessKnownHostSelection([object[]]$Candidates) {
                $listType = [System.Collections.Generic.List``1].MakeGenericType($candidateType)
                $list = [System.Activator]::CreateInstance($listType)
                foreach ($candidate in $Candidates) { $list.Add($candidate) }
                $ignored = [System.Collections.Generic.HashSet[long]]::new()
                $null = $ignored.Add(900L)
                [bool]$currentProcessKnownHostMethod.Invoke($null, @(
                    $list,
                    [Drawing.Point]::new(50, 50),
                    $ignored,
                    100L,
                    [uint32]10))
            }

            $invalidBlocker = New-Surface 250 25 $true $false (New-Rect 0 0 0 0) $false
            $recoveredBlocker = New-Surface 250 25 $true $false (New-Rect 600 0 500 400) $true
            $invisibleInvalid = New-Surface 260 26 $false $false (New-Rect 0 0 0 0) $false
            $minimizedInvalid = New-Surface 270 27 $true $true (New-Rect 0 0 0 0) $false
            $ignoredInvalid = New-Surface 900 40 $true $false (New-Rect 0 0 0 0) $false
            $overlayProcessId = [uint32]40
            $ownShadow = New-Surface 901 $overlayProcessId $true $false $fullBounds
            $foreignShadow = New-Surface 901 41 $true $false $fullBounds
            $codexNonHost = New-Surface 200 10 $true $false $fullBounds
            $ownUnreadable = New-Surface 902 $overlayProcessId $true $false (New-Rect 0 0 0 0) $false
            $foreignUnreadable = New-Surface 903 41 $true $false (New-Rect 0 0 0 0) $false
            $zeroPidBlocker = New-Surface 904 ([uint32]0) $true $false $fullBounds
            $runtimeOverlayProcessId = [uint32]$PID
            $runtimeOverlay = New-Surface 900 $runtimeOverlayProcessId $true $false $fullBounds
            $runtimeOwnShadow = New-Surface 901 $runtimeOverlayProcessId $true $false $fullBounds

            $result.VisibleInvalidBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $invalidBlocker, $hostSurface) -IgnoredProcessId ([uint32]0)
            $result.RecoveredAfterCompleteReadsIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $recoveredBlocker, $hostSurface) -IgnoredProcessId ([uint32]0)
            $result.InactiveInvalidBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($ignoredInvalid, $invisibleInvalid, $minimizedInvalid, $hostSurface) -IgnoredProcessId ([uint32]0)
            $result.OwnShadowBeforeHostIsKnownHost = Invoke-CurrentProcessKnownHostSelection -Candidates @($runtimeOverlay, $runtimeOwnShadow, $hostSurface)
            $result.ForeignShadowBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $foreignShadow, $hostSurface) -IgnoredProcessId $overlayProcessId
            $result.CodexNonHostBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $codexNonHost, $hostSurface) -IgnoredProcessId $overlayProcessId
            $result.OwnUnreadableBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $ownUnreadable, $hostSurface) -IgnoredProcessId $overlayProcessId
            $result.ForeignUnreadableBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $foreignUnreadable, $hostSurface) -IgnoredProcessId $overlayProcessId
            $result.ZeroIgnoredProcessDoesNotSkip = Invoke-KnownHostSelection -Candidates @($zeroPidBlocker, $hostSurface) -IgnoredProcessId ([uint32]0)
            $result.ExplicitHandleStillSkippedWithZeroProcess = Invoke-KnownHostSelection -Candidates @($overlay, $hostSurface) -IgnoredProcessId ([uint32]0)
            if ($null -ne $unreadableCandidateMethod) {
                $destroyedDuringRead = $unreadableCandidateMethod.Invoke($null, @(
                    280L,
                    [uint32]41,
                    $false,
                    $false,
                    $false))
                $result.DestroyedDuringReadBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $destroyedDuringRead, $hostSurface) -IgnoredProcessId ([uint32]0)
                $result.DestroyedForeignBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $destroyedDuringRead, $hostSurface) -IgnoredProcessId $overlayProcessId
            }
        }
    }
}
catch {
    $result.Error = $_.Exception.ToString()
}
[System.IO.File]::WriteAllText($OutputPath, ($result | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
'@
    [System.IO.File]::WriteAllText($probeScriptPath, $probeScript, [System.Text.UTF8Encoding]::new($false))

    $probeProcess = $null
    try {
        $powershellPath = (Get-Process -Id $PID).Path
        $argumentString = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ApplicationDll "{1}" -OutputPath "{2}"' -f `
            $probeScriptPath.Replace('"', '\"'), `
            $applicationDll.Replace('"', '\"'), `
            $outputPath.Replace('"', '\"')
        $probeProcess = Start-Process -FilePath $powershellPath -ArgumentList $argumentString -WindowStyle Hidden -PassThru
        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            $probeProcess.WaitForExit()
            throw '主窗口表面契约反射探针未在 10 秒内结束。'
        }
        if ($probeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw '主窗口表面契约反射探针执行失败。'
        }
        Get-Content -LiteralPath $outputPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    finally {
        if ($null -ne $probeProcess) {
            try {
                if (-not $probeProcess.HasExited) {
                    $probeProcess.Kill()
                    $probeProcess.WaitForExit()
                }
            }
            finally { $probeProcess.Dispose() }
        }
    }
}

function Invoke-ManualCoordinatorReflectionProbe {
    $probeScriptPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-manual-coordinator-probe.ps1")
    $outputPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-manual-coordinator-output.json")
    $probeScript = @'
param(
    [string]$ApplicationDll,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$assembly = [System.Reflection.Assembly]::LoadFrom($ApplicationDll)
$coordinatorType = $assembly.GetType('CodexTokenOverlay.ManualAttachmentCoordinator', $true)
$snapshotType = $assembly.GetType('CodexTokenOverlay.ManualPlacementSnapshot', $true)
$targetsType = $assembly.GetType('CodexTokenOverlay.AttachmentTargetBounds', $true)
$displayType = $assembly.GetType('CodexTokenOverlay.CollapsedDisplayMode', $true)
$gestureType = $assembly.GetType('CodexTokenOverlay.OverlayEditGestureKind', $true)
$previewPolicyType = $assembly.GetType('CodexTokenOverlay.OverlayEditPreviewLayoutPolicy', $false)
$eventArgsType = $assembly.GetType('CodexTokenOverlay.OverlayEditPreviewEventArgs', $true)
$contextType = $assembly.GetType('CodexTokenOverlay.OverlayContext', $true)
$moveDispatcherType = $assembly.GetType('CodexTokenOverlay.OverlayEditMoveDispatcher', $false)
$staticFlags = [System.Reflection.BindingFlags]'Public, NonPublic, Static'
$instanceFlags = [System.Reflection.BindingFlags]'Public, NonPublic, Instance'
$moveDispatcherMethod = if ($null -eq $moveDispatcherType) {
    $null
} else {
    $moveDispatcherType.GetMethod('Dispatch', $staticFlags)
}
$jsonOptions = [System.Text.Json.JsonSerializerOptions]::new()
$jsonOptions.PropertyNameCaseInsensitive = $true

function Convert-Model([string]$Json, [Type]$Type) {
    return [System.Text.Json.JsonSerializer]::Deserialize($Json, $Type, $jsonOptions)
}

$opcodeLookup = @{}
foreach ($field in [System.Reflection.Emit.OpCodes].GetFields([System.Reflection.BindingFlags]'Public, Static')) {
    $opcode = $field.GetValue($null)
    $value = [int]$opcode.Value
    if ($value -lt 0) { $value += 65536 }
    $opcodeLookup[$value] = $opcode
}

function Get-MethodInstructions([System.Reflection.MethodInfo]$Method) {
    if ($null -eq $Method -or $null -eq $Method.GetMethodBody()) {
        return
    }

    $bytes = $Method.GetMethodBody().GetILAsByteArray()
    $offset = 0
    while ($offset -lt $bytes.Length) {
        $instructionOffset = $offset
        $first = [int]$bytes[$offset]
        $offset++
        $value = if ($first -eq 0xFE) {
            if ($offset -ge $bytes.Length) { throw "Invalid IL at offset $instructionOffset." }
            $second = [int]$bytes[$offset]
            $offset++
            0xFE00 -bor $second
        } else {
            $first
        }
        $opcode = $opcodeLookup[$value]
        if ($null -eq $opcode) { throw "Unknown IL opcode at offset $instructionOffset." }

        $operandStart = $offset
        $operandLength = switch ($opcode.OperandType.ToString()) {
            'InlineNone' { 0 }
            'ShortInlineBrTarget' { 1 }
            'ShortInlineI' { 1 }
            'ShortInlineVar' { 1 }
            'InlineVar' { 2 }
            'InlineI' { 4 }
            'InlineBrTarget' { 4 }
            'InlineField' { 4 }
            'InlineMethod' { 4 }
            'InlineSig' { 4 }
            'InlineString' { 4 }
            'InlineTok' { 4 }
            'InlineType' { 4 }
            'ShortInlineR' { 4 }
            'InlineI8' { 8 }
            'InlineR' { 8 }
            'InlineSwitch' {
                if ($offset + 4 -gt $bytes.Length) { throw "Invalid switch IL at offset $instructionOffset." }
                4 + (4 * [BitConverter]::ToInt32($bytes, $offset))
            }
            default { throw "Unsupported IL operand $($opcode.OperandType) at offset $instructionOffset." }
        }
        if ($operandStart + $operandLength -gt $bytes.Length) {
            throw "Truncated IL operand at offset $instructionOffset."
        }

        $token = if ($opcode.OperandType.ToString() -eq 'InlineMethod') {
            [BitConverter]::ToInt32($bytes, $operandStart)
        } else {
            $null
        }
        [pscustomobject]@{
            Offset = $instructionOffset
            OpCode = $opcode.Name
            MethodToken = $token
        }
        $offset += $operandLength
    }
}

function Test-MethodCalls([System.Reflection.MethodInfo]$Caller, [System.Reflection.MethodInfo]$Callee) {
    if ($null -eq $Caller -or $null -eq $Callee) {
        return $false
    }

    foreach ($instruction in @(Get-MethodInstructions $Caller)) {
        if ($null -ne $instruction.MethodToken -and $instruction.MethodToken -eq $Callee.MetadataToken) {
            return $true
        }
    }
    return $false
}

function Get-HandlerDispatcherWiring(
    [System.Reflection.MethodInfo]$Handler,
    [System.Reflection.MethodInfo]$Dispatcher,
    [System.Reflection.MethodInfo]$NativeResolver) {
    $wiring = [ordered]@{
        UsesDispatcher = $false
        ResolverCallsNative = $false
        ResolverMethodToken = $null
        IsCompletionFlag = $null
    }
    if ($null -eq $Handler -or $null -eq $Dispatcher -or $null -eq $NativeResolver) {
        return [pscustomobject]$wiring
    }

    $instructions = @(Get-MethodInstructions $Handler)
    $dispatchIndex = -1
    for ($index = 0; $index -lt $instructions.Count; $index++) {
        if ($instructions[$index].MethodToken -eq $Dispatcher.MetadataToken) {
            $dispatchIndex = $index
            break
        }
    }
    if ($dispatchIndex -lt 0) {
        return [pscustomobject]$wiring
    }

    $wiring.UsesDispatcher = $true
    if ($dispatchIndex -gt 0) {
        $wiring.IsCompletionFlag = switch ($instructions[$dispatchIndex - 1].OpCode) {
            'ldc.i4.0' { $false }
            'ldc.i4.1' { $true }
            default { $null }
        }
    }

    for ($index = $dispatchIndex - 1; $index -ge 0; $index--) {
        $instruction = $instructions[$index]
        if ($instruction.OpCode -ne 'ldftn' -or $null -eq $instruction.MethodToken) {
            continue
        }

        $resolverMethod = $Handler.Module.ResolveMethod($instruction.MethodToken)
        if ($resolverMethod -is [System.Reflection.MethodInfo]) {
            $wiring.ResolverMethodToken = $resolverMethod.MetadataToken
            $wiring.ResolverCallsNative = Test-MethodCalls $resolverMethod $NativeResolver
        }
        break
    }
    return [pscustomobject]$wiring
}

$targets = Convert-Model '{"MainHandle":100,"MainBounds":{"X":100,"Y":200,"Width":800,"Height":600},"WorkingArea":{"X":0,"Y":0,"Width":1920,"Height":1080},"Dpi":96}' $targetsType
$mainOriginal = Convert-Model '{"Enabled":true,"MainAttachment":{"ReferencePoint":2,"OffsetXDip":-112,"OffsetYDip":24},"ScalePercent":100}' $snapshotType
$disabledOriginal = Convert-Model '{"Enabled":false,"MainAttachment":{"ReferencePoint":4,"OffsetXDip":-15,"OffsetYDip":7},"ScalePercent":91}' $snapshotType

$saveCoordinator = [System.Activator]::CreateInstance($coordinatorType)
$saveEvents = @(
    $saveCoordinator.BeginEdit($mainOriginal, $targets)
    $saveCoordinator.CompleteMove($targets, [Drawing.Point]::new(850, 750), [Drawing.Point]::new(840, 740), $true)
    $saveCoordinator.PreviewResize($targets, [Drawing.Point]::new(750, 700), 73, [Enum]::ToObject($displayType, 0))
    $saveCoordinator.Commit()
)

$cancelCoordinator = [System.Activator]::CreateInstance($coordinatorType)
$cancelEvents = @(
    $cancelCoordinator.BeginEdit($disabledOriginal, $targets)
    $cancelCoordinator.CompleteMove($targets, [Drawing.Point]::new(750, 350), [Drawing.Point]::new(750, 350), $true)
    $cancelCoordinator.Cancel()
)

$blankCoordinator = [System.Activator]::CreateInstance($coordinatorType)
$blankEvents = @(
    $blankCoordinator.BeginEdit($mainOriginal, $targets)
    $blankCoordinator.CompleteMove($targets, [Drawing.Point]::new(850, 750), [Drawing.Point]::new(840, 740), $true)
    $blankCoordinator.CompleteMove($targets, [Drawing.Point]::new(870, 230), [Drawing.Point]::new(50, 50), $false)
)

$movePreviewCoordinator = [System.Activator]::CreateInstance($coordinatorType)
$null = $movePreviewCoordinator.BeginEdit($mainOriginal, $targets)
$null = $movePreviewCoordinator.CompleteMove($targets, [Drawing.Point]::new(850, 750), [Drawing.Point]::new(840, 740), $true)
$movePreviewCoordinator.BeginGesturePreview()
$validMovePreview = $movePreviewCoordinator.PreviewMove(
    $targets,
    [Drawing.Point]::new(870, 230),
    [Drawing.Point]::new(700, 650),
    $true)
$draftBeforeInvalidPreview = $validMovePreview.Draft | ConvertTo-Json -Compress -Depth 8
$invalidMovePreview = $movePreviewCoordinator.PreviewMove(
    $targets,
    [Drawing.Point]::new(870, 230),
    [Drawing.Point]::new(50, 50),
    $false)
$previewLayoutMethod = if ($null -eq $previewPolicyType) {
    $null
} else {
    $previewPolicyType.GetMethod(
        'ShouldApplyLayout',
        [System.Reflection.BindingFlags]'Public, NonPublic, Static')
}
$validPreviewAppliesLayout = if ($null -eq $previewLayoutMethod) {
    $null
} else {
    [bool]$previewLayoutMethod.Invoke($null, @(
        [Enum]::ToObject($gestureType, 0),
        $validMovePreview))
}
$invalidPreviewAppliesLayout = if ($null -eq $previewLayoutMethod) {
    $null
} else {
    [bool]$previewLayoutMethod.Invoke($null, @(
        [Enum]::ToObject($gestureType, 0),
        $invalidMovePreview))
}

$refreshCoordinator = [System.Activator]::CreateInstance($coordinatorType)
$null = $refreshCoordinator.BeginEdit($mainOriginal, $targets)
$refreshBeforeGesture = @{
    Apply = $refreshCoordinator.ShouldApplyStaticDraft
    Highlight = $refreshCoordinator.ShouldShowStaticHighlight
}
$refreshCoordinator.BeginGesturePreview()
$refreshDuringGesture = @{
    Apply = $refreshCoordinator.ShouldApplyStaticDraft
    Highlight = $refreshCoordinator.ShouldShowStaticHighlight
}
$refreshCoordinator.EndGesturePreview()
$refreshAfterGesture = @{
    Apply = $refreshCoordinator.ShouldApplyStaticDraft
    Highlight = $refreshCoordinator.ShouldShowStaticHighlight
}
$null = $refreshCoordinator.CompleteMove(
    $targets,
    [Drawing.Point]::new(50, 50),
    [Drawing.Point]::new(50, 50),
    $false)
$refreshAfterInvalidMove = @{
    Apply = $refreshCoordinator.ShouldApplyStaticDraft
    Highlight = $refreshCoordinator.ShouldShowStaticHighlight
}

$previewHandler = $contextType.GetMethod('HandleEditPreviewChanged', $instanceFlags)
$completionHandler = $contextType.GetMethod('HandleEditGestureCompleted', $instanceFlags)
$nativeResolverMethod = $contextType.GetMethod('IsCursorOnKnownHost', $instanceFlags)
$previewHandlerWiring = Get-HandlerDispatcherWiring $previewHandler $moveDispatcherMethod $nativeResolverMethod
$completionHandlerWiring = Get-HandlerDispatcherWiring $completionHandler $moveDispatcherMethod $nativeResolverMethod
$previewDispatch = $null
$completionDispatchFalse = $null
$completionDispatchTrue = $null
$falseResolverPoints = [System.Collections.Generic.List[Drawing.Point]]::new()
$trueResolverPoints = [System.Collections.Generic.List[Drawing.Point]]::new()
if ($null -ne $moveDispatcherMethod) {
    $falseResolver = [Func[Drawing.Point,bool]] {
        param([Drawing.Point]$point)
        $falseResolverPoints.Add($point)
        return $false
    }
    $trueResolver = [Func[Drawing.Point,bool]] {
        param([Drawing.Point]$point)
        $trueResolverPoints.Add($point)
        return $true
    }
    $moveEvent = [System.Activator]::CreateInstance($eventArgsType, @(
        [Enum]::ToObject($gestureType, 0),
        [Drawing.Point]::new(150, 250),
        [Drawing.Point]::new(0, 0),
        100))

    $previewDispatchCoordinator = [System.Activator]::CreateInstance($coordinatorType)
    $null = $previewDispatchCoordinator.BeginEdit($mainOriginal, $targets)
    $previewDispatchCoordinator.BeginGesturePreview()
    $previewDispatch = $moveDispatcherMethod.Invoke($null, @(
        $previewDispatchCoordinator,
        $targets,
        $moveEvent,
        [Drawing.Point]::new(160, 260),
        $falseResolver,
        $false))

    $completionFalseCoordinator = [System.Activator]::CreateInstance($coordinatorType)
    $null = $completionFalseCoordinator.BeginEdit($mainOriginal, $targets)
    $completionDispatchFalse = $moveDispatcherMethod.Invoke($null, @(
        $completionFalseCoordinator,
        $targets,
        $moveEvent,
        [Drawing.Point]::new(160, 260),
        $falseResolver,
        $true))

    $completionTrueCoordinator = [System.Activator]::CreateInstance($coordinatorType)
    $null = $completionTrueCoordinator.BeginEdit($mainOriginal, $targets)
    $completionDispatchTrue = $moveDispatcherMethod.Invoke($null, @(
        $completionTrueCoordinator,
        $targets,
        $moveEvent,
        [Drawing.Point]::new(160, 260),
        $trueResolver,
        $true))
}

$result = @{
    SaveMainBottomRightAndResize = $saveEvents
    CancelRestoresDisabledOriginal = $cancelEvents
    BlankMoveKeepsLastValidDraft = $blankEvents
    ValidMovePreview = $validMovePreview
    InvalidMovePreview = $invalidMovePreview
    DraftBeforeInvalidPreview = $draftBeforeInvalidPreview
    GesturePreviewStillActive = $movePreviewCoordinator.IsEditing
    HasPreviewLayoutPolicy = $null -ne $previewLayoutMethod
    ValidPreviewAppliesLayout = $validPreviewAppliesLayout
    InvalidPreviewAppliesLayout = $invalidPreviewAppliesLayout
    RefreshBeforeGesture = $refreshBeforeGesture
    RefreshDuringGesture = $refreshDuringGesture
    RefreshAfterGesture = $refreshAfterGesture
    RefreshAfterInvalidMove = $refreshAfterInvalidMove
    HasMoveDispatcher = $null -ne $moveDispatcherMethod
    PreviewHandlerUsesDispatcher = $previewHandlerWiring.UsesDispatcher
    CompletionHandlerUsesDispatcher = $completionHandlerWiring.UsesDispatcher
    PreviewResolverCallsNative = $previewHandlerWiring.ResolverCallsNative
    CompletionResolverCallsNative = $completionHandlerWiring.ResolverCallsNative
    PreviewResolverMethodToken = $previewHandlerWiring.ResolverMethodToken
    CompletionResolverMethodToken = $completionHandlerWiring.ResolverMethodToken
    PreviewIsCompletionFlag = $previewHandlerWiring.IsCompletionFlag
    CompletionIsCompletionFlag = $completionHandlerWiring.IsCompletionFlag
    PreviewDispatch = $previewDispatch
    CompletionDispatchFalse = $completionDispatchFalse
    CompletionDispatchTrue = $completionDispatchTrue
    FalseResolverCallCount = $falseResolverPoints.Count
    TrueResolverCallCount = $trueResolverPoints.Count
    FalseResolverPoints = $falseResolverPoints
    TrueResolverPoints = $trueResolverPoints
}
[System.IO.File]::WriteAllText(
    $OutputPath,
    ($result | ConvertTo-Json -Depth 12),
    [System.Text.UTF8Encoding]::new($false))
'@
    [System.IO.File]::WriteAllText(
        $probeScriptPath,
        $probeScript,
        [System.Text.UTF8Encoding]::new($false))

    $probeProcess = $null
    try {
        $powershellPath = (Get-Process -Id $PID).Path
        $argumentString = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ApplicationDll "{1}" -OutputPath "{2}"' -f `
            $probeScriptPath.Replace('"', '\"'), `
            $applicationDll.Replace('"', '\"'), `
            $outputPath.Replace('"', '\"')
        $probeProcess = Start-Process `
            -FilePath $powershellPath `
            -ArgumentList $argumentString `
            -WindowStyle Hidden `
            -PassThru
        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            $probeProcess.WaitForExit()
            throw '手动吸附协调器反射探针未在 10 秒内结束。'
        }
        if ($probeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw '手动吸附协调器反射探针执行失败。'
        }
        return Get-Content -LiteralPath $outputPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    finally {
        if ($null -ne $probeProcess) {
            try {
                if (-not $probeProcess.HasExited) {
                    $probeProcess.Kill()
                    $probeProcess.WaitForExit()
                }
            }
            finally {
                $probeProcess.Dispose()
            }
        }
    }
}

function Invoke-AnchorStateReflectionProbe {
    $probeScriptPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-anchor-state-probe.ps1")
    $outputPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-anchor-state-output.json")
    $probeScript = @'
param([string]$ApplicationDll, [string]$OutputPath)
$ErrorActionPreference = 'Stop'
$assembly = [System.Reflection.Assembly]::LoadFrom($ApplicationDll)
$type = $assembly.GetType('CodexTokenOverlay.OverlayAnchorTargetState', $true)
$interactionType = $assembly.GetType('CodexTokenOverlay.OverlayInteractionState', $true)
$referenceType = $assembly.GetType('CodexTokenOverlay.AttachmentReferencePoint', $true)
$method = @($type.GetMethods() | Where-Object {
    $_.Name -eq 'ObserveAndCollapse' -and $_.GetParameters().Count -eq 3
})[0]

function Test-Collapse(
    [long]$FirstHost,
    [int]$FirstReference,
    [long]$SecondHost,
    [int]$SecondReference) {
    if ($null -eq $method) {
        return $false
    }
    $state = [System.Activator]::CreateInstance($type)
    $interaction = [System.Activator]::CreateInstance($interactionType)
    $null = $interaction.OnCapsuleMouseUp()
    $null = $method.Invoke($state, @(
        $FirstHost,
        [Enum]::ToObject($referenceType, $FirstReference),
        $interaction))
    return [bool]$method.Invoke($state, @(
        $SecondHost,
        [Enum]::ToObject($referenceType, $SecondReference),
        $interaction))
}

$result = @{
    HasMainOnlyObserveMethod = $null -ne $method
    BoundsOnlyMovementStaysExpanded = Test-Collapse 100 2 100 2
    HostHandleChangeCollapses = Test-Collapse 100 2 101 2
    ReferencePointChangeCollapses = Test-Collapse 100 2 100 7
}
[System.IO.File]::WriteAllText(
    $OutputPath,
    ($result | ConvertTo-Json -Depth 8),
    [System.Text.UTF8Encoding]::new($false))
'@
    [System.IO.File]::WriteAllText($probeScriptPath, $probeScript, [System.Text.UTF8Encoding]::new($false))
    $probeProcess = $null
    try {
        $powershellPath = (Get-Process -Id $PID).Path
        $argumentString = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ApplicationDll "{1}" -OutputPath "{2}"' -f `
            $probeScriptPath.Replace('"', '\"'), `
            $applicationDll.Replace('"', '\"'), `
            $outputPath.Replace('"', '\"')
        $probeProcess = Start-Process -FilePath $powershellPath -ArgumentList $argumentString -WindowStyle Hidden -PassThru
        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            $probeProcess.WaitForExit()
            throw '锚点身份反射探针未在 10 秒内结束。'
        }
        if ($probeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw '锚点身份反射探针执行失败。'
        }
        return Get-Content -LiteralPath $outputPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    finally {
        if ($null -ne $probeProcess) {
            try {
                if (-not $probeProcess.HasExited) {
                    $probeProcess.Kill()
                    $probeProcess.WaitForExit()
                }
            }
            finally {
                $probeProcess.Dispose()
            }
        }
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    & $DotnetPath build $projectPath -c Release --nologo "-p:TargetFramework=$TargetFramework"
    if ($LASTEXITCODE -ne 0) {
        throw '项目构建失败。'
    }

    if ($areas -contains 'Theme') {
        $assembly = [System.Reflection.Assembly]::LoadFrom($applicationDll)
        $kindType = $assembly.GetType('CodexTokenOverlay.OverlayThemeKind', $false)
        $sourceType = $assembly.GetType('CodexTokenOverlay.WindowsOverlayThemeSource', $false)
        $paletteType = $assembly.GetType('CodexTokenOverlay.OverlayThemePalette', $false)
        Assert-Condition `
            ($null -ne $kindType -and $null -ne $sourceType -and $null -ne $paletteType) `
            '主题枚举、调色板与 Windows 值解析契约必须存在。'

        $staticFlags = [System.Reflection.BindingFlags]'Public, NonPublic, Static'
        $resolveKind = $sourceType.GetMethod('ResolveKind', $staticFlags)
        $readKind = $sourceType.GetMethod('ReadKind', $staticFlags)
        $paletteFor = $paletteType.GetMethod('For', $staticFlags)
        Assert-Condition `
            ($null -ne $resolveKind -and $null -ne $readKind -and $null -ne $paletteFor) `
            '主题纯逻辑入口必须可用。'

        function Invoke-ResolveThemeKind([object]$Value) {
            $arguments = [object[]]::new(1)
            $arguments[0] = $Value
            return $resolveKind.Invoke($null, $arguments).ToString()
        }

        Assert-Condition ((Invoke-ResolveThemeKind 0) -eq 'Dark') 'AppsUseLightTheme=0 必须解析为 Dark。'
        Assert-Condition ((Invoke-ResolveThemeKind 1) -eq 'Light') 'AppsUseLightTheme=1 必须解析为 Light。'
        Assert-Condition ((Invoke-ResolveThemeKind 2) -eq 'Light') '非零 DWORD 必须解析为 Light。'
        Assert-Condition ((Invoke-ResolveThemeKind $null) -eq 'Dark') '缺失注册表值必须回退 Dark。'
        Assert-Condition ((Invoke-ResolveThemeKind '1') -eq 'Dark') '非数值注册表值必须回退 Dark。'

        $throwingRead = [Func[object]] {
            throw [UnauthorizedAccessException]::new('denied')
        }
        $readArguments = [object[]]::new(1)
        $readArguments[0] = $throwingRead
        $fallbackKind = $readKind.Invoke($null, $readArguments).ToString()
        Assert-Condition ($fallbackKind -eq 'Dark') '注册表读取异常必须回退 Dark。'

        $darkKind = [Enum]::Parse($kindType, 'Dark')
        $lightKind = [Enum]::Parse($kindType, 'Light')
        $dark = $paletteFor.Invoke($null, @($darkKind))
        $light = $paletteFor.Invoke($null, @($lightKind))
        $propertyNames = @(
            'Background', 'Label', 'Value', 'Accent', 'Border', 'Divider',
            'ProgressTrack', 'ProgressStart', 'ProgressEnd', 'TargetHighlight')
        $expectedDark = @(
            [Drawing.Color]::FromArgb(36, 38, 45),
            [Drawing.Color]::FromArgb(157, 161, 170),
            [Drawing.Color]::FromArgb(245, 245, 247),
            [Drawing.Color]::FromArgb(185, 174, 255),
            [Drawing.Color]::FromArgb(36, 255, 255, 255),
            [Drawing.Color]::FromArgb(80, 84, 93),
            [Drawing.Color]::FromArgb(70, 74, 83),
            [Drawing.Color]::FromArgb(142, 126, 255),
            [Drawing.Color]::FromArgb(181, 169, 255),
            [Drawing.Color]::FromArgb(142, 126, 255))
        $expectedLight = @(
            [Drawing.Color]::FromArgb(244, 244, 246),
            [Drawing.Color]::FromArgb(92, 96, 105),
            [Drawing.Color]::FromArgb(28, 29, 33),
            [Drawing.Color]::FromArgb(91, 72, 190),
            [Drawing.Color]::FromArgb(32, 0, 0, 0),
            [Drawing.Color]::FromArgb(208, 210, 216),
            [Drawing.Color]::FromArgb(221, 222, 227),
            [Drawing.Color]::FromArgb(111, 91, 218),
            [Drawing.Color]::FromArgb(150, 132, 232),
            [Drawing.Color]::FromArgb(111, 91, 218))
        for ($index = 0; $index -lt $propertyNames.Count; $index++) {
            $property = $propertyNames[$index]
            $darkArgb = $dark.$property.ToArgb()
            $lightArgb = $light.$property.ToArgb()
            Assert-Condition ($darkArgb -eq $expectedDark[$index].ToArgb()) "Dark $property 颜色不正确。actual=$darkArgb"
            Assert-Condition ($lightArgb -eq $expectedLight[$index].ToArgb()) "Light $property 颜色不正确。actual=$lightArgb"
            Assert-Condition ($dark.$property -ne [Drawing.Color]::Fuchsia) "Dark $property 不得使用透明键色。"
            Assert-Condition ($light.$property -ne [Drawing.Color]::Fuchsia) "Light $property 不得使用透明键色。"
        }
        Assert-Condition ($dark.Background -ne $light.Background) '浅深色背景必须不同。'
        Assert-Condition ($dark.Value -ne $light.Value) '浅深色数值颜色必须不同。'

        $sourceContract = $assembly.GetType('CodexTokenOverlay.IOverlayThemeSource', $false)
        $bindingType = $assembly.GetType('CodexTokenOverlay.OverlayThemeBinding', $false)
        Assert-Condition `
            ($null -ne $sourceContract -and $null -ne $bindingType) `
            '主题源与 UI 绑定契约必须存在。'

        $themeResponse = Invoke-JsonProbe '--theme-probe' @()
        $theme = Get-ProbeCase $themeResponse 'theme-lifecycle'
        Assert-Condition $theme.Supported '主题生命周期探针必须运行真实 source/binding。'
        Assert-Condition $theme.SourceInitialDark 'Windows 主题源必须初始应用 Dark。'
        Assert-Condition $theme.SourceChangedOnce '主题类型变化必须恰好通知一次。'
        Assert-Condition $theme.SourceSameKindIgnored '相同主题类型不得重复通知。'
        Assert-Condition $theme.SourceUnsubscribedOnce '释放 Windows 主题源必须恰好解除一次静态订阅。'
        Assert-Condition $theme.SourceDisposeIdempotent '重复释放 Windows 主题源必须幂等。'
        Assert-Condition $theme.SourcePostDisposeIgnored '释放后的 Windows 主题事件必须安全忽略。'
        Assert-Condition $theme.BindingInitialDark '绑定必须在 UI 线程初始应用 Dark。'
        Assert-Condition $theme.BindingBackgroundLightOnUiThread '后台主题更新必须在 UI 线程应用 Light。'
        Assert-Condition $theme.BindingSameKindIgnored '绑定必须合并相同主题的重复事件。'
        Assert-Condition $theme.BindingQueuedCallbackCancelledOnDispose '释放后已排队的 UI 回调必须失效。'
        Assert-Condition $theme.BindingUnsubscribedBeforeSourceDispose '绑定必须先解除事件再释放主题源。'
        Assert-Condition $theme.FormsSupported '两个窗体必须支持 ApplyTheme。'
        Assert-Condition $theme.FormsInitialDark '两个隐藏窗体必须初始应用 Dark。'
        Assert-Condition $theme.FormsBackgroundLightOnUiThread '后台变更必须在 UI 线程向两个窗体应用 Light。'
        Assert-Condition $theme.FormsStateUnchanged '主题变更不得改变边界、布局、展示数据、编辑态或可见性。'
        Assert-Condition $theme.FormsSameKindIgnored '相同主题事件不得产生第二次窗体绘制状态转换。'
        Assert-Condition $theme.FormsSurviveTokenHandleRecreation '编辑态句柄重建前后的后台主题变更必须仍应用。'
        Assert-Condition $theme.FormsPostDisposeIgnored '绑定释放后的主题事件不得改变窗体。'
        Assert-Condition $theme.NoBackgroundException '后台主题事件、句柄竞争和释放不得逃逸异常。'

        $instanceFlags = [System.Reflection.BindingFlags]'Public, NonPublic, Instance'
        $contextType = $assembly.GetType('CodexTokenOverlay.OverlayContext', $true)
        $themeBindingField = $contextType.GetField('_themeBinding', $instanceFlags)
        $contextThemeApply = $contextType.GetMethod('ApplyTheme', $instanceFlags)
        Assert-Condition `
            ($null -ne $themeBindingField -and $themeBindingField.FieldType -eq $bindingType -and $null -ne $contextThemeApply) `
            'OverlayContext 必须持有唯一主题 binding 并提供双窗体应用回调。'

        $formApplyTheme = $assembly.GetType('CodexTokenOverlay.TokenStripForm', $true).GetMethod('ApplyTheme', $instanceFlags)
        $highlightApplyTheme = $assembly.GetType('CodexTokenOverlay.AttachmentTargetHighlightForm', $true).GetMethod('ApplyTheme', $instanceFlags)
        Assert-Condition `
            (Test-MethodCallChain $contextThemeApply @($formApplyTheme, $highlightApplyTheme) 6) `
            'OverlayContext 主题回调必须向主窗体和高亮窗体应用同一调色板。'

        $contextConstructor = @($contextType.GetConstructors($instanceFlags) | Where-Object {
            $_.GetParameters().Count -eq 2
        })[0]
        $constructorCalls = @(
            foreach ($token in @(Get-MethodCallTokens $contextConstructor)) {
                $contextConstructor.Module.ResolveMethod($token)
            })
        $handleGetterIndex = -1
        $bindingConstructorIndex = -1
        for ($index = 0; $index -lt $constructorCalls.Count; $index++) {
            $call = $constructorCalls[$index]
            if ($call.DeclaringType.FullName -eq 'System.Windows.Forms.Control' -and $call.Name -eq 'get_Handle') {
                $handleGetterIndex = $index
            }
            if ($call.DeclaringType -eq $bindingType -and $call.Name -eq '.ctor') {
                $bindingConstructorIndex = $index
                break
            }
        }
        Assert-Condition `
            ($handleGetterIndex -ge 0 -and $bindingConstructorIndex -gt $handleGetterIndex) `
            'OverlayContext 必须先创建稳定高亮 dispatcher 句柄，再构造主题 binding。'

        $contextDispose = $contextType.GetMethod('DisposeThemeAndForms', $instanceFlags)
        $disposeCalls = @(
            foreach ($token in @(Get-MethodCallTokens $contextDispose)) {
                $contextDispose.Module.ResolveMethod($token)
            })
        $themeDisposeIndex = -1
        $formDisposeIndexes = @()
        for ($index = 0; $index -lt $disposeCalls.Count; $index++) {
            $call = $disposeCalls[$index]
            if ($call.DeclaringType -eq $bindingType -and $call.Name -eq 'Dispose') { $themeDisposeIndex = $index }
            if ($call.DeclaringType.FullName -eq 'System.ComponentModel.Component' -and $call.Name -eq 'Dispose') {
                $formDisposeIndexes += $index
            }
        }
        Assert-Condition `
            ($themeDisposeIndex -ge 0 -and $formDisposeIndexes.Count -eq 2 -and @($formDisposeIndexes | Where-Object { $_ -gt $themeDisposeIndex }).Count -eq 2) `
            'OverlayContext 必须在两个窗体之前释放主题 binding。'
    }

    if ($areas -contains 'Attachment') {
        $target = @{ X = 100; Y = 200; Width = 800; Height = 600 }
        $mainBounds = @{ X = 100; Y = 200; Width = 800; Height = 600 }
        $workingArea = @{ X = 0; Y = 0; Width = 1920; Height = 1080 }
        $assembly = [System.Reflection.Assembly]::LoadFrom($applicationDll)
        foreach ($contractName in @(
            'CodexTokenOverlay.ManualPlacementSnapshot',
            'CodexTokenOverlay.AttachmentTargetBounds',
            'CodexTokenOverlay.AttachmentTargetHit')) {
            $contract = $assembly.GetType($contractName, $true)
            foreach ($propertyName in @(
                'AttachmentTargetKind', 'ActiveTarget')) {
                Assert-Condition ($null -eq $contract.GetProperty($propertyName)) `
                    "$contractName 不得公开 $propertyName。"
            }
        }
        Assert-Condition ($null -eq $assembly.GetType('CodexTokenOverlay.AttachmentTargetKind', $false)) `
            '主窗口契约不得保留 AttachmentTargetKind 类型。'
        $response = Invoke-JsonProbe '--attachment-probe' @(
            @{ Name = 'reference-points'; Operation = 'ReferencePoints'; Target = $target; Dpi = 96 },
            @{ Name = 'center-tie'; Operation = 'SelectReferencePoint'; Target = $target; Center = @{ X = 500; Y = 500 } },
            @{ Name = 'near-top-right'; Operation = 'SelectReferencePoint'; Target = $target; Center = @{ X = 870; Y = 230 } },
            @{ Name = 'dpi-capture-roundtrip'; Operation = 'CaptureResolve'; Target = $target; Center = @{ X = 855; Y = 245 }; Dpi = 144 },
            @{
                Name = 'target-hit-testing'
                Operation = 'SelectTargets'
                Targets = @{
                    MainHandle = 100
                    MainBounds = $mainBounds
                    WorkingArea = $workingArea
                    Dpi = 96
                }
                Points = @(
                    @{ X = 870; Y = 230 },
                    @{ X = 870; Y = 230 },
                    @{ X = 50; Y = 50 }
                )
                HostSurfaceHits = @($true, $false, $false)
            },
            @{
                Name = 'scale-calculation'
                Operation = 'CalculateScales'
                Cases = @(
                    @{ StartWidth = 196; StartHeight = 34; StartScale = 100; DeltaX = -80; DeltaY = -20 },
                    @{ StartWidth = 196; StartHeight = 34; StartScale = 100; DeltaX = 59; DeltaY = 10 },
                    @{ StartWidth = 0; StartHeight = 34; StartScale = 73; DeltaX = 20; DeltaY = 20 },
                    @{ StartWidth = 196; StartHeight = -1; StartScale = 999; DeltaX = 20; DeltaY = 20 }
                )
            },
            @{
                Name = 'edit-state'
                Operation = 'EditState'
                CommitOriginal = @{
                    Enabled = $true
                    MainAttachment = @{ ReferencePoint = 2; OffsetXDip = -112; OffsetYDip = 24 }
                    ScalePercent = 100
                }
                CommitAttachment = @{ ReferencePoint = 2; OffsetXDip = -30; OffsetYDip = 40 }
                CommitScale = 73
                CancelOriginal = @{
                    Enabled = $false
                    MainAttachment = @{ ReferencePoint = 4; OffsetXDip = -15; OffsetYDip = 7 }
                    ScalePercent = 91
                }
                CancelAttachment = @{ ReferencePoint = 0; OffsetXDip = 10; OffsetYDip = 20 }
                CancelScale = 120
            }
        )

        $referencePoints = @(Get-ProbeCase $response 'reference-points').Points
        $expectedReferencePoints = @(
            @{ Kind = 0; X = 100; Y = 200 },
            @{ Kind = 1; X = 500; Y = 200 },
            @{ Kind = 2; X = 900; Y = 200 },
            @{ Kind = 3; X = 100; Y = 500 },
            @{ Kind = 4; X = 900; Y = 500 },
            @{ Kind = 5; X = 100; Y = 800 },
            @{ Kind = 6; X = 500; Y = 800 },
            @{ Kind = 7; X = 900; Y = 800 }
        )
        Assert-Condition ($referencePoints.Count -eq $expectedReferencePoints.Count) '手动吸附必须暴露恰好八个参考点。'
        for ($index = 0; $index -lt $expectedReferencePoints.Count; $index++) {
            $actual = $referencePoints[$index]
            $expected = $expectedReferencePoints[$index]
            Assert-Condition `
                ($actual.Kind -eq $expected.Kind -and $actual.Point.X -eq $expected.X -and $actual.Point.Y -eq $expected.Y) `
                "第 $index 个手动吸附参考点不正确。"
        }
        $referenceCase = Get-ProbeCase $response 'reference-points'
        Assert-Condition $referenceCase.RejectsEmptyTarget '纯吸附 API 必须拒绝空目标矩形。'
        Assert-Condition $referenceCase.RejectsZeroDpi '纯吸附 API 必须拒绝零 DPI。'

        Assert-Condition ((Get-ProbeCase $response 'center-tie').ReferencePoint -eq 1) '中心并列必须按枚举顺序选择 TopCenter。'
        Assert-Condition ((Get-ProbeCase $response 'near-top-right').ReferencePoint -eq 2) '右上附近必须选择 TopRight。'

        $roundtrip = Get-ProbeCase $response 'dpi-capture-roundtrip'
        Assert-Condition ($roundtrip.Attachment.ReferencePoint -eq 2) '144 DPI 捕获必须选择 TopRight。'
        Assert-Condition ([Math]::Abs($roundtrip.Attachment.OffsetXDip - (-30)) -lt 0.000001) '144 DPI 捕获 X 偏移必须为 -30 DIP。'
        Assert-Condition ([Math]::Abs($roundtrip.Attachment.OffsetYDip - 30) -lt 0.000001) '144 DPI 捕获 Y 偏移必须为 30 DIP。'
        Assert-Condition ($roundtrip.ResolvedCenter.X -eq 855 -and $roundtrip.ResolvedCenter.Y -eq 245) '144 DPI 捕获必须无损解析回原中心。'

        $hits = @(Get-ProbeCase $response 'target-hit-testing').Hits
        Assert-Condition ($hits.Count -eq 3) '目标命中探针必须返回三个结果。'
        Assert-Condition ($hits[0].Handle -eq 100 -and $hits[0].Bounds.X -eq 100 -and $hits[0].Bounds.Y -eq 200) '主窗口表面命中必须捕获主窗口。'
        Assert-Condition ($null -eq $hits[1]) 'hostSurfaceHit=false 时即使在主窗口矩形内也不得捕获。'
        Assert-Condition ($null -eq $hits[2]) '无关位置不得命中任意吸附目标。'

        $scales = @(Get-ProbeCase $response 'scale-calculation').Scales
        Assert-Condition (($scales -join ',') -eq '60,130,73,130') '缩放计算必须按 60–130 边界并在无效起始尺寸时返回清理后的起始比例。'

        $edit = Get-ProbeCase $response 'edit-state'
        Assert-Condition $edit.ThrowsBeforeBegin '编辑状态在 Begin 前必须拒绝 Apply/Commit/Cancel。'
        Assert-Condition (-not $edit.ActiveAfterCommit) 'Commit 后编辑状态必须失活。'
        Assert-Condition ($edit.Committed.Enabled -and $edit.Committed.ScalePercent -eq 73) 'Commit 必须返回当前草稿缩放。'
        Assert-Condition ($edit.Committed.MainAttachment.ReferencePoint -eq 2 -and $edit.Committed.MainAttachment.OffsetXDip -eq -30 -and $edit.Committed.MainAttachment.OffsetYDip -eq 40) 'Commit 必须返回主窗口草稿附件。'
        Assert-Condition (-not $edit.ActiveAfterCancel) 'Cancel 后编辑状态必须失活。'
        $cancelledJson = $edit.Cancelled | ConvertTo-Json -Compress -Depth 8
        $cancelOriginalJson = $edit.CancelOriginal | ConvertTo-Json -Compress -Depth 8
        Assert-Condition ($cancelledJson -eq $cancelOriginalJson) 'Cancel 必须完整恢复不可变的原始快照。'

        $coordinator = Invoke-ManualCoordinatorReflectionProbe

        $dispatcherBehaviorIsNativeSeamDriven = `
            ($coordinator.FalseResolverCallCount -eq 2) -and `
            ($coordinator.TrueResolverCallCount -eq 1) -and `
            (-not $coordinator.PreviewDispatch.CanSave) -and `
            ($null -eq $coordinator.PreviewDispatch.HighlightBounds) -and `
            (-not $coordinator.CompletionDispatchFalse.CanSave) -and `
            ($null -eq $coordinator.CompletionDispatchFalse.HighlightBounds) -and `
            $coordinator.CompletionDispatchTrue.CanSave -and `
            ($null -ne $coordinator.CompletionDispatchTrue.HighlightBounds) -and `
            ($coordinator.FalseResolverPoints[0].X -eq 150) -and `
            ($coordinator.FalseResolverPoints[0].Y -eq 250) -and `
            ($coordinator.TrueResolverPoints[0].X -eq 150) -and `
            ($coordinator.TrueResolverPoints[0].Y -eq 250)
        Assert-Condition `
            ($coordinator.HasMoveDispatcher -and $coordinator.PreviewHandlerUsesDispatcher -and $coordinator.CompletionHandlerUsesDispatcher -and $dispatcherBehaviorIsNativeSeamDriven) `
            "Context 的 preview/completion handler 必须共同调用可注入 surface resolver 的 production dispatcher，并逐字传递 false/true。actual=$($coordinator | ConvertTo-Json -Compress -Depth 12)"
        Assert-Condition `
            ($coordinator.PreviewResolverCallsNative -and $coordinator.CompletionResolverCallsNative -and ($coordinator.PreviewIsCompletionFlag -eq $false) -and ($coordinator.CompletionIsCompletionFlag -eq $true)) `
            "两个 concrete handler 创建的 delegate 必须分别调用 native IsCursorOnKnownHost，且 dispatcher 调用前必须装载 preview=false/completion=true。actual=$($coordinator | ConvertTo-Json -Compress -Depth 12)"

        $saveEvents = @($coordinator.SaveMainBottomRightAndResize)
        $saved = $saveEvents[3]
        Assert-Condition (-not $saved.IsEditing) '保存后协调器必须退出编辑态。'
        Assert-Condition ($saved.Draft.Enabled -and $saved.Draft.ScalePercent -eq 73) '保存必须启用手动主窗口目标并保留 73% 缩放。'
        Assert-Condition ($saved.Draft.MainAttachment.ReferencePoint -eq 7) '右下移动和缩放后必须保存 BottomRight 参考点。'
        $resize = $saveEvents[2]
        Assert-Condition $resize.ShouldCollapse '进入缩放预览必须请求保持收起。'
        Assert-Condition ($resize.ResolvedCenter.X -eq 821 -and $resize.ResolvedCenter.Y -eq 712) '73% 缩放必须由固定左上角推导新胶囊中心。'

        $cancelEvents = @($coordinator.CancelRestoresDisabledOriginal)
        $cancelled = $cancelEvents[2].Draft
        Assert-Condition (-not $cancelEvents[2].IsEditing -and -not $cancelled.Enabled) '取消必须退出编辑并恢复原始禁用标志。'
        Assert-Condition ($cancelled.ScalePercent -eq 91) '取消必须恢复原始缩放。'
        Assert-Condition ($cancelled.MainAttachment.ReferencePoint -eq 4 -and $cancelled.MainAttachment.OffsetXDip -eq -15 -and $cancelled.MainAttachment.OffsetYDip -eq 7) '取消必须完整恢复主窗口附件。'

        $blankEvents = @($coordinator.BlankMoveKeepsLastValidDraft)
        Assert-Condition (-not $blankEvents[2].CanSave) '无关空白位置必须让当前手势不可保存。'
        Assert-Condition (($blankEvents[1].Draft | ConvertTo-Json -Compress -Depth 8) -eq ($blankEvents[2].Draft | ConvertTo-Json -Compress -Depth 8)) '无关空白位置不得覆盖最后一个有效草稿。'
        Assert-Condition ($blankEvents[2].ResolvedCenter.X -eq 840 -and $blankEvents[2].ResolvedCenter.Y -eq 740) '无效 Move 完成必须立即返回最后有效草稿中心，而不是保留桌面自由拖动位置。'

        $validMovePreview = $coordinator.ValidMovePreview
        Assert-Condition ($validMovePreview.CanSave -and $validMovePreview.ResolvedCenter.X -eq 700 -and $validMovePreview.ResolvedCenter.Y -eq 650) '有效 Move 预览必须继续使用自由拖拽中心。'
        Assert-Rect $validMovePreview.HighlightBounds 100 200 800 600 '有效 Move 预览必须显示主窗口目标 ring。'
        $invalidMovePreview = $coordinator.InvalidMovePreview
        Assert-Condition $invalidMovePreview.IsEditing '无效 Move 预览不得结束手势编辑态。'
        Assert-Condition (-not $invalidMovePreview.CanSave) 'hostSurfaceHit=false 的 Move 预览必须立即不可保存。'
        Assert-Condition ($null -eq $invalidMovePreview.HighlightBounds) 'hostSurfaceHit=false 的 Move 预览不得保留目标 ring。'
        Assert-Condition (($invalidMovePreview.Draft | ConvertTo-Json -Compress -Depth 8) -eq $coordinator.DraftBeforeInvalidPreview) '无效 Move 预览不得覆盖最后有效草稿。'
        Assert-Condition ($invalidMovePreview.ResolvedCenter.X -eq 840 -and $invalidMovePreview.ResolvedCenter.Y -eq 740) '无效 Move 预览必须同步返回最后有效草稿中心。'
        Assert-Condition $coordinator.GesturePreviewStillActive '无效 Move 预览不得结束活动 gesture preview。'
        Assert-Condition $coordinator.HasPreviewLayoutPolicy 'Context 必须暴露可观察的 move preview 布局决策 seam。'
        Assert-Condition (-not $coordinator.ValidPreviewAppliesLayout) '有效 Move 预览必须保持自由跟手且不得应用布局。'
        Assert-Condition $coordinator.InvalidPreviewAppliesLayout '无效 Move 预览必须在同一事件应用最后有效布局。'

        Assert-Condition ($coordinator.RefreshBeforeGesture.Apply -and $coordinator.RefreshBeforeGesture.Highlight) '静态编辑草稿初始必须允许 Tick 跟随并显示有效目标 ring。'
        Assert-Condition (-not $coordinator.RefreshDuringGesture.Apply -and -not $coordinator.RefreshDuringGesture.Highlight) '活动 move/resize preview 期间 Tick 不得覆盖预览或恢复 ring。'
        Assert-Condition ($coordinator.RefreshAfterGesture.Apply -and $coordinator.RefreshAfterGesture.Highlight) '手势完成后有效草稿必须恢复静态窗口跟随。'
        Assert-Condition ($coordinator.RefreshAfterInvalidMove.Apply -and -not $coordinator.RefreshAfterInvalidMove.Highlight) 'CanSave=false 时 Tick 可恢复草稿位置但不得恢复目标 ring。'
    }

    if ($areas -contains 'Settings') {
        $missingSettingsPath = Join-Path $testRoot 'missing\settings.json'
        $emptySettingsPath = Join-Path $testRoot 'empty\settings.json'
        $migratedSettingsPath = Join-Path $testRoot 'migrated\settings.json'
        $manualPlacementSettingsPath = Join-Path $testRoot 'manual-placement\settings.json'
        $response = Invoke-JsonProbe '--settings-probe' @(
            @{
                Name = 'migrate-real-old-settings'
                Operation = 'Parse'
                Json = '{"AnchorMode":2,"VisibleFields":511}'
            },
            @{
                Name = 'keep-current-old-anchor'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"AnchorMode":2,"VisibleFields":511,"CollapsedPrimaryField":1,"CollapsedSecondaryField":64}'
            },
            @{
                Name = 'existing-version-one-keeps-traditional-mode'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"AnchorMode":2,"VisibleFields":127,"CollapsedPrimaryField":1,"CollapsedSecondaryField":64}'
            },
            @{
                Name = 'swap-duplicate-slot'
                Operation = 'Select'
                Json = '{"SettingsVersion":1,"AnchorMode":3,"VisibleFields":511,"CollapsedPrimaryField":1,"CollapsedSecondaryField":64}'
                Slot = 'Primary'
                Field = 64
            },
            @{
                Name = 'repair-unknown-values'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"AnchorMode":99,"VisibleFields":1073741824,"CollapsedPrimaryField":3,"CollapsedSecondaryField":3}'
            },
            @{
                Name = 'missing-settings-file'
                Operation = 'Load'
                SettingsPath = $missingSettingsPath
            },
            @{
                Name = 'empty-settings-file'
                Operation = 'Load'
                Json = ''
                SettingsPath = $emptySettingsPath
            },
            @{
                Name = 'load-legacy-settings-and-persist'
                Operation = 'Load'
                Json = '{"AnchorMode":2,"VisibleFields":511}'
                SettingsPath = $migratedSettingsPath
            },
            @{
                Name = 'reload-migrated-settings'
                Operation = 'Load'
                SettingsPath = $migratedSettingsPath
            },
            @{
                Name = 'visible-none-becomes-total'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"VisibleFields":0}'
            },
            @{
                Name = 'visible-known-bits-survive'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"VisibleFields":1073741952}'
            },
            @{
                Name = 'existing-visible-fields-preserved'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"VisibleFields":127}'
            },
            @{
                Name = 'duplicate-valid-slots-remain-distinct'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"CollapsedPrimaryField":64,"CollapsedSecondaryField":64}'
            },
            @{
                Name = 'save-reload-isolated-settings'
                Operation = 'SaveReload'
                Json = '{"SettingsVersion":1,"AnchorMode":2,"VisibleFields":511,"CollapsedPrimaryField":64,"CollapsedSecondaryField":1}'
                SettingsPath = $migratedSettingsPath
            },
            @{
                Name = 'manual-placement-roundtrip'
                Operation = 'SaveReload'
                SettingsPath = $manualPlacementSettingsPath
                Json = '{"SettingsVersion":1,"AnchorMode":2,"VisibleFields":127,"CollapsedPrimaryField":1,"CollapsedSecondaryField":64,"ManualPlacementEnabled":true,"MainAttachment":{"ReferencePoint":2,"OffsetXDip":-112.5,"OffsetYDip":24.25},"OverlayScalePercent":73}'
            },
            @{
                Name = 'invalid-manual-placement-sanitized'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"ManualPlacementEnabled":true,"MainAttachment":{"ReferencePoint":99,"OffsetXDip":1e99,"OffsetYDip":-1e99},"OverlayScalePercent":999}'
            },
            @{
                Name = 'empty-main-attachment-sanitized'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"ManualPlacementEnabled":true,"MainAttachment":{}}'
            },
            @{
                Name = 'incomplete-main-missing-reference-point'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"ManualPlacementEnabled":true,"MainAttachment":{"OffsetXDip":3.5,"OffsetYDip":22.75}}'
            },
            @{
                Name = 'incomplete-main-missing-offset-x'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"ManualPlacementEnabled":true,"MainAttachment":{"ReferencePoint":6,"OffsetYDip":22.75}}'
            },
            @{
                Name = 'incomplete-main-missing-offset-y'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"ManualPlacementEnabled":true,"MainAttachment":{"ReferencePoint":6,"OffsetXDip":3.5}}'
            },
            @{
                Name = 'invalid-json-defaults'
                Operation = 'Parse'
                Json = '{not json}'
            }
        )

        $migrated = Get-ProbeCase $response 'migrate-real-old-settings'
        Assert-Condition ($migrated.Settings.SettingsVersion -eq 1) '旧设置未迁移到版本 1。'
        Assert-Condition ($migrated.Settings.AnchorMode -eq 3) '旧设置迁移后未切换到标题栏右上。'
        Assert-Condition ($migrated.Settings.VisibleFields -eq 511) '旧设置迁移后未保留可见字段。'
        Assert-Condition ($migrated.Settings.CollapsedPrimaryField -eq 1) '旧设置迁移后左侧指标不正确。'
        Assert-Condition ($migrated.Settings.CollapsedSecondaryField -eq 64) '旧设置迁移后右侧指标不正确。'
        Assert-Condition ($migrated.MustPersist -eq $true) '旧设置迁移后必须立即持久化。'

        $currentOldAnchor = Get-ProbeCase $response 'keep-current-old-anchor'
        Assert-Condition ($currentOldAnchor.Settings.AnchorMode -eq 2) '当前版本错误地覆盖了用户选择的旧吸附模式。'
        Assert-Condition ($currentOldAnchor.MustPersist -eq $false) '当前版本设置不应触发迁移写入。'

        $traditionalMode = Get-ProbeCase $response 'existing-version-one-keeps-traditional-mode'
        Assert-Condition ($traditionalMode.Settings.AnchorMode -eq 2) '版本 1 设置错误地覆盖了传统吸附模式。'
        Assert-Condition ($traditionalMode.Settings.ManualPlacementEnabled -eq $false) '缺少手动放置字段的版本 1 设置必须保持传统模式。'
        Assert-Condition ($traditionalMode.Settings.MainAttachment.ReferencePoint -eq 2) '缺少手动放置字段的版本 1 设置必须默认主窗口右上参考点。'
        Assert-Condition ($traditionalMode.Settings.MainAttachment.OffsetXDip -eq -344) '缺少手动放置字段的版本 1 设置必须默认主窗口安全水平偏移。'
        Assert-Condition ($traditionalMode.Settings.MainAttachment.OffsetYDip -eq 24) '缺少手动放置字段的版本 1 设置必须默认主窗口垂直偏移。'
        Assert-Condition ($traditionalMode.Settings.OverlayScalePercent -eq 100) '缺少手动放置字段的版本 1 设置必须默认 100% 缩放。'

        $swapped = Get-ProbeCase $response 'swap-duplicate-slot'
        Assert-Condition ($swapped.Settings.CollapsedPrimaryField -eq 64) '选择右侧指标为左侧指标时未更新左侧。'
        Assert-Condition ($swapped.Settings.CollapsedSecondaryField -eq 1) '重复选择时未交换原左侧指标。'

        $repaired = Get-ProbeCase $response 'repair-unknown-values'
        Assert-Condition ($repaired.Settings.AnchorMode -eq 3) '未知吸附模式未回退到标题栏右上。'
        Assert-Condition ($repaired.Settings.VisibleFields -eq 1) '全未知可见字段未回退到总 Token。'
        Assert-Condition ($repaired.Settings.CollapsedPrimaryField -eq 1) '无效左侧指标未回退到总 Token。'
        Assert-Condition ($repaired.Settings.CollapsedSecondaryField -eq 64) '无效右侧指标未回退到上下文百分比。'

        $missing = Get-ProbeCase $response 'missing-settings-file'
        Assert-Condition ($missing.Settings.SettingsVersion -eq 1) '缺少设置文件时未使用当前版本默认值。'
        Assert-Condition ($missing.Settings.AnchorMode -eq 3) '缺少设置文件时默认吸附模式不正确。'
        Assert-Condition ($missing.Settings.CollapsedPrimaryField -eq 1) '缺少设置文件时默认左侧指标不正确。'
        Assert-Condition ($missing.Settings.CollapsedSecondaryField -eq 64) '缺少设置文件时默认右侧指标不正确。'
        Assert-Condition ($missing.Settings.ManualPlacementEnabled -eq $true) '缺少设置文件时必须启用默认手动放置。'
        Assert-Condition ($missing.Settings.MainAttachment.ReferencePoint -eq 2) '缺少设置文件时默认主窗口参考点不正确。'
        Assert-Condition ($missing.Settings.MainAttachment.OffsetXDip -eq -344 -and $missing.Settings.MainAttachment.OffsetYDip -eq 24) '缺少设置文件时默认主窗口偏移不正确。'
        $defaultWindowRight = 900
        $defaultCaptionButtonLeft = 730
        $defaultCaptionSafetyGap = 8
        $defaultManualCapsuleWidth = 196
        $defaultManualCapsuleRight = $defaultWindowRight +
            [int]$missing.Settings.MainAttachment.OffsetXDip +
            $defaultManualCapsuleWidth -
            [int]($defaultManualCapsuleWidth / 2)
        Assert-Condition ($defaultManualCapsuleRight -le ($defaultCaptionButtonLeft - $defaultCaptionSafetyGap)) `
            "默认手动右上位置覆盖标题栏按钮：capsuleRight=$defaultManualCapsuleRight safeRight=$($defaultCaptionButtonLeft - $defaultCaptionSafetyGap)。"
        $maximumManualCapsuleWidth = 255
        $maximumManualCapsuleRight = $defaultWindowRight +
            [int]$missing.Settings.MainAttachment.OffsetXDip +
            $maximumManualCapsuleWidth -
            [int]($defaultManualCapsuleWidth / 2)
        Assert-Condition ($maximumManualCapsuleRight -le ($defaultCaptionButtonLeft - $defaultCaptionSafetyGap)) `
            "默认手动右上位置在 130% 缩放时覆盖标题栏按钮：capsuleRight=$maximumManualCapsuleRight safeRight=$($defaultCaptionButtonLeft - $defaultCaptionSafetyGap)。"
        Assert-Condition ($missing.Settings.OverlayScalePercent -eq 100) '缺少设置文件时默认缩放不正确。'
        Assert-Condition (-not (Test-Path -LiteralPath $missingSettingsPath)) '缺少设置文件不应触发写入。'

        $empty = Get-ProbeCase $response 'empty-settings-file'
        Assert-Condition ($empty.Settings.ManualPlacementEnabled -eq $true) '空设置文件时必须使用默认手动放置。'
        Assert-Condition ($empty.Settings.MainAttachment.ReferencePoint -eq 2) '空设置文件时默认主窗口参考点不正确。'
        Assert-Condition ($empty.Settings.MainAttachment.OffsetXDip -eq -344 -and $empty.Settings.MainAttachment.OffsetYDip -eq 24) '空设置文件时默认主窗口偏移不正确。'
        Assert-Condition ($empty.Settings.OverlayScalePercent -eq 100) '空设置文件时默认缩放不正确。'

        $loadedLegacy = Get-ProbeCase $response 'load-legacy-settings-and-persist'
        Assert-Condition ($loadedLegacy.Settings.AnchorMode -eq 3) '旧设置文件加载后未迁移到标题栏右上。'
        Assert-Condition ($loadedLegacy.MustPersist -eq $true) '旧设置文件首次加载后必须立即迁移。'
        Assert-Condition ($loadedLegacy.Settings.ManualPlacementEnabled -eq $false) '旧版无版本设置加载迁移时必须保持传统模式。'
        Assert-Condition (Test-Path -LiteralPath $migratedSettingsPath -PathType Leaf) '旧设置文件迁移后未立即保存。'

        $reloadedMigration = Get-ProbeCase $response 'reload-migrated-settings'
        Assert-Condition ($reloadedMigration.Settings.AnchorMode -eq 3) '已迁移设置重载后被错误覆盖。'
        Assert-Condition ($reloadedMigration.MustPersist -eq $false) '已迁移设置重载时不应再次迁移。'
        Assert-Condition ($reloadedMigration.Settings.ManualPlacementEnabled -eq $false) '旧版无版本设置写回并重载后必须保持传统模式。'

        $visibleNone = Get-ProbeCase $response 'visible-none-becomes-total'
        Assert-Condition ($visibleNone.Settings.VisibleFields -eq 1) 'VisibleFields=None 未回退到总 Token。'

        $knownBits = Get-ProbeCase $response 'visible-known-bits-survive'
        Assert-Condition ($knownBits.Settings.VisibleFields -eq 128) '可见字段未去除未知位或未保留已知位。'

        $cacheHitRate = 512
        Assert-Condition (($missing.Settings.VisibleFields -band $cacheHitRate) -ne 0) `
            '新设置默认必须显示缓存命中率。'

        $existing = Get-ProbeCase $response 'existing-visible-fields-preserved'
        Assert-Condition ($existing.Settings.VisibleFields -eq 127) `
            '已有 VisibleFields 不得自动加入缓存命中率。'

        $duplicateSlots = Get-ProbeCase $response 'duplicate-valid-slots-remain-distinct'
        Assert-Condition ($duplicateSlots.Settings.CollapsedPrimaryField -eq 64) '有效重复指标错误地改写了左侧选择。'
        Assert-Condition ($duplicateSlots.Settings.CollapsedSecondaryField -eq 1) '有效重复指标未回退到与左侧不同的安全值。'

        $saveReload = Get-ProbeCase $response 'save-reload-isolated-settings'
        Assert-Condition ($saveReload.Settings.SettingsVersion -eq 1) '保存重载后设置版本不正确。'
        Assert-Condition ($saveReload.Settings.AnchorMode -eq 2) '保存重载后用户切换的吸附模式未保留。'
        Assert-Condition ($saveReload.Settings.VisibleFields -eq 511) '保存重载后可见字段未保留。'
        Assert-Condition ($saveReload.Settings.CollapsedPrimaryField -eq 64) '保存重载后左侧指标未保留。'
        Assert-Condition ($saveReload.Settings.CollapsedSecondaryField -eq 1) '保存重载后右侧指标未保留。'
        Assert-Condition ($saveReload.MustPersist -eq $false) '已保存的当前版本设置不应再次迁移。'
        Assert-Condition (Test-Path -LiteralPath $migratedSettingsPath -PathType Leaf) '保存重载未写入指定的临时设置路径。'

        $manualPlacement = Get-ProbeCase $response 'manual-placement-roundtrip'
        Assert-Condition ($manualPlacement.Settings.ManualPlacementEnabled -eq $true) '保存重载后手动放置开关未保留。'
        Assert-Condition ($manualPlacement.Settings.MainAttachment.ReferencePoint -eq 2) '保存重载后主窗口参考点未保留。'
        Assert-Condition ($manualPlacement.Settings.MainAttachment.OffsetXDip -eq -112.5 -and $manualPlacement.Settings.MainAttachment.OffsetYDip -eq 24.25) '保存重载后主窗口小数偏移未保留。'
        Assert-Condition ($manualPlacement.Settings.OverlayScalePercent -eq 73) '保存重载后缩放未保留。'
        Assert-Condition (Test-Path -LiteralPath $manualPlacementSettingsPath -PathType Leaf) '手动放置未写入指定的临时设置路径。'
        Assert-Condition ($manualPlacementSettingsPath.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase)) '手动放置设置路径必须位于测试临时根目录。'
        $manualPlacementSavedJson = Get-Content -LiteralPath $manualPlacementSettingsPath -Encoding UTF8 -Raw | ConvertFrom-Json
        Assert-Condition ($manualPlacementSavedJson.MainAttachment.ReferencePoint -eq 2) '保存 JSON 未写入主窗口参考点。'
        Assert-Condition ($manualPlacementSavedJson.MainAttachment.OffsetXDip -eq -112.5 -and $manualPlacementSavedJson.MainAttachment.OffsetYDip -eq 24.25) '保存 JSON 未写入主窗口小数偏移。'

        $invalidManualPlacement = Get-ProbeCase $response 'invalid-manual-placement-sanitized'
        Assert-Condition ($invalidManualPlacement.Settings.ManualPlacementEnabled -eq $true) '无效手动放置不应关闭已启用的手动模式。'
        Assert-Condition ($invalidManualPlacement.Settings.MainAttachment.ReferencePoint -eq 2) '无效主窗口放置必须回退到默认参考点。'
        Assert-Condition ($invalidManualPlacement.Settings.MainAttachment.OffsetXDip -eq -344 -and $invalidManualPlacement.Settings.MainAttachment.OffsetYDip -eq 24) '无效主窗口放置必须回退到默认偏移。'
        Assert-Condition ($invalidManualPlacement.Settings.OverlayScalePercent -eq 130) '超出范围的手动缩放必须钳制到 130%。'

        $emptyAttachments = Get-ProbeCase $response 'empty-main-attachment-sanitized'
        Assert-Condition ($emptyAttachments.Settings.MainAttachment.ReferencePoint -eq 2) '空主窗口放置对象必须回退到默认参考点。'
        Assert-Condition ($emptyAttachments.Settings.MainAttachment.OffsetXDip -eq -344 -and $emptyAttachments.Settings.MainAttachment.OffsetYDip -eq 24) '空主窗口放置对象必须回退到默认偏移。'

        foreach ($name in @(
            'incomplete-main-missing-reference-point',
            'incomplete-main-missing-offset-x',
            'incomplete-main-missing-offset-y')) {
            $incompleteMain = Get-ProbeCase $response $name
            Assert-Condition ($incompleteMain.Settings.MainAttachment.ReferencePoint -eq 2) "$name 必须使主窗口参考点回退默认值。"
            Assert-Condition ($incompleteMain.Settings.MainAttachment.OffsetXDip -eq -344 -and $incompleteMain.Settings.MainAttachment.OffsetYDip -eq 24) "$name 必须使主窗口偏移回退默认值。"
        }

        $invalidJson = Get-ProbeCase $response 'invalid-json-defaults'
        Assert-Condition ($invalidJson.Settings.SettingsVersion -eq 1) '损坏 JSON 未回退到当前默认版本。'
        Assert-Condition ($invalidJson.Settings.AnchorMode -eq 3) '损坏 JSON 未回退到默认吸附模式。'
        Assert-Condition ($invalidJson.Settings.CollapsedPrimaryField -eq 1) '损坏 JSON 未回退到默认左侧指标。'
        Assert-Condition ($invalidJson.Settings.CollapsedSecondaryField -eq 64) '损坏 JSON 未回退到默认右侧指标。'
    }

    if ($areas -contains 'Presentation') {
        $snapshot = @{
            ThreadId = '11111111-2222-3333-4444-555555555555'
            LogPath = 'C:\\tmp\\codex-session.jsonl'
            TotalTokens = 128400
            InputTokens = 82100
            CachedInputTokens = 31400
            OutputTokens = 12600
            ReasoningOutputTokens = 6500
            ContextUsedTokens = 62000
            ContextWindowTokens = 200000
            UpdatedAtUtc = '2026-08-11T00:00:00Z'
        }
        $zeroSnapshot = @{
            ThreadId = '00000000-0000-0000-0000-000000000000'
            LogPath = 'C:\\tmp\\zero-session.jsonl'
            TotalTokens = 0
            InputTokens = 0
            CachedInputTokens = 0
            OutputTokens = 0
            ReasoningOutputTokens = 0
            ContextUsedTokens = 0
            ContextWindowTokens = 0
            UpdatedAtUtc = '2026-08-11T00:00:00Z'
        }
        $fieldExpectations = @(
            @{ Name = 'total'; Field = 1; CompactLabel = '总'; ExpandedLabel = '总 Token'; Value = '128.4k' },
            @{ Name = 'input'; Field = 2; CompactLabel = '入'; ExpandedLabel = '输入'; Value = '82.1k' },
            @{ Name = 'output'; Field = 4; CompactLabel = '出'; ExpandedLabel = '输出'; Value = '12.6k' },
            @{ Name = 'cache-hit'; Field = 8; CompactLabel = '命中'; ExpandedLabel = '缓存命中'; Value = '31.4k' },
            @{ Name = 'cache-miss'; Field = 16; CompactLabel = '未中'; ExpandedLabel = '缓存未命中'; Value = '50.7k' },
            @{ Name = 'context'; Field = 32; CompactLabel = '上下文'; ExpandedLabel = '上下文用量'; Value = '62.0k / 200.0k' },
            @{ Name = 'context-percent'; Field = 64; CompactLabel = '上下文'; ExpandedLabel = '上下文占用'; Value = '31%' },
            @{ Name = 'reasoning'; Field = 128; CompactLabel = '推理'; ExpandedLabel = '推理输出'; Value = '6.5k' },
            @{ Name = 'thread'; Field = 256; CompactLabel = '会话'; ExpandedLabel = '会话'; Value = '1111…555555' },
            @{ Name = 'cache-hit-rate'; Field = 512; CompactLabel = '命中率'; ExpandedLabel = '缓存命中率'; Value = '38%' }
        )
        $originalCulture = [System.Globalization.CultureInfo]::CurrentCulture
        try {
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            Assert-Condition ([System.Globalization.CultureInfo]::CurrentCulture.NumberFormat.NumberDecimalSeparator -eq ',') '区域性覆盖未进入非点号小数文化。'
            $assembly = [System.Reflection.Assembly]::LoadFrom($applicationDll)
            $presentationBuilder = $assembly.GetType('CodexTokenOverlay.OverlayPresentationBuilder', $true)
            $formatTokenCount = $presentationBuilder.GetMethod(
                'FormatTokenCount',
                [System.Reflection.BindingFlags]'Public, Static')
            Assert-Condition ($null -ne $formatTokenCount) '未找到 FormatTokenCount。'
            $localizedLargeValue = $formatTokenCount.Invoke($null, [object[]]@([long]128400))
            $localizedMillionValue = $formatTokenCount.Invoke($null, [object[]]@([long]1200000))
            $localizedSmallValue = $formatTokenCount.Invoke($null, [object[]]@([long]999))
            Assert-Condition ($localizedLargeValue -eq '128.4k') '非点号小数文化下的千级格式必须保持不变。'
            Assert-Condition ($localizedMillionValue -eq '1.20M') '非点号小数文化下的百万级格式必须保持不变。'
            Assert-Condition ($localizedSmallValue -eq '999') '非点号小数文化下的整数格式必须保持不变。'
        }
        finally {
            [System.Globalization.CultureInfo]::CurrentCulture = $originalCulture
        }
        $contextBelowZeroSnapshot = @{} + $snapshot
        $contextBelowZeroSnapshot.ContextUsedTokens = -1
        $contextZeroSnapshot = @{} + $snapshot
        $contextZeroSnapshot.ContextUsedTokens = 0
        $contextHundredSnapshot = @{} + $snapshot
        $contextHundredSnapshot.ContextUsedTokens = 200000
        $contextAboveHundredSnapshot = @{} + $snapshot
        $contextAboveHundredSnapshot.ContextUsedTokens = 200001
        $cacheHitZeroSnapshot = @{} + $snapshot
        $cacheHitZeroSnapshot.InputTokens = 0
        $cacheHitZeroSnapshot.CachedInputTokens = 0
        $cacheHitNoneSnapshot = @{} + $snapshot
        $cacheHitNoneSnapshot.InputTokens = 100
        $cacheHitNoneSnapshot.CachedInputTokens = 0
        $cacheHitNegativeSnapshot = @{} + $snapshot
        $cacheHitNegativeSnapshot.InputTokens = 100
        $cacheHitNegativeSnapshot.CachedInputTokens = -1
        $cacheHitAboveHundredSnapshot = @{} + $snapshot
        $cacheHitAboveHundredSnapshot.InputTokens = 100
        $cacheHitAboveHundredSnapshot.CachedInputTokens = 200
        $cacheHitMaximumSnapshot = @{} + $snapshot
        $cacheHitMaximumSnapshot.InputTokens = [long]::MaxValue
        $cacheHitMaximumSnapshot.CachedInputTokens = [long]::MaxValue
        $presentationCases = @(
            @{
                Name = 'primary-secondary'
                Operation = 'Create'
                Snapshot = $snapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'valid-zero'
                Operation = 'Create'
                Snapshot = $zeroSnapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'waiting'
                Operation = 'Waiting'
                StatusText = '正在等待会话数据'
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'context-below-zero'
                Operation = 'Create'
                Snapshot = $contextBelowZeroSnapshot
                PrimaryField = 64
                SecondaryField = 1
                VisibleFields = 1023
            },
            @{
                Name = 'context-zero'
                Operation = 'Create'
                Snapshot = $contextZeroSnapshot
                PrimaryField = 64
                SecondaryField = 1
                VisibleFields = 1023
            },
            @{
                Name = 'context-hundred'
                Operation = 'Create'
                Snapshot = $contextHundredSnapshot
                PrimaryField = 64
                SecondaryField = 1
                VisibleFields = 1023
            },
            @{
                Name = 'context-above-hundred'
                Operation = 'Create'
                Snapshot = $contextAboveHundredSnapshot
                PrimaryField = 64
                SecondaryField = 1
                VisibleFields = 1023
            },
            @{
                Name = 'cache-hit-zero'
                Operation = 'Create'
                Snapshot = $cacheHitZeroSnapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'cache-hit-none'
                Operation = 'Create'
                Snapshot = $cacheHitNoneSnapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'cache-hit-negative'
                Operation = 'Create'
                Snapshot = $cacheHitNegativeSnapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'cache-hit-above-hundred'
                Operation = 'Create'
                Snapshot = $cacheHitAboveHundredSnapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'cache-hit-maximum'
                Operation = 'Create'
                Snapshot = $cacheHitMaximumSnapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            }
        )
        foreach ($expectedField in $fieldExpectations) {
            $presentationCases += @{
                Name = "field-$($expectedField.Name)"
                Operation = 'Create'
                Snapshot = $snapshot
                PrimaryField = if ($expectedField.Field -eq 512) { 1 } else { $expectedField.Field }
                SecondaryField = if ($expectedField.Field -eq 64) { 1 } else { 64 }
                VisibleFields = 1023
            }
        }

        $response = Invoke-JsonProbe '--presentation-probe' $presentationCases
        $selected = (Get-ProbeCase $response 'primary-secondary').Presentation
        Assert-Condition ($selected.Primary.CompactLabel -eq '总') '主指标紧凑标签不正确。'
        Assert-Condition ($selected.Primary.ExpandedLabel -eq '总 Token') '主指标展开标签不正确。'
        Assert-Condition ($selected.Primary.Value -eq '128.4k') '主指标值格式不正确。'
        Assert-Condition ($selected.Secondary.CompactLabel -eq '上下文') '次指标紧凑标签不正确。'
        Assert-Condition ($selected.Secondary.ExpandedLabel -eq '上下文占用') '次指标展开标签不正确。'
        Assert-Condition ($selected.Secondary.Value -eq '31%') '次指标值格式不正确。'
        Assert-Condition ($selected.ContextPercent -eq 31) '上下文百分比不正确。'
        Assert-Condition ($selected.ShowContextProgress -eq $true) '可见上下文百分比时应显示进度。'
        Assert-Condition (@($selected.ExpandedRows | Where-Object { $_.Field -eq 1 -or $_.Field -eq 64 }).Count -eq 0) '展开行重复了收起指标。'
        $contextRow = @($selected.ExpandedRows | Where-Object { $_.Field -eq 32 })
        Assert-Condition ($contextRow.Count -eq 1 -and $contextRow[0].Value -eq '62.0k / 200.0k') '上下文行格式不正确。'
        Assert-Condition (@($selected.ExpandedRows | ForEach-Object Field) -join ',' -eq '2,4,8,512,16,32,128,256') '展开行顺序或去重不正确。'

        $zero = (Get-ProbeCase $response 'valid-zero').Presentation
        Assert-Condition ($zero.Primary.Value -eq '0' -and $zero.Primary.HasValue -eq $true) '合法的数值零应显示为 0。'
        Assert-Condition ($zero.Secondary.Value -eq '0%' -and $zero.Secondary.HasValue -eq $true) '合法的上下文百分比零应有值。'

        $waiting = (Get-ProbeCase $response 'waiting').Presentation
        Assert-Condition ($waiting.StatusText -eq '正在等待会话数据') '等待态状态文本不正确。'
        Assert-Condition ($waiting.ShowContextProgress -eq $false) '等待态不应显示上下文进度。'
        $waitingMetrics = @($waiting.Primary; $waiting.Secondary; $waiting.ExpandedRows)
        Assert-Condition (@($waitingMetrics | Where-Object { $_.Value -ne '—' -or $_.HasValue }).Count -eq 0) '等待态指标必须为无值占位。'
        $waitingCacheHitRate = @($waiting.ExpandedRows | Where-Object { $_.Field -eq 512 })
        Assert-Condition ($waitingCacheHitRate.Count -eq 1 -and $waitingCacheHitRate[0].Value -eq '—' -and -not $waitingCacheHitRate[0].HasValue) '等待态缓存命中率必须为无值占位。'

        foreach ($expectedField in $fieldExpectations) {
            $presentation = (Get-ProbeCase $response "field-$($expectedField.Name)").Presentation
            $metric = if ($expectedField.Field -eq 512) {
                @($presentation.ExpandedRows | Where-Object { $_.Field -eq 512 })
            }
            else {
                @($presentation.Primary)
            }
            Assert-Condition ($metric.Count -eq 1) "字段 $($expectedField.Name) 未出现在展示结果中。"
            Assert-Condition ($metric[0].CompactLabel -eq $expectedField.CompactLabel) "字段 $($expectedField.Name) 的紧凑标签不正确。"
            Assert-Condition ($metric[0].ExpandedLabel -eq $expectedField.ExpandedLabel) "字段 $($expectedField.Name) 的展开标签不正确。"
            Assert-Condition ($metric[0].Value -eq $expectedField.Value) "字段 $($expectedField.Name) 的值格式不正确。"
            Assert-Condition ($metric[0].HasValue -eq $true) "字段 $($expectedField.Name) 应有值。"
        }

        foreach ($contextCase in @('context-below-zero', 'context-zero', 'context-hundred', 'context-above-hundred')) {
            $presentation = Get-ProbeCase $response $contextCase | Select-Object -ExpandProperty Presentation
            $expectedPercent = switch ($contextCase) {
                'context-below-zero' { 0 }
                'context-zero' { 0 }
                'context-hundred' { 100 }
                'context-above-hundred' { 100 }
            }
            Assert-Condition ($presentation.ContextPercent -eq $expectedPercent) "$contextCase 的上下文进度未限制在 0–100。"
            Assert-Condition ($presentation.Primary.Value -eq "$expectedPercent%") "$contextCase 的上下文显示值未限制在 0–100%。"
        }

        foreach ($cacheHitCase in @(
            @{ Name = 'cache-hit-zero'; Value = '0%' },
            @{ Name = 'cache-hit-none'; Value = '0%' },
            @{ Name = 'cache-hit-negative'; Value = '0%' },
            @{ Name = 'cache-hit-above-hundred'; Value = '100%' },
            @{ Name = 'cache-hit-maximum'; Value = '100%' })) {
            $presentation = Get-ProbeCase $response $cacheHitCase.Name | Select-Object -ExpandProperty Presentation
            $cacheHitRate = @($presentation.ExpandedRows | Where-Object { $_.Field -eq 512 })
            Assert-Condition ($cacheHitRate.Count -eq 1 -and $cacheHitRate[0].Value -eq $cacheHitCase.Value) "$($cacheHitCase.Name) 的缓存命中率不正确。"
            Assert-Condition ($cacheHitRate[0].HasValue -eq $true) "$($cacheHitCase.Name) 的缓存命中率应有值。"
        }

        $snapshotType = $assembly.GetType('CodexTokenOverlay.TokenSnapshot', $true)
        $displayFieldType = $assembly.GetType('CodexTokenOverlay.DisplayField', $true)
        $presentationBuilder = $assembly.GetType('CodexTokenOverlay.OverlayPresentationBuilder', $true)
        $createPresentation = $presentationBuilder.GetMethod(
            'Create',
            [System.Reflection.BindingFlags]'Public, Static')
        Assert-Condition ($null -ne $createPresentation) '未找到 OverlayPresentationBuilder.Create。'
        $reflectionSnapshot = [System.Activator]::CreateInstance($snapshotType, @(
            $snapshot.ThreadId,
            $snapshot.LogPath,
            [long]$snapshot.TotalTokens,
            [long]$snapshot.InputTokens,
            [long]$snapshot.CachedInputTokens,
            [long]$snapshot.OutputTokens,
            [long]$snapshot.ReasoningOutputTokens,
            [long]$snapshot.ContextUsedTokens,
            [long]$snapshot.ContextWindowTokens,
            [DateTime]::Parse(
                $snapshot.UpdatedAtUtc,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)))
        $cacheHitRateField = [Enum]::ToObject($displayFieldType, 512)
        $totalField = [Enum]::ToObject($displayFieldType, 1)
        $visibleFields = [Enum]::ToObject($displayFieldType, 1023)

        $cacheHitRatePrimary = $createPresentation.Invoke(
            $null,
            [object[]]@($reflectionSnapshot, $cacheHitRateField, $totalField, $visibleFields))
        Assert-Condition ($cacheHitRatePrimary.Primary.Field -eq 512) '缓存命中率作为主指标时字段不正确。'
        Assert-Condition ($cacheHitRatePrimary.Primary.CompactLabel -eq '命中率') '缓存命中率作为主指标时紧凑标签不正确。'
        Assert-Condition ($cacheHitRatePrimary.Primary.ExpandedLabel -eq '缓存命中率') '缓存命中率作为主指标时展开标签不正确。'
        Assert-Condition ($cacheHitRatePrimary.Primary.Value -eq '38%' -and $cacheHitRatePrimary.Primary.HasValue -eq $true) '缓存命中率作为主指标时值或 HasValue 不正确。'
        Assert-Condition ($cacheHitRatePrimary.Secondary.Field -eq 1) '缓存命中率作为主指标时另一指标不正确。'
        Assert-Condition (@($cacheHitRatePrimary.ExpandedRows | Where-Object { $_.Field -eq 512 -or $_.Field -eq 1 }).Count -eq 0) '缓存命中率作为主指标时展开行不得重复任一收起指标。'

        $cacheHitRateSecondary = $createPresentation.Invoke(
            $null,
            [object[]]@($reflectionSnapshot, $totalField, $cacheHitRateField, $visibleFields))
        Assert-Condition ($cacheHitRateSecondary.Secondary.Field -eq 512) '缓存命中率作为次指标时字段不正确。'
        Assert-Condition ($cacheHitRateSecondary.Secondary.CompactLabel -eq '命中率') '缓存命中率作为次指标时紧凑标签不正确。'
        Assert-Condition ($cacheHitRateSecondary.Secondary.ExpandedLabel -eq '缓存命中率') '缓存命中率作为次指标时展开标签不正确。'
        Assert-Condition ($cacheHitRateSecondary.Secondary.Value -eq '38%' -and $cacheHitRateSecondary.Secondary.HasValue -eq $true) '缓存命中率作为次指标时值或 HasValue 不正确。'
        Assert-Condition ($cacheHitRateSecondary.Primary.Field -eq 1) '缓存命中率作为次指标时另一指标不正确。'
        Assert-Condition (@($cacheHitRateSecondary.ExpandedRows | Where-Object { $_.Field -eq 512 -or $_.Field -eq 1 }).Count -eq 0) '缓存命中率作为次指标时展开行不得重复任一收起指标。'

        $allMetrics = @($selected.Primary; $selected.Secondary; $selected.ExpandedRows; $waiting.Primary; $waiting.Secondary; $waiting.ExpandedRows)
        Assert-Condition (@($allMetrics | Where-Object { $_.CompactLabel -match "[\r\n]" -or $_.ExpandedLabel -match "[\r\n]" -or $_.Value -match "[\r\n]" }).Count -eq 0) '展示字段不允许包含 CR/LF。'
    }

    if ($areas -contains 'Layout') {
        $baseWindow = @{
            Handle = 4294967296
            WindowBounds = @{ X = 0; Y = 0; Width = 1200; Height = 800 }
            ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1200; Height = 800 }
            CaptionButtonBounds = @{ X = 1050; Y = 0; Width = 150; Height = 46 }
            WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 1040 }
            Dpi = 96
            ChromeMetrics = @{
                CaptionButtonWidth = 50
                CaptionButtonHeight = 46
                FrameWidth = 4
                FrameHeight = 4
                PaddedBorderWidth = 2
            }
        }
        $primaryWindow = @{} + $baseWindow
        $primaryWindow.WindowBounds = @{ X = 0; Y = 0; Width = 468; Height = 800 }
        $primaryWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 468; Height = 800 }
        $primaryWindow.CaptionButtonBounds = @{ X = 318; Y = 0; Width = 150; Height = 46 }

        $narrowPrimaryWindow = @{} + $baseWindow
        $narrowPrimaryWindow.CaptionButtonBounds = @{ X = 283; Y = 0; Width = 150; Height = 46 }
        $narrowPrimaryWindow.WindowBounds = @{ X = 0; Y = 0; Width = 433; Height = 800 }
        $narrowPrimaryWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 433; Height = 800 }

        $hiddenWindow = @{} + $primaryWindow
        $hiddenWindow.CaptionButtonBounds = @{ X = 237; Y = 0; Width = 150; Height = 46 }
        $hiddenWindow.WindowBounds = @{ X = 0; Y = 0; Width = 387; Height = 800 }
        $hiddenWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 387; Height = 800 }

        $negativeWindow = @{} + $baseWindow
        $negativeWindow.WindowBounds = @{ X = -1600; Y = 100; Width = 1200; Height = 800 }
        $negativeWindow.ExtendedFrameBounds = @{ X = -1600; Y = 100; Width = 1200; Height = 800 }
        $negativeWindow.CaptionButtonBounds = @{ X = -550; Y = 100; Width = 150; Height = 46 }
        $negativeWindow.WorkingArea = @{ X = -1920; Y = 0; Width = 1920; Height = 1040 }

        $clippedWindow = @{} + $baseWindow
        $clippedWindow.WindowBounds = @{ X = -8; Y = -8; Width = 1936; Height = 1056 }
        $clippedWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1920; Height = 1040 }
        $clippedWindow.CaptionButtonBounds = @{ X = 1770; Y = 0; Width = 150; Height = 46 }
        $clippedWindow.WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 1040 }
        $partiallyOffscreenWindow = @{} + $baseWindow
        $partiallyOffscreenWindow.WindowBounds = @{ X = -400; Y = 100; Width = 1200; Height = 800 }
        $partiallyOffscreenWindow.ExtendedFrameBounds = @{ X = -400; Y = 100; Width = 1200; Height = 800 }
        $partiallyOffscreenWindow.CaptionButtonBounds = @{ X = 650; Y = 100; Width = 150; Height = 46 }

        $caption34Window = @{} + $baseWindow
        $caption34Window.CaptionButtonBounds = @{ X = 1050; Y = 0; Width = 150; Height = 34 }
        $caption32Window = @{} + $baseWindow
        $caption32Window.CaptionButtonBounds = @{ X = 1050; Y = 0; Width = 150; Height = 32 }
        $caption20Window = @{} + $baseWindow
        $caption20Window.CaptionButtonBounds = @{ X = 1050; Y = 0; Width = 150; Height = 20 }
        $caption19Window = @{} + $baseWindow
        $caption19Window.CaptionButtonBounds = @{ X = 1050; Y = 0; Width = 150; Height = 19 }

        $fallbackWindow = @{} + $baseWindow
        $fallbackWindow.CaptionButtonBounds = $null
        $clippedFallbackWindow = @{} + $fallbackWindow
        $clippedFallbackWindow.WindowBounds = @{ X = 0; Y = -8; Width = 1200; Height = 808 }
        $clippedFallbackWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1200; Height = 800 }
        $clippedFallbackWindow.ChromeMetrics = @{
            CaptionButtonWidth = 50
            CaptionButtonHeight = 30
            FrameWidth = 4
            FrameHeight = 4
            PaddedBorderWidth = 2
        }
        $invalidFallbackWindow = @{} + $fallbackWindow
        $invalidFallbackWindow.CaptionButtonBounds = @{ X = 4000; Y = 4000; Width = 150; Height = 46 }
        $invalidFallbackWindow.ChromeMetrics = @{
            CaptionButtonWidth = 0
            CaptionButtonHeight = 0
            FrameWidth = -1
            FrameHeight = -1
            PaddedBorderWidth = -1
        }
        $dpi192FallbackWindow = @{
            Handle = 1920
            WindowBounds = @{ X = 0; Y = 0; Width = 2400; Height = 1600 }
            ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 2400; Height = 1600 }
            CaptionButtonBounds = $null
            WorkingArea = @{ X = 0; Y = 0; Width = 3840; Height = 2080 }
            Dpi = 192
            ChromeMetrics = @{ CaptionButtonWidth = 100; CaptionButtonHeight = 92; FrameWidth = 8; FrameHeight = 8; PaddedBorderWidth = 4 }
        }

        $dpi0Window = @{} + $baseWindow
        $dpi0Window.Dpi = 0

        $manualDpi192Window = @{} + $baseWindow
        $manualDpi192Window.Dpi = 192

        $compressedWindow = @{} + $baseWindow
        $compressedWindow.WindowBounds = @{ X = 0; Y = 0; Width = 1200; Height = 400 }
        $compressedWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1200; Height = 400 }
        $compressedWindow.WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 400 }
        $tooShortWindow = @{} + $compressedWindow
        $tooShortWindow.WindowBounds = @{ X = 0; Y = 0; Width = 1200; Height = 350 }
        $tooShortWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1200; Height = 350 }
        $tooShortWindow.WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 350 }

        $autoRightWindow = @{} + $baseWindow
        $autoRightWindow.WindowBounds = @{ X = 200; Y = 100; Width = 800; Height = 600 }
        $autoRightWindow.ExtendedFrameBounds = @{ X = 200; Y = 100; Width = 800; Height = 600 }
        $autoRightWindow.CaptionButtonBounds = $null
        $autoLeftWindow = @{} + $autoRightWindow
        $autoLeftWindow.WindowBounds = @{ X = 920; Y = 100; Width = 800; Height = 600 }
        $autoLeftWindow.ExtendedFrameBounds = @{ X = 920; Y = 100; Width = 800; Height = 600 }
        $autoInsideWindow = @{} + $autoRightWindow
        $autoInsideWindow.WindowBounds = @{ X = 60; Y = 100; Width = 1800; Height = 800 }
        $autoInsideWindow.ExtendedFrameBounds = @{ X = 60; Y = 100; Width = 1800; Height = 800 }
        $autoUpWindow = @{} + $autoRightWindow
        $autoUpWindow.WindowBounds = @{ X = 200; Y = 400; Width = 800; Height = 600 }
        $autoUpWindow.ExtendedFrameBounds = @{ X = 200; Y = 400; Width = 800; Height = 600 }
        $autoCompressedDownWindow = @{} + $autoRightWindow
        $autoCompressedDownWindow.WindowBounds = @{ X = 200; Y = 100; Width = 800; Height = 214 }
        $autoCompressedDownWindow.ExtendedFrameBounds = @{ X = 200; Y = 100; Width = 800; Height = 214 }
        $autoCompressedDownWindow.WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 470 }
        $autoInsideUpWindow = @{} + $autoInsideWindow
        $autoInsideUpWindow.WindowBounds = @{ X = 60; Y = 400; Width = 1800; Height = 300 }
        $autoInsideUpWindow.ExtendedFrameBounds = @{ X = 60; Y = 400; Width = 1800; Height = 300 }
        $autoInsideUpWindow.WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 700 }

        $manualNoExpansionWindow = @{} + $baseWindow
        $manualNoExpansionWindow.WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 170 }

        $manualCaptionCollisionWindow = @{} + $baseWindow
        $manualCaptionCollisionWindow.WindowBounds = @{ X = 0; Y = 0; Width = 500; Height = 800 }
        $manualCaptionCollisionWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 500; Height = 800 }
        $manualCaptionCollisionWindow.CaptionButtonBounds = @{ X = 350; Y = 0; Width = 150; Height = 46 }

        $layoutCases = @(
            @{
                Name = 'caption-relative-to-negative-screen'
                Operation = 'ConvertCaptionBounds'
                WindowBounds = @{ X = -1600; Y = 20; Width = 1600; Height = 900 }
                RelativeBounds = @{ X = 1390; Y = 0; Width = 210; Height = 48 }
            },
            @{ Name = 'exact-collapsed'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'exact-expanded'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ClientPoints = @(@{ X = 20; Y = 20 }, @{ X = 100; Y = 20 }, @{ X = 20; Y = 80 }); ScreenPoints = @(@{ X = 792; Y = 26 }, @{ X = 872; Y = 26 }, @{ X = 792; Y = 86 }) },
            @{ Name = 'explicit-default-no-manual'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = $null; ScalePercent = 100 },
            @{ Name = 'manual-collapsed-60'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 60 },
            @{ Name = 'manual-collapsed-100'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 100 },
            @{ Name = 'manual-collapsed-130'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 130 },
            @{ Name = 'manual-collapsed-192-60'; HostWindow = $manualDpi192Window; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 60 },
            @{ Name = 'manual-scale-low-sanitized'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 20 },
            @{ Name = 'manual-scale-high-sanitized'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 999 },
            @{ Name = 'manual-expanded-60'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 60 },
            @{ Name = 'manual-expanded-100'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 100 },
            @{ Name = 'manual-expanded-130'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 130 },
            @{ Name = 'manual-direction-60-down'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 800 }; ScalePercent = 60 },
            @{ Name = 'manual-direction-130-up'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 800 }; ScalePercent = 130 },
            @{ Name = 'manual-outside-work-area'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 2500; Y = 1500 }; ScalePercent = 100 },
            @{ Name = 'manual-no-expansion-does-not-fall-back'; HostWindow = $manualNoExpansionWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 85 }; ScalePercent = 100 },
            @{ Name = 'manual-titlebar-cannot-expand-over-caption-buttons'; HostWindow = $manualCaptionCollisionWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 185; Y = 24 }; ScalePercent = 130 },
            @{ Name = 'hidden-scale-sanitized'; HostWindow = $hiddenWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 999 },
            @{ Name = 'legacy-system-offsets-at-scale-60'; HostWindow = $baseWindow; AnchorMode = 1; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 60 },
            @{ Name = 'primary-only'; HostWindow = $primaryWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'primary-can-expand'; HostWindow = $primaryWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'narrow-primary-115'; HostWindow = $narrowPrimaryWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'hidden-for-width'; HostWindow = $hiddenWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi-120'; HostWindow = @{ Handle = 120; WindowBounds = @{ X = 0; Y = 0; Width = 1500; Height = 1000 }; ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1500; Height = 1000 }; CaptionButtonBounds = @{ X = 1313; Y = 0; Width = 187; Height = 58 }; WorkingArea = @{ X = 0; Y = 0; Width = 2400; Height = 1300 }; Dpi = 120; ChromeMetrics = @{ CaptionButtonWidth = 63; CaptionButtonHeight = 58; FrameWidth = 5; FrameHeight = 5; PaddedBorderWidth = 3 } }; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi-144'; HostWindow = @{ Handle = 144; WindowBounds = @{ X = 0; Y = 0; Width = 1800; Height = 1200 }; ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1800; Height = 1200 }; CaptionButtonBounds = @{ X = 1575; Y = 0; Width = 225; Height = 69 }; WorkingArea = @{ X = 0; Y = 0; Width = 2880; Height = 1560 }; Dpi = 144; ChromeMetrics = @{ CaptionButtonWidth = 75; CaptionButtonHeight = 69; FrameWidth = 6; FrameHeight = 6; PaddedBorderWidth = 3 } }; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi-192'; HostWindow = @{ Handle = 192; WindowBounds = @{ X = 0; Y = 0; Width = 2400; Height = 1600 }; ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 2400; Height = 1600 }; CaptionButtonBounds = @{ X = 2100; Y = 0; Width = 300; Height = 92 }; WorkingArea = @{ X = 0; Y = 0; Width = 3840; Height = 2080 }; Dpi = 192; ChromeMetrics = @{ CaptionButtonWidth = 100; CaptionButtonHeight = 92; FrameWidth = 8; FrameHeight = 8; PaddedBorderWidth = 4 } }; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'negative-display'; HostWindow = $negativeWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'clipped-maximized'; HostWindow = $clippedWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'partially-offscreen'; HostWindow = $partiallyOffscreenWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'title-fit-caption-34'; HostWindow = $caption34Window; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'title-fit-caption-32'; HostWindow = $caption32Window; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'title-fit-caption-20'; HostWindow = $caption20Window; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'title-fit-caption-19-hidden'; HostWindow = $caption19Window; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'title-fit-caption-46'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'title-fit-primary-150'; HostWindow = $primaryWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'title-fit-scale-low'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 20 },
            @{ Name = 'title-fit-scale-high'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 999 },
            @{ Name = 'title-fit-expanded-caption-34'; HostWindow = $caption34Window; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'fallback-caption'; HostWindow = $fallbackWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'fallback-caption-clipped'; HostWindow = $clippedFallbackWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'fallback-caption-192'; HostWindow = $dpi192FallbackWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'invalid-fallback'; HostWindow = $invalidFallbackWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi0-title'; HostWindow = $dpi0Window; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi0-auto'; HostWindow = $dpi0Window; AnchorMode = 0; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi0-inside-top'; HostWindow = $dpi0Window; AnchorMode = 1; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi0-inside-bottom'; HostWindow = $dpi0Window; AnchorMode = 2; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'inside-top-expanded'; HostWindow = $baseWindow; AnchorMode = 1; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'inside-bottom-expanded'; HostWindow = $baseWindow; AnchorMode = 2; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'compressed-rows'; HostWindow = $compressedWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 8; ShowContextProgress = $true },
            @{ Name = 'insufficient-height'; HostWindow = $tooShortWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 8; ShowContextProgress = $true },
            @{ Name = 'auto-right'; HostWindow = $autoRightWindow; AnchorMode = 0; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'auto-left'; HostWindow = $autoLeftWindow; AnchorMode = 0; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'auto-inside'; HostWindow = $autoInsideWindow; AnchorMode = 0; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'auto-down'; HostWindow = $autoRightWindow; AnchorMode = 0; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'auto-up'; HostWindow = $autoUpWindow; AnchorMode = 0; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'auto-compressed-down'; HostWindow = $autoCompressedDownWindow; AnchorMode = 0; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'auto-inside-up'; HostWindow = $autoInsideUpWindow; AnchorMode = 0; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true }
        )

        $response = Invoke-JsonProbe '--layout-probe' $layoutCases
        $layoutContract = Invoke-HostSurfaceContractReflectionProbe
        $removedLayoutProperty = 'Preferred' + 'P' + 'etBounds'
        Assert-Condition `
            (-not (@($layoutContract.LayoutRequestProperties) -contains $removedLayoutProperty)) `
            "OverlayLayoutRequest 不得保留已删除的附着矩形属性。actual=$(@($layoutContract.LayoutRequestProperties) -join ',')"
        Assert-Rect (Get-ProbeCase $response 'caption-relative-to-negative-screen').ScreenBounds -210 20 210 48 '标题按钮相对坐标未以原始窗口左上角转换为屏幕坐标。'
        $collapsed = (Get-ProbeCase $response 'exact-collapsed').Layout
        Assert-Condition ((Get-ProbeCase $response 'exact-collapsed').Handle -eq 4294967296) '布局探针未以 long 往返窗口句柄。'
        Assert-Condition ($collapsed.State -eq 0) '精确收起案例状态不正确。'
        Assert-Condition ($collapsed.CollapsedDisplay -eq 0) '精确收起案例未显示双字段。'
        Assert-Condition ((@($collapsed.WindowBounds.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'Height,Width,X,Y') '布局探针矩形必须只序列化 X/Y/Width/Height。'
        Assert-Rect $collapsed.WindowBounds 802 6 240 34 '100% 标题栏双字段宽度必须为 240。'
        Assert-Rect $collapsed.CapsuleBounds 0 0 240 34 '100% 标题栏胶囊客户区宽度必须为 240。'
        Assert-Rect $collapsed.PanelBounds 0 0 0 0 '精确收起面板应为空。'

        $expandedCase = Get-ProbeCase $response 'exact-expanded'
        $expanded = $expandedCase.Layout
        Assert-Condition ($expanded.State -eq 1) '精确展开案例状态不正确。'
        Assert-Condition ($expanded.ExpansionDirection -eq 0) '标题栏展开方向必须向下。'
        Assert-Condition ($expanded.Dpi -eq 96) '布局结果 DPI 不正确。'
        Assert-Condition ($expanded.ExpandedRowHeight -eq 30) '正常展开行高不正确。'
        Assert-Rect $expanded.WindowBounds 772 6 270 282 '精确展开窗口矩形不正确。'
        Assert-Rect $expanded.CapsuleBounds 30 0 240 34 '加宽胶囊必须在展开窗口内右对齐。'
        Assert-Rect $expanded.PanelBounds 0 40 270 242 '面板几何不得变化。'
        Assert-Condition (-not $expandedCase.ContainsClientPoints[0]) '左上角 30×40 镂空区不应可交互。'
        Assert-Condition ($expandedCase.ContainsClientPoints[1]) '胶囊点应在交互并集中。'
        Assert-Condition ($expandedCase.ContainsClientPoints[2]) '面板点应在交互并集中。'
        Assert-Condition (-not $expandedCase.ContainsScreenPoints[0]) '屏幕坐标镂空区不应可交互。'
        Assert-Condition ($expandedCase.ContainsScreenPoints[1]) '屏幕坐标胶囊点应可交互。'
        Assert-Condition ($expandedCase.ContainsScreenPoints[2]) '屏幕坐标面板点应可交互。'

        Assert-Condition ($collapsed.ScalePercent -eq 100 -and $expanded.ScalePercent -eq 100) '缺省缩放必须在收起和展开结果中保持 100%。'
        Assert-LayoutEqual `
            (Get-ProbeCase $response 'explicit-default-no-manual').Layout `
            $collapsed `
            'ManualCapsuleCenter=null 且 ScalePercent=100 必须完整保留旧标题栏几何。'

        foreach ($manualCollapsedCase in @(
            @{ Name = 'manual-collapsed-60'; X = 941; Y = 290; Width = 118; Height = 20; Scale = 60 },
            @{ Name = 'manual-collapsed-100'; X = 902; Y = 283; Width = 196; Height = 34; Scale = 100 },
            @{ Name = 'manual-collapsed-130'; X = 873; Y = 278; Width = 255; Height = 44; Scale = 130 },
            @{ Name = 'manual-collapsed-192-60'; X = 883; Y = 280; Width = 235; Height = 41; Scale = 60 },
            @{ Name = 'manual-scale-low-sanitized'; X = 941; Y = 290; Width = 118; Height = 20; Scale = 60 },
            @{ Name = 'manual-scale-high-sanitized'; X = 873; Y = 278; Width = 255; Height = 44; Scale = 130 }
        )) {
            $manualCollapsed = (Get-ProbeCase $response $manualCollapsedCase.Name).Layout
            Assert-Condition ($manualCollapsed.State -eq 0 -and $manualCollapsed.CollapsedDisplay -eq 0) "$($manualCollapsedCase.Name) 必须保留手动双字段收起布局。"
            Assert-Condition ($manualCollapsed.ScalePercent -eq $manualCollapsedCase.Scale) "$($manualCollapsedCase.Name) 返回的缩放未正确清理。"
            Assert-Rect $manualCollapsed.WindowBounds $manualCollapsedCase.X $manualCollapsedCase.Y $manualCollapsedCase.Width $manualCollapsedCase.Height "$($manualCollapsedCase.Name) 手动中心收起矩形不正确。"
            Assert-Rect $manualCollapsed.CapsuleBounds 0 0 $manualCollapsedCase.Width $manualCollapsedCase.Height "$($manualCollapsedCase.Name) 手动胶囊客户区不正确。"
        }
        Assert-Condition ((Get-ProbeCase $response 'manual-collapsed-100').Layout.CapsuleBounds.Width -eq 196) '手动吸附双字段宽度不得改变。'

        foreach ($manualExpandedCase in @(
            @{ Name = 'manual-expanded-60'; X = 897; Y = 290; Width = 162; Height = 169; CapsuleX = 44; CapsuleY = 0; CapsuleWidth = 118; CapsuleHeight = 20; PanelY = 24; PanelHeight = 145; RowHeight = 18; Scale = 60 },
            @{ Name = 'manual-expanded-100'; X = 828; Y = 283; Width = 270; Height = 282; CapsuleX = 74; CapsuleY = 0; CapsuleWidth = 196; CapsuleHeight = 34; PanelY = 40; PanelHeight = 242; RowHeight = 30; Scale = 100 },
            @{ Name = 'manual-expanded-130'; X = 777; Y = 278; Width = 351; Height = 367; CapsuleX = 96; CapsuleY = 0; CapsuleWidth = 255; CapsuleHeight = 44; PanelY = 52; PanelHeight = 315; RowHeight = 39; Scale = 130 }
        )) {
            $manualExpanded = (Get-ProbeCase $response $manualExpandedCase.Name).Layout
            Assert-Condition ($manualExpanded.State -eq 1 -and $manualExpanded.ExpansionDirection -eq 0) "$($manualExpandedCase.Name) 必须向下展开。"
            Assert-Condition ($manualExpanded.ScalePercent -eq $manualExpandedCase.Scale) "$($manualExpandedCase.Name) 返回缩放不正确。"
            Assert-Condition ($manualExpanded.ExpandedRowHeight -eq $manualExpandedCase.RowHeight) "$($manualExpandedCase.Name) 行高未按用户比例缩放。"
            Assert-Rect $manualExpanded.WindowBounds $manualExpandedCase.X $manualExpandedCase.Y $manualExpandedCase.Width $manualExpandedCase.Height "$($manualExpandedCase.Name) 展开窗口矩形不正确。"
            Assert-Rect $manualExpanded.CapsuleBounds $manualExpandedCase.CapsuleX $manualExpandedCase.CapsuleY $manualExpandedCase.CapsuleWidth $manualExpandedCase.CapsuleHeight "$($manualExpandedCase.Name) 胶囊矩形不正确。"
            Assert-Rect $manualExpanded.PanelBounds 0 $manualExpandedCase.PanelY $manualExpandedCase.Width $manualExpandedCase.PanelHeight "$($manualExpandedCase.Name) 面板尺寸未按用户比例缩放。"
        }

        Assert-Condition ((Get-ProbeCase $response 'manual-direction-60-down').Layout.ExpansionDirection -eq 0) '60% 手动布局应按缩放后的可用高度向下展开。'
        Assert-Condition ((Get-ProbeCase $response 'manual-direction-130-up').Layout.ExpansionDirection -eq 1) '130% 手动布局应按缩放后的可用高度向上展开。'

        $manualOutside = (Get-ProbeCase $response 'manual-outside-work-area').Layout
        Assert-Condition ($manualOutside.State -eq 1 -and $manualOutside.ExpansionDirection -eq 1) '工作区外手动中心应最小平移后向上展开。'
        Assert-Rect $manualOutside.WindowBounds 1650 758 270 282 '工作区外手动中心的完整窗口必须钳制到工作区。'
        Assert-Rect $manualOutside.CapsuleBounds 74 248 196 34 '工作区外手动中心的胶囊平移不正确。'
        Assert-Rect $manualOutside.PanelBounds 0 0 270 242 '工作区外手动中心的面板必须完整保留。'

        $manualNoExpansion = (Get-ProbeCase $response 'manual-no-expansion-does-not-fall-back').Layout
        Assert-Condition ($manualNoExpansion.State -eq 0) '手动布局上下均无法展开时必须保持收起。'
        Assert-Rect $manualNoExpansion.WindowBounds 902 68 196 34 '手动展开无空间时不得回落传统锚点。'

        $manualCaptionCollision = (Get-ProbeCase $response 'manual-titlebar-cannot-expand-over-caption-buttons').Layout
        Assert-Condition ($manualCaptionCollision.State -eq 0) '标题栏中的手动胶囊无法安全容纳展开面板时必须保持收起。'
        Assert-Rect $manualCaptionCollision.WindowBounds 58 2 255 44 '标题栏手动布局不得为展开面板移入标题按钮区。'

        Assert-Condition ((Get-ProbeCase $response 'hidden-scale-sanitized').Layout.ScalePercent -eq 130) 'Hidden 结果也必须携带清理后的缩放。'

        $legacyScaled = (Get-ProbeCase $response 'legacy-system-offsets-at-scale-60').Layout
        Assert-Rect $legacyScaled.WindowBounds 1064 56 118 20 '传统锚点偏移必须仅按系统 DPI 缩放，胶囊尺寸才使用用户比例。'

        $primary = (Get-ProbeCase $response 'primary-only').Layout
        Assert-Condition ($primary.State -eq 0 -and $primary.CollapsedDisplay -eq 1) '150 DIP 可用宽度必须降级为单字段。'
        Assert-Rect $primary.WindowBounds 194 6 116 34 '单字段收起宽度必须为 116 DIP。'
        $primaryExpanded = (Get-ProbeCase $response 'primary-can-expand').Layout
        Assert-Condition ($primaryExpanded.State -eq 1 -and $primaryExpanded.CollapsedDisplay -eq 1) 'PrimaryOnly 不应阻止完整面板展开。'
        Assert-Rect $primaryExpanded.PanelBounds 0 40 270 242 'PrimaryOnly 展开面板必须保留完整宽度。'

        $narrowPrimary = (Get-ProbeCase $response 'narrow-primary-115').Layout
        Assert-Condition ($narrowPrimary.State -eq 0) '115px 可用宽度必须保持收起显示，不能误判为空间不足。'
        Assert-Condition ($narrowPrimary.ScalePercent -eq 99) '115px 可用宽度必须选择最大 99% 比例。'
        Assert-Condition ($narrowPrimary.CollapsedDisplay -eq 1) '115px 可用宽度必须降级为单字段。'
        Assert-Condition ($narrowPrimary.CapsuleBounds.Width -eq 115) '115px 可用宽度的胶囊必须完整占用 115px。'
        Assert-Rect $narrowPrimary.WindowBounds 160 6 115 34 '115px 可用宽度的 99% 单字段矩形不正确。'

        $hiddenWidth = (Get-ProbeCase $response 'hidden-for-width').Layout
        Assert-Condition ($hiddenWidth.State -eq 2) '小于 60% 单字段宽度的可用空间必须隐藏。'
        Assert-Rect $hiddenWidth.WindowBounds 0 0 0 0 '宽度不足时窗口矩形必须为空。'
        Assert-Rect $hiddenWidth.CapsuleBounds 0 0 0 0 '宽度不足时胶囊矩形必须为空。'
        Assert-Rect $hiddenWidth.PanelBounds 0 0 0 0 '宽度不足时面板矩形必须为空。'

        foreach ($dpiCase in @(
            @{ Name = 'dpi-120'; Dpi = 120; CapsuleWidth = 300; CapsuleHeight = 43; PanelWidth = 338; PanelHeight = 305; RowHeight = 38 },
            @{ Name = 'dpi-144'; Dpi = 144; CapsuleWidth = 360; CapsuleHeight = 51; PanelWidth = 405; PanelHeight = 363; RowHeight = 45 },
            @{ Name = 'dpi-192'; Dpi = 192; CapsuleWidth = 480; CapsuleHeight = 68; PanelWidth = 540; PanelHeight = 484; RowHeight = 60 }
        )) {
            $layout = (Get-ProbeCase $response $dpiCase.Name).Layout
            Assert-Condition ($layout.Dpi -eq $dpiCase.Dpi) "$($dpiCase.Name) 返回 DPI 不正确。"
            Assert-Condition ($layout.CapsuleBounds.Width -eq $dpiCase.CapsuleWidth -and $layout.CapsuleBounds.Height -eq $dpiCase.CapsuleHeight) "$($dpiCase.Name) 胶囊未恰好缩放一次。"
            Assert-Condition ($layout.PanelBounds.Width -eq $dpiCase.PanelWidth -and $layout.PanelBounds.Height -eq $dpiCase.PanelHeight) "$($dpiCase.Name) 面板未恰好缩放一次。"
            Assert-Condition ($layout.ExpandedRowHeight -eq $dpiCase.RowHeight) "$($dpiCase.Name) 行高未恰好缩放一次。"
        }
        $dpi192 = (Get-ProbeCase $response 'dpi-192').Layout
        Assert-Rect $dpi192.WindowBounds 1544 12 540 564 '192 DPI 展开窗口必须严格为 96 DPI 的两倍。'
        Assert-Rect $dpi192.CapsuleBounds 60 0 480 68 '192 DPI 胶囊客户区必须严格为 96 DPI 的两倍。'
        Assert-Rect $dpi192.PanelBounds 0 80 540 484 '192 DPI 面板客户区必须严格为 96 DPI 的两倍。'

        foreach ($boundedCase in @('negative-display', 'clipped-maximized', 'partially-offscreen')) {
            $layout = (Get-ProbeCase $response $boundedCase).Layout
            $hostFixture = switch ($boundedCase) {
                'negative-display' { $negativeWindow }
                'clipped-maximized' { $clippedWindow }
                default { $partiallyOffscreenWindow }
            }
            Assert-Condition ($layout.WindowBounds.X -ge $hostFixture.WorkingArea.X -and $layout.WindowBounds.Y -ge $hostFixture.WorkingArea.Y) "$boundedCase 超出工作区左上边界。"
            Assert-Condition (($layout.WindowBounds.X + $layout.WindowBounds.Width) -le ($hostFixture.WorkingArea.X + $hostFixture.WorkingArea.Width)) "$boundedCase 超出工作区右边界。"
            Assert-Condition (($layout.WindowBounds.Y + $layout.WindowBounds.Height) -le ($hostFixture.WorkingArea.Y + $hostFixture.WorkingArea.Height)) "$boundedCase 超出工作区下边界。"
            Assert-Condition (($layout.WindowBounds.X + $layout.CapsuleBounds.X + $layout.CapsuleBounds.Width) -le ($hostFixture.CaptionButtonBounds.X - 8)) "$boundedCase 胶囊越过标题栏安全边界。"
        }

        $autoCompressedDown = (Get-ProbeCase $response 'auto-compressed-down').Layout
        Assert-Condition ($autoCompressedDown.State -eq 1 -and $autoCompressedDown.ExpansionDirection -eq 0 -and $autoCompressedDown.ExpandedRowHeight -eq 24) 'Auto 应选择可容纳 24 DIP 压缩行的下方，而不是选择无法容纳最小面板的上方。'
        $autoInsideUp = (Get-ProbeCase $response 'auto-inside-up').Layout
        Assert-Condition ($autoInsideUp.State -eq 1 -and $autoInsideUp.ExpansionDirection -eq 1 -and $autoInsideUp.ExpandedRowHeight -eq 30) 'Auto 回退到窗口内坐标后仍应按可用空间向上展开。'

        $title34 = (Get-ProbeCase $response 'title-fit-caption-34').Layout
        Assert-Condition ($title34.State -eq 0 -and $title34.ScalePercent -eq 101 -and $title34.CollapsedDisplay -eq 0) '34px 标题栏有效比例必须保持 101%。'
        Assert-Rect $title34.WindowBounds 800 0 242 34 '34px 标题栏应使用 101% 下的 240 DIP 宽度。'

        $title32 = (Get-ProbeCase $response 'title-fit-caption-32').Layout
        Assert-Condition ($title32.State -eq 0 -and $title32.ScalePercent -eq 95 -and $title32.CollapsedDisplay -eq 0) '32px 标题栏必须选择可完整容纳双字段的最大 95% 比例。'
        Assert-Rect $title32.WindowBounds 814 0 228 32 '32px 标题栏几何不正确。'

        $title20 = (Get-ProbeCase $response 'title-fit-caption-20').Layout
        Assert-Condition ($title20.State -eq 0 -and $title20.ScalePercent -eq 60 -and $title20.CollapsedDisplay -eq 0) '20px 标题栏必须在最小 60% 比例完整显示双字段。'
        Assert-Rect $title20.WindowBounds 898 0 144 20 '20px 标题栏几何不正确。'

        $title19 = (Get-ProbeCase $response 'title-fit-caption-19-hidden').Layout
        Assert-Condition ($title19.State -eq 2) '19px 标题栏仍必须隐藏。'
        Assert-Rect $title19.WindowBounds 0 0 0 0 '无安全标题栏比例时不得生成客户区内右上矩形。'

        $title46 = (Get-ProbeCase $response 'title-fit-caption-46').Layout
        Assert-Condition ($title46.State -eq 0 -and $title46.ScalePercent -eq 130 -and $title46.CollapsedDisplay -eq 0) '46px 标题栏必须保留请求的 130% 双字段比例。'
        Assert-Rect $title46.WindowBounds 730 1 312 44 '130% 标题栏几何不正确。'

        $titlePrimary = (Get-ProbeCase $response 'title-fit-primary-150').Layout
        Assert-Condition ($titlePrimary.State -eq 0 -and $titlePrimary.ScalePercent -eq 129 -and $titlePrimary.CollapsedDisplay -eq 1) '150px 必须保持 129% 单字段回退。'
        Assert-Rect $titlePrimary.WindowBounds 160 1 150 44 '150px 单字段边界不得改变。'

        $titleLow = (Get-ProbeCase $response 'title-fit-scale-low').Layout
        Assert-Condition ($titleLow.ScalePercent -eq 60) '标题栏请求比例 20% 必须先清理为 60%。'
        $titleHigh = (Get-ProbeCase $response 'title-fit-scale-high').Layout
        Assert-Condition ($titleHigh.ScalePercent -eq 130) '标题栏请求比例 999% 必须从 130% 开始搜索。'
        Assert-Condition ($title34.ScalePercent -eq 101 -and $title46.ScalePercent -eq 130) '标题栏空间恢复后必须重新使用未被改写的 130% 请求比例。'

        $titleExpanded = (Get-ProbeCase $response 'title-fit-expanded-caption-34').Layout
        Assert-Condition ($titleExpanded.State -eq 1 -and $titleExpanded.ScalePercent -eq 101 -and $titleExpanded.ExpandedRowHeight -eq 30) '34px 标题栏展开布局必须全程使用 101% 有效比例。'
        Assert-Rect $titleExpanded.WindowBounds 769 0 273 283 '101% 展开窗口矩形不正确。'
        Assert-Rect $titleExpanded.CapsuleBounds 31 0 242 34 '101% 展开胶囊客户区矩形不正确。'
        Assert-Rect $titleExpanded.PanelBounds 0 40 273 243 '101% 展开面板矩形不正确。'

        $layoutAssembly = [System.Reflection.Assembly]::LoadFrom($applicationDll)
        $renderMetricsType = $layoutAssembly.GetType('CodexTokenOverlay.OverlayRenderMetrics', $true)
        $createRenderMetrics = $renderMetricsType.GetMethod('Create', [System.Reflection.BindingFlags]'Public, Static')
        $titleRenderMetrics = $createRenderMetrics.Invoke($null, [object[]]@([uint32]96, [int]$titleExpanded.ScalePercent))
        Assert-Condition `
            ($titleRenderMetrics.LabelFontPoints -eq 10.1 -and $titleRenderMetrics.CompactValueFontPoints -eq 12.12 -and $titleRenderMetrics.CapsuleRadius -eq 10 -and $titleRenderMetrics.HorizontalPadding -eq 10) `
            '标题栏绘制指标必须来自布局返回的 101% 有效比例。'

        $metrics = $createRenderMetrics.Invoke($null, [object[]]@([uint32]96, [int]100))
        Add-Type -AssemblyName System.Windows.Forms
        $bitmap = $null
        $graphics = $null
        $labelFont = $null
        $valueFont = $null
        try {
            $bitmap = [System.Drawing.Bitmap]::new(1, 1)
            $bitmap.SetResolution(96, 96)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $labelFont = [System.Drawing.Font]::new(
                'Segoe UI',
                [single]$metrics.LabelFontPoints,
                [System.Drawing.FontStyle]::Regular,
                [System.Drawing.GraphicsUnit]::Point)
            $valueFont = [System.Drawing.Font]::new(
                'Segoe UI Semibold',
                [single]$metrics.CompactValueFontPoints,
                [System.Drawing.FontStyle]::Regular,
                [System.Drawing.GraphicsUnit]::Point)
            Assert-Condition ($labelFont.Name -eq 'Segoe UI') '真实字体测量必须解析到 Segoe UI。'
            Assert-Condition ($valueFont.Name -eq 'Segoe UI Semibold') '真实字体测量必须解析到 Segoe UI Semibold。'
            $measureFlags = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
            $totalLabelWidth = [System.Windows.Forms.TextRenderer]::MeasureText(
                $graphics, '总', $labelFont, [System.Drawing.Size]::Empty, $measureFlags).Width
            $totalValueWidth = [System.Windows.Forms.TextRenderer]::MeasureText(
                $graphics, '163.45M', $valueFont, [System.Drawing.Size]::Empty, $measureFlags).Width
            $hitLabelWidth = [System.Windows.Forms.TextRenderer]::MeasureText(
                $graphics, '命中率', $labelFont, [System.Drawing.Size]::Empty, $measureFlags).Width
            $hitValueWidth = [System.Windows.Forms.TextRenderer]::MeasureText(
                $graphics, '38%', $valueFont, [System.Drawing.Size]::Empty, $measureFlags).Width

            $capsuleWidth = 240
            $contentWidth = $capsuleWidth - (2 * $metrics.HorizontalPadding)
            $columnWidth = [math]::Floor($contentWidth / 2) - $metrics.MetricGap
            $totalRequired = $totalLabelWidth + $metrics.CompactMetricGap + $totalValueWidth
            $hitRequired = $hitLabelWidth + $metrics.CompactMetricGap + $hitValueWidth
            $totalMargin = $columnWidth - $totalRequired
            $hitMargin = $columnWidth - $hitRequired

            Write-Host "字体可读性测量：240px column=$columnWidth totalRequired=$totalRequired totalMargin=$totalMargin hitRequired=$hitRequired hitMargin=$hitMargin minimumMargin=$($metrics.CompactMetricGap)"
            Assert-Condition ($totalMargin -ge $metrics.CompactMetricGap) '240 DIP 必须完整容纳“总 163.45M”并保留一个紧凑指标间距。'
            Assert-Condition ($hitMargin -ge $metrics.CompactMetricGap) '240 DIP 必须完整容纳“命中率 38%”并保留一个紧凑指标间距。'

            $oldContentWidth = 196 - (2 * $metrics.HorizontalPadding)
            $oldColumnWidth = [math]::Floor($oldContentWidth / 2) - $metrics.MetricGap
            $oldTotalMargin = $oldColumnWidth - $totalRequired
            Write-Host "字体负控测量：196px column=$oldColumnWidth totalRequired=$totalRequired totalMargin=$oldTotalMargin minimumMargin=$($metrics.CompactMetricGap)"
            Assert-Condition `
                ($oldTotalMargin -lt $metrics.CompactMetricGap) `
                '旧 196px 宽度负控不得为“总 163.45M”保留一个紧凑指标间距的可读余量。'
        }
        finally {
            if ($null -ne $valueFont) { $valueFont.Dispose() }
            if ($null -ne $labelFont) { $labelFont.Dispose() }
            if ($null -ne $graphics) { $graphics.Dispose() }
            if ($null -ne $bitmap) { $bitmap.Dispose() }
        }

        $layoutResultType = $layoutAssembly.GetType('CodexTokenOverlay.OverlayLayoutResult', $true)
        $dpiGetter = $layoutResultType.GetProperty('Dpi').GetMethod
        $scaleGetter = $layoutResultType.GetProperty('ScalePercent').GetMethod
        $formType = $layoutAssembly.GetType('CodexTokenOverlay.TokenStripForm', $true)
        $applyLayout = $formType.GetMethod('ApplyLayout', [System.Reflection.BindingFlags]'Public, Instance')
        $onPaint = $formType.GetMethod('OnPaint', [System.Reflection.BindingFlags]'NonPublic, Instance')
        Assert-Condition `
            (Test-MethodCallChain $applyLayout @($dpiGetter, $scaleGetter, $createRenderMetrics)) `
            'TokenStripForm.ApplyLayout 必须把布局结果的有效比例传给区域绘制指标。'
        Assert-Condition `
            (Test-MethodCallChain $onPaint @($dpiGetter, $scaleGetter, $createRenderMetrics)) `
            'TokenStripForm.OnPaint 必须把布局结果的有效比例传给实际绘制指标。'
        Assert-Condition ((Get-ProbeCase $response 'fallback-caption').Layout.State -ne 2) '缺失标题按钮时有效回退指标应继续布局。'
        $fallbackClipped = (Get-ProbeCase $response 'fallback-caption-clipped').Layout
        Assert-Condition ($fallbackClipped.State -eq 0 -and $fallbackClipped.ScalePercent -eq 83 -and $fallbackClipped.CapsuleBounds.Height -eq 28) '回退标题区域裁切为 28px 时必须选择完整适配的最大 83% 比例。'
        Assert-Rect $fallbackClipped.WindowBounds 831 0 199 28 '回退标题区域裁切后的最大适配矩形不正确。'
        Assert-Rect $fallbackClipped.CapsuleBounds 0 0 199 28 '回退标题区域裁切后必须使用 240 DIP 标题栏宽度。'
        Assert-Condition ((Get-ProbeCase $response 'fallback-caption-192').Layout.CapsuleBounds.Height -eq 68) '高 DPI 回退指标不应被重复缩放。'
        Assert-Condition ((Get-ProbeCase $response 'invalid-fallback').Layout.State -eq 2) '无效标题按钮和不可用回退指标必须隐藏。'

        Assert-Condition ((Get-ProbeCase $response 'dpi0-title').Layout.State -eq 2) 'Dpi=0 时标题栏锚点必须隐藏。'
        foreach ($legacyCase in @('dpi0-auto', 'dpi0-inside-top', 'dpi0-inside-bottom')) {
            Assert-Condition ((Get-ProbeCase $response $legacyCase).Layout.State -ne 2) "Dpi=0 不应隐藏旧锚点：$legacyCase"
        }
        Assert-Condition ((Get-ProbeCase $response 'inside-top-expanded').Layout.ExpansionDirection -eq 0) 'InsideTopRight 必须向下展开。'
        Assert-Condition ((Get-ProbeCase $response 'inside-top-expanded').Layout.CapsuleBounds.Width -eq 196) '旧锚点双字段宽度不得改变。'
        Assert-Condition ((Get-ProbeCase $response 'inside-bottom-expanded').Layout.ExpansionDirection -eq 1) 'InsideBottomRight 必须向上展开。'

        $compressed = (Get-ProbeCase $response 'compressed-rows').Layout
        Assert-Condition ($compressed.State -eq 1 -and $compressed.ExpandedRowHeight -eq 29) '空间不足时行高应从 30 DIP 降至可容纳值。'
        $tooShort = (Get-ProbeCase $response 'insufficient-height').Layout
        Assert-Condition ($tooShort.State -eq 0 -and $tooShort.ExpandedRowHeight -eq 0) '不足 24 DIP 行高时请求应保持收起。'

        Assert-Condition ((Get-ProbeCase $response 'auto-right').Layout.WindowBounds.X -eq 1010) 'Auto 未优先选择窗口外右侧。'
        Assert-Condition ((Get-ProbeCase $response 'auto-left').Layout.WindowBounds.X -eq 714) 'Auto 右侧不足时未选择窗口外左侧。'
        Assert-Condition ((Get-ProbeCase $response 'auto-inside').Layout.WindowBounds.X -eq 1646) 'Auto 两侧不足时未回退 InsideTopRight。'
        Assert-Condition ((Get-ProbeCase $response 'auto-down').Layout.ExpansionDirection -eq 0) 'Auto 在下方空间充足时未向下展开。'
        Assert-Condition ((Get-ProbeCase $response 'auto-up').Layout.ExpansionDirection -eq 1) 'Auto 在下方不足且上方充足时未向上展开。'
    }

    if ($areas -contains 'Interaction') {
        $interactionCases = @(
            @{
                Name = 'open-release-outside-left'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 1; PointerInsideOverlay = $false }
                )
            },
            @{
                Name = 'capsule-click-while-expanded-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'CapsuleMouseUp' }
                )
            },
            @{
                Name = 'inside-left-right-middle-stay-expanded'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 1; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 2; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 4; PointerInsideOverlay = $true }
                )
            },
            @{
                Name = 'outside-right-edge-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 2; PointerInsideOverlay = $false }
                )
            },
            @{
                Name = 'outside-middle-edge-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 4; PointerInsideOverlay = $false }
                )
            },
            @{
                Name = 'held-button-does-not-repeat-edge'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 1; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 1; PointerInsideOverlay = $false },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $false },
                    @{ Operation = 'PointerSample'; PressedButtons = 1; PointerInsideOverlay = $false }
                )
            },
            @{
                Name = 'target-window-change-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'CollapseForHostChange' }
                )
            },
            @{
                Name = 'pinned-monitor-route-thread-change-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{
                        Operation = 'ObserveActiveRouteThread'
                        RouteThreadId = '11111111-1111-1111-1111-111111111111'
                        RouteActiveWindowCount = 1
                        RouteIsConnected = $true
                        RouteVersion = 10
                        RouteLastError = $null
                    },
                    @{ Operation = 'DataOnlyUpdate' },
                    @{
                        Operation = 'ObserveActiveRouteThread'
                        RouteThreadId = '22222222-2222-2222-2222-222222222222'
                        RouteActiveWindowCount = 1
                        RouteIsConnected = $true
                        RouteVersion = 11
                        RouteLastError = $null
                    }
                )
            },
            @{
                Name = 'route-metadata-only-change-stays-expanded'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{
                        Operation = 'ObserveActiveRouteThread'
                        RouteThreadId = '11111111-1111-1111-1111-111111111111'
                        RouteActiveWindowCount = 1
                        RouteIsConnected = $true
                        RouteVersion = 10
                        RouteLastError = $null
                    },
                    @{
                        Operation = 'ObserveActiveRouteThread'
                        RouteThreadId = '11111111-1111-1111-1111-111111111111'
                        RouteActiveWindowCount = 0
                        RouteIsConnected = $false
                        RouteVersion = 11
                        RouteLastError = 'pipe closed'
                    }
                )
            },
            @{
                Name = 'first-route-thread-baseline-stays-expanded'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{
                        Operation = 'ObserveActiveRouteThread'
                        RouteThreadId = $null
                        RouteActiveWindowCount = 0
                        RouteIsConnected = $false
                        RouteVersion = 0
                        RouteLastError = $null
                    },
                    @{
                        Operation = 'ObserveActiveRouteThread'
                        RouteThreadId = '11111111-1111-1111-1111-111111111111'
                        RouteActiveWindowCount = 1
                        RouteIsConnected = $true
                        RouteVersion = 1
                        RouteLastError = $null
                    }
                )
            },
            @{
                Name = 'active-thread-change-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'CollapseForHostChange' }
                )
            },
            @{
                Name = 'foreground-loss-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'CollapseForHostChange' }
                )
            },
            @{
                Name = 'minimization-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'CollapseForHostChange' }
                )
            },
            @{
                Name = 'expanded-layout-failure-collapses-before-relayout'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'CollapseForExpandedLayoutFailure' }
                )
            },
            @{
                Name = 'primary-only-does-not-collapse'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'DataOnlyUpdate' }
                )
            },
            @{
                Name = 'hide-and-restore-space'
                Events = @(
                    @{ Operation = 'HideForSpace' },
                    @{ Operation = 'RestoreAfterSpace' }
                )
            },
            @{
                Name = 'hidden-pointer-sample-waits-for-space-restore'
                Events = @(
                    @{ Operation = 'HideForSpace' },
                    @{ Operation = 'PointerSample'; PressedButtons = 1; PointerInsideOverlay = $false },
                    @{ Operation = 'RestoreAfterSpace' }
                )
            },
            @{
                Name = 'data-only-update-keeps-collapsed'
                Events = @(
                    @{ Operation = 'DataOnlyUpdate' }
                )
            }
        )

        $response = Invoke-JsonProbe '--interaction-probe' $interactionCases
        $expandedWaiting = @{ State = 1; Polling = $true; WaitingForRelease = $true; StateChanged = $true }
        $expanded = @{ State = 1; Polling = $true; WaitingForRelease = $false; StateChanged = $false }
        $collapsed = @{ State = 0; Polling = $false; WaitingForRelease = $false; StateChanged = $true }
        $collapsedUnchanged = @{ State = 0; Polling = $false; WaitingForRelease = $false; StateChanged = $false }
        $hidden = @{ State = 2; Polling = $false; WaitingForRelease = $false; StateChanged = $true }
        $hiddenUnchanged = @{ State = 2; Polling = $false; WaitingForRelease = $false; StateChanged = $false }

        Assert-InteractionTrace (Get-ProbeCase $response 'open-release-outside-left') @($expandedWaiting, $expanded, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'capsule-click-while-expanded-collapses') @($expandedWaiting, $expanded, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'inside-left-right-middle-stay-expanded') @($expandedWaiting, $expanded, $expanded, $expanded, $expanded, $expanded, $expanded)
        Assert-InteractionTrace (Get-ProbeCase $response 'outside-right-edge-collapses') @($expandedWaiting, $expanded, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'outside-middle-edge-collapses') @($expandedWaiting, $expanded, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'held-button-does-not-repeat-edge') @($expandedWaiting, $expanded, $expanded, $expanded, $expanded, $collapsed)
        $anchorState = Invoke-AnchorStateReflectionProbe
        Assert-Condition $anchorState.HasMainOnlyObserveMethod '锚点状态必须只公开 host 句柄和参考点的 ObserveAndCollapse 接口。'
        Assert-Condition (-not $anchorState.BoundsOnlyMovementStaysExpanded) '仅矩形移动不得改变锚点身份或收起。'
        Assert-Condition $anchorState.HostHandleChangeCollapses 'host 句柄变化必须收起。'
        Assert-Condition $anchorState.ReferencePointChangeCollapses '参考点变化必须收起。'
        Assert-InteractionTrace (Get-ProbeCase $response 'pinned-monitor-route-thread-change-collapses') @($expandedWaiting, $expanded, $expanded, $expanded, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'route-metadata-only-change-stays-expanded') @($expandedWaiting, $expanded, $expanded, $expanded)
        Assert-InteractionTrace (Get-ProbeCase $response 'first-route-thread-baseline-stays-expanded') @($expandedWaiting, $expanded, $expanded, $expanded)
        foreach ($hostChangeCase in @('target-window-change-collapses', 'active-thread-change-collapses', 'foreground-loss-collapses', 'minimization-collapses')) {
            Assert-InteractionTrace (Get-ProbeCase $response $hostChangeCase) @($expandedWaiting, $expanded, $collapsed)
        }
        Assert-InteractionTrace (Get-ProbeCase $response 'expanded-layout-failure-collapses-before-relayout') @($expandedWaiting, $expanded, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'primary-only-does-not-collapse') @($expandedWaiting, $expanded, $expanded)
        Assert-InteractionTrace (Get-ProbeCase $response 'hide-and-restore-space') @($hidden, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'hidden-pointer-sample-waits-for-space-restore') @($hidden, $hiddenUnchanged, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'data-only-update-keeps-collapsed') @($collapsedUnchanged)
    }

    if ($areas -contains 'Window') {
        $normalStyle = 0x240100
        $toolStyle = 0x2800A8
        $main = @{ Handle = 100; ProcessId = 10; IsCodexProcess = $true; IsVisible = $true; IsMinimized = $false; OwnerHandle = 0; ExtendedStyle = $normalStyle; Bounds = @{ X = 0; Y = 0; Width = 1500; Height = 1000 }; ClassName = 'Chrome_WidgetWin_1' }
        $tool = @{ Handle = 200; ProcessId = 10; IsCodexProcess = $true; IsVisible = $true; IsMinimized = $false; OwnerHandle = 0; ExtendedStyle = $toolStyle; Bounds = @{ X = 1250; Y = 350; Width = 410; Height = 400 }; ClassName = 'Chrome_WidgetWin_1' }
        $response = Invoke-JsonProbe '--window-classification-probe' @(
            @{ Name = 'foreground-host'; ForegroundHandle = 100; Candidates = @($main, $tool) },
            @{ Name = 'foreground-tool'; ForegroundHandle = 200; Candidates = @($main, $tool) },
            @{ Name = 'foreground-non-codex'; ForegroundHandle = 300; Candidates = @($main, $tool, @{ Handle = 300; ProcessId = 30; IsCodexProcess = $false; IsVisible = $true; IsMinimized = $false; OwnerHandle = 0; ExtendedStyle = $normalStyle; Bounds = @{ X = 0; Y = 0; Width = 1600; Height = 1000 }; ClassName = 'Chrome_WidgetWin_1' }) },
            @{ Name = 'largest-host-and-lowest-handle-tie'; ForegroundHandle = 100; Candidates = @(
                (Copy-WindowCandidate $main @{ Handle = 100; Bounds = @{ X = 0; Y = 0; Width = 1000; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 120; Bounds = @{ X = 0; Y = 0; Width = 1500; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 110; Bounds = @{ X = 0; Y = 0; Width = 1500; Height = 1000 } })
            ) },
            @{ Name = 'invalid-normal-candidates'; ForegroundHandle = 100; Candidates = @(
                $main,
                (Copy-WindowCandidate $main @{ Handle = 1; IsVisible = $false; Bounds = @{ X = 0; Y = 0; Width = 2000; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 2; IsMinimized = $true; Bounds = @{ X = 0; Y = 0; Width = 2000; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 3; OwnerHandle = 100; Bounds = @{ X = 0; Y = 0; Width = 2000; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 4; Bounds = @{ X = 0; Y = 0; Width = 499; Height = 4000 } }),
                (Copy-WindowCandidate $main @{ Handle = 5; Bounds = @{ X = 0; Y = 0; Width = 4000; Height = 399 } }),
                (Copy-WindowCandidate $main @{ Handle = 6; ClassName = 'Other_Window_Class'; Bounds = @{ X = 0; Y = 0; Width = 2000; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 7; ExtendedStyle = 0x80000; Bounds = @{ X = 0; Y = 0; Width = 2000; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 8; ExtendedStyle = 0x80; Bounds = @{ X = 0; Y = 0; Width = 2000; Height = 1000 } })
            ) }
        )

        $foregroundHost = Get-ProbeCase $response 'foreground-host'
        Assert-Condition ($foregroundHost.HostHandle -eq 100) '前景为主窗口时必须选择同进程主窗口。'
        $foregroundTool = Get-ProbeCase $response 'foreground-tool'
        Assert-Condition ($foregroundTool.HostHandle -eq 100) '前景为同进程工具/分层窗口时仍必须定位主窗口，且工具窗口不得成为返回目标。'
        $nonCodexForeground = Get-ProbeCase $response 'foreground-non-codex'
        Assert-Condition ($null -eq $nonCodexForeground.HostHandle) '非 Codex 前景窗口不得产生选择结果。'
        $tieBreaker = Get-ProbeCase $response 'largest-host-and-lowest-handle-tie'
        Assert-Condition ($tieBreaker.HostHandle -eq 110) '主窗口必须优先选择最大面积，并以最小句柄打破面积并列。'
        $invalidNormal = Get-ProbeCase $response 'invalid-normal-candidates'
        Assert-Condition ($invalidNormal.HostHandle -eq 100) '隐藏、最小化、有所有者、过小、工具/分层或错误类名的候选不得成为主窗口。'

        $surfaceContract = Invoke-HostSurfaceContractReflectionProbe
        $classificationFieldsAreHostOnly = (@($foregroundHost.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'HostHandle,Name'
        $selectionTypeIsHostOnly = (@($surfaceContract.SelectionProperties) -join ',') -eq 'Host'
        $targetTypeIsHostOnly = (@($surfaceContract.TargetProperties) -join ',') -eq 'HostWindow'
        $removedHandleField = 'P' + 'etHandle'
        $removedBoundsField = 'P' + 'etBounds'
        $diagnosticFieldsAreHostOnly = `
            (@($surfaceContract.DiagnosticProperties) -contains 'HostHandle') -and `
            (-not (@($surfaceContract.DiagnosticProperties) -contains $removedHandleField)) -and `
            (-not (@($surfaceContract.DiagnosticProperties) -contains $removedBoundsField))
        $zOrderCasesAvailable = `
            ($surfaceContract.IgnoredOverlayThenHost -eq 100) -and `
            ($surfaceContract.ToolBeforeHost -eq 200) -and `
            ($surfaceContract.OtherAppBeforeHost -eq 300) -and `
            ($null -eq $surfaceContract.EmptyAfterIgnoredOverlay)
        Assert-Condition `
            ([string]::IsNullOrEmpty($surfaceContract.Error) -and $classificationFieldsAreHostOnly -and $selectionTypeIsHostOnly -and $targetTypeIsHostOnly -and $diagnosticFieldsAreHostOnly -and $surfaceContract.HasKnownHostMethod -and $zOrderCasesAvailable) `
            "主窗口表面契约必须为 host-only，并由第一个未忽略的完整矩形顶层窗口阻断穿透。actual=$($surfaceContract | ConvertTo-Json -Compress -Depth 8)"
        Assert-Condition $surfaceContract.OwnShadowBeforeHostIsKnownHost `
            '状态条进程的 SysShadow 必须被跳过并命中 Codex 主窗口。'
        Assert-Condition $surfaceContract.HasCurrentProcessWrapper `
            '必须存在由生产命中链使用的当前进程包装器。'
        Assert-Condition (-not $surfaceContract.ForeignShadowBeforeHostIsKnownHost) `
            '其他进程的同形阴影窗口必须继续阻断。'
        Assert-Condition (-not $surfaceContract.CodexNonHostBeforeHostIsKnownHost) `
            'Codex 非主窗口必须继续阻断，不能恢复宠物吸附。'
        Assert-Condition $surfaceContract.OwnUnreadableBeforeHostIsKnownHost `
            '状态条进程的 unreadable 辅助窗口必须在 fail-closed 前跳过。'
        Assert-Condition (-not $surfaceContract.ForeignUnreadableBeforeHostIsKnownHost) `
            '其他进程的 unreadable 可见窗口必须继续 fail closed。'
        Assert-Condition (-not $surfaceContract.DestroyedForeignBeforeHostIsKnownHost) `
            '其他进程读取中销毁的候选必须继续 fail closed。'
        Assert-Condition (-not $surfaceContract.ZeroIgnoredProcessDoesNotSkip) `
            'ignoredProcessId=0 不得按进程穿透候选。'
        Assert-Condition $surfaceContract.ExplicitHandleStillSkippedWithZeroProcess `
            'ignoredProcessId=0 时显式忽略句柄仍必须生效。'
        $windowAssembly = [System.Reflection.Assembly]::LoadFrom($applicationDll)
        $windowLocatorType = $windowAssembly.GetType('CodexTokenOverlay.CodexWindowLocator', $true)
        $windowStaticFlags = [System.Reflection.BindingFlags]'Public, NonPublic, Static'
        $isPointOnKnownHost = $windowLocatorType.GetMethod('IsPointOnKnownHost', $windowStaticFlags)
        $currentProcessKnownHost = $windowLocatorType.GetMethod('IsUnderlyingWindowKnownHostForCurrentProcess', $windowStaticFlags)
        $productionPidWiring = `
            ($null -ne $isPointOnKnownHost) -and `
            ($null -ne $currentProcessKnownHost) -and `
            (Test-MethodCallChain `
                $isPointOnKnownHost `
                @($currentProcessKnownHost) `
                4)
        Assert-Condition `
            ($surfaceContract.HasCurrentProcessWrapper -and $surfaceContract.OwnShadowBeforeHostIsKnownHost -and $productionPidWiring) `
            '生产命中链必须调用经动态子进程 PID 行为验证的当前进程包装器。'
        Assert-Condition `
            (($null -ne $surfaceContract.VisibleInvalidBeforeHostIsKnownHost) -and (-not $surfaceContract.VisibleInvalidBeforeHostIsKnownHost) -and ($null -ne $surfaceContract.DestroyedDuringReadBeforeHostIsKnownHost) -and (-not $surfaceContract.DestroyedDuringReadBeforeHostIsKnownHost) -and $surfaceContract.RecoveredAfterCompleteReadsIsKnownHost -and $surfaceContract.InactiveInvalidBeforeHostIsKnownHost) `
            "可见表面矩形读取失败必须 fail closed；下一次完整读取以及 ignored/不可见/最小化失败不得永久阻断恢复。actual=$($surfaceContract | ConvertTo-Json -Compress -Depth 8)"

        $dpiAwareness = Invoke-WindowDpiAwarenessReflectionProbe
        Assert-Condition `
            ($dpiAwareness.DpiMode -eq 'PerMonitorV2') `
            "窗口探针必须在读取窗口指标前建立 PerMonitorV2 awareness。actual=$($dpiAwareness.DpiMode)"

        $knownRefresh = Invoke-KnownTargetRefreshReflectionProbe
        Assert-Condition $knownRefresh.RefreshWhileOverlayForeground.Success '已知目标刷新不得依赖当前前景窗口。'
        Assert-Condition ($knownRefresh.RefreshWhileOverlayForeground.HostHandle -eq 100) '已知目标刷新必须保持原 Codex 进程并返回当前主窗口。'
        Assert-Rect $knownRefresh.RefreshWhileOverlayForeground.HostBounds 40 60 1500 1000 '已知目标刷新必须返回主窗口最新矩形。'
        Assert-Condition (-not $knownRefresh.RejectProcessChange.Success) '已知目标刷新必须拒绝进程变化。'
        Assert-Condition (-not $knownRefresh.DestroyedHostFailsClosed.Success) '已销毁的原主窗口必须 fail closed。'
        Assert-Condition (-not $knownRefresh.ClassReadFailureAccepted) 'GetClassName 失败的候选必须 fail closed。'
        Assert-Condition (-not $knownRefresh.StyleReadFailureAccepted) '扩展样式读取报错的候选必须 fail closed。'
        Assert-Condition $knownRefresh.ZeroStyleWithoutErrorAccepted '扩展样式为零但无 Win32 错误时必须视为有效读取。'
        Assert-Condition $knownRefresh.SameConfirmedIdentityAccepted '相同确认 host+PID 必须允许已知目标刷新。'
        Assert-Condition (-not $knownRefresh.ReusedHandleDifferentProcessAccepted) '被其他进程复用的同 HWND 必须拒绝刷新。'
        Assert-Condition (-not $knownRefresh.DifferentHostSameProcessAccepted) '同进程但不同 host HWND 必须拒绝刷新。'
    }

    if ($areas -contains 'Form') {
        $form = Invoke-JsonProbe '--form-probe' @(
            @{
                Name = 'non-activating-window-contract'
                CollapsedLayout = @{
                    State = 0
                    CollapsedDisplay = 0
                    ExpansionDirection = 0
                    Dpi = 96
                    WindowBounds = @{ X = 1400; Y = 100; Width = 196; Height = 34 }
                    CapsuleBounds = @{ X = 0; Y = 0; Width = 196; Height = 34 }
                    PanelBounds = @{ X = 0; Y = 0; Width = 0; Height = 0 }
                    ExpandedRowHeight = 0
                    ScalePercent = 100
                }
                Collapsed60Layout = @{
                    State = 0
                    CollapsedDisplay = 0
                    ExpansionDirection = 0
                    Dpi = 96
                    WindowBounds = @{ X = 1400; Y = 100; Width = 118; Height = 20 }
                    CapsuleBounds = @{ X = 0; Y = 0; Width = 118; Height = 20 }
                    PanelBounds = @{ X = 0; Y = 0; Width = 0; Height = 0 }
                    ExpandedRowHeight = 0
                    ScalePercent = 60
                }
                Collapsed130Layout = @{
                    State = 0
                    CollapsedDisplay = 0
                    ExpansionDirection = 0
                    Dpi = 96
                    WindowBounds = @{ X = 1400; Y = 100; Width = 255; Height = 44 }
                    CapsuleBounds = @{ X = 0; Y = 0; Width = 255; Height = 44 }
                    PanelBounds = @{ X = 0; Y = 0; Width = 0; Height = 0 }
                    ExpandedRowHeight = 0
                    ScalePercent = 130
                }
                ExpandedLayout = @{
                    State = 1
                    CollapsedDisplay = 0
                    ExpansionDirection = 0
                    Dpi = 96
                    WindowBounds = @{ X = 1326; Y = 100; Width = 270; Height = 304 }
                    CapsuleBounds = @{ X = 74; Y = 0; Width = 196; Height = 34 }
                    PanelBounds = @{ X = 0; Y = 40; Width = 270; Height = 264 }
                    ExpandedRowHeight = 30
                    ScalePercent = 100
                }
            }
        )

        $contract = Get-ProbeCase $form 'non-activating-window-contract'
        Assert-Condition $contract.WsExToolWindowPresent 'TokenStripForm 必须设置 WS_EX_TOOLWINDOW。'
        Assert-Condition $contract.WsExNoActivatePresent 'TokenStripForm 必须设置 WS_EX_NOACTIVATE。'
        Assert-Condition (-not $contract.WsExTransparentPresent) 'TokenStripForm 不得设置 WS_EX_TRANSPARENT。'
        Assert-Condition $contract.CsDropShadowPresent 'TokenStripForm 应请求 CS_DROPSHADOW。'
        Assert-Condition ($contract.MouseActivateResult -eq 3) 'WM_MOUSEACTIVATE 必须返回 MA_NOACTIVATE。'
        Assert-Condition ($contract.CapsuleCenterHitTest -ne -1) '胶囊中心不得返回 HTTRANSPARENT。'
        Assert-Condition ($contract.PanelCenterHitTest -ne -1) '面板中心不得返回 HTTRANSPARENT。'
        Assert-Condition ($contract.TopLeftHitTest -eq -1) 'L 形左上切角必须返回 HTTRANSPARENT。'
        Assert-Rect $contract.CollapsedBounds 1400 100 196 34 '收起 ApplyLayout 必须匹配 WindowBounds。'
        Assert-Rect $contract.ExpandedBounds 1326 100 270 304 '展开 ApplyLayout 必须原子应用 WindowBounds。'
        Assert-Condition ($contract.ExpandedSetBoundsCoreDelta -eq 1) '展开 ApplyLayout 必须只产生一次 SetBoundsCore 调用。'
        Assert-Condition $contract.ExpandedRegionMatchesUnion '展开 Region 必须匹配圆角胶囊与面板并集。'
        Assert-Condition ($contract.NormalCapsuleClickCount -eq 1) '正常模式必须保留既有胶囊点击展开事件。'
        Assert-Condition (-not $contract.NormalCommandIntercepted) '正常模式不得拦截 Enter 或 Esc。'
        Assert-Condition (-not $contract.NormalRenderDecorations.ShowBorder) '普通模式不得绘制编辑边框。'
        Assert-Condition (-not $contract.NormalRenderDecorations.ShowDragHint) '普通模式不得绘制拖动提示。'
        Assert-Condition (-not $contract.NormalRenderDecorations.ShowResizeHandle) '普通模式不得绘制缩放手柄。'
        Assert-Condition $contract.BeginEditRejectsExpanded '编辑模式必须拒绝非收起布局。'
        Assert-Condition $contract.EditWsExToolWindowPresent '编辑模式仍必须设置 WS_EX_TOOLWINDOW。'
        Assert-Condition (-not $contract.EditWsExNoActivatePresent) '编辑模式必须临时移除 WS_EX_NOACTIVATE。'
        Assert-Condition ($contract.EditMouseActivateResult -ne 3) '编辑模式不得将 WM_MOUSEACTIVATE 强制返回 MA_NOACTIVATE。'
        Assert-Condition $contract.EditIsCollapsed '编辑模式必须保持收起布局。'
        Assert-Condition ($contract.EditCapsuleClickCount -eq 0) '编辑模式不得触发胶囊点击展开。'
        Assert-Rect $contract.EditResizeHandle60 111 13 7 7 '60% 编辑缩放柄必须为右下角 7px。'
        Assert-Rect $contract.EditResizeHandle100 184 22 12 12 '100% 编辑缩放柄必须为右下角 12px。'
        Assert-Rect $contract.EditResizeHandle130 239 28 16 16 '130% 编辑缩放柄必须为右下角 16px。'
        foreach ($decoration in @($contract.EditRenderDecorations60, $contract.EditRenderDecorations100, $contract.EditRenderDecorations130)) {
            Assert-Condition $decoration.ShowBorder '编辑模式必须绘制细边框。'
            Assert-Condition $decoration.ShowDragHint '编辑模式必须绘制拖动提示。'
            Assert-Condition $decoration.ShowResizeHandle '编辑模式必须绘制右下缩放手柄。'
            Assert-Condition (-not [string]::IsNullOrWhiteSpace($decoration.DragHintText)) '编辑拖动提示不得为空。'
        }
        Assert-Rect $contract.EditRenderDecorations60.DragHintBounds 6 0 94 20 '60% 拖动提示布局必须随统一指标缩放。'
        Assert-Rect $contract.EditRenderDecorations100.DragHintBounds 10 0 156 34 '100% 拖动提示布局必须使用胶囊内容区。'
        Assert-Rect $contract.EditRenderDecorations130.DragHintBounds 13 0 203 44 '130% 拖动提示布局必须随统一指标缩放。'
        Assert-Condition `
            ($contract.EditRenderDecorations60.DragHintFontPoints -eq 6.0 -and $contract.EditRenderDecorations100.DragHintFontPoints -eq 10.0 -and $contract.EditRenderDecorations130.DragHintFontPoints -eq 13.0) `
            '拖动提示字体必须由 OverlayRenderMetrics 缩放。'
        Assert-Condition ($contract.MovePreview.Kind -eq 0) '拖动模拟必须报告 Move。'
        Assert-Condition `
            ($contract.MovePreview.CursorScreen.X -eq 1528 -and $contract.MovePreview.CursorScreen.Y -eq 137) `
            '拖动预览必须报告真实屏幕光标。'
        Assert-Rect $contract.MovePreviewBounds 1430 120 196 34 '拖动预览只能按屏幕增量改变位置。'
        Assert-Condition $contract.MovePreservedSize '拖动预览不得改变大小。'
        Assert-Condition ($contract.MinimumResizePreview.Kind -eq 1) '缩放模拟必须报告 Resize。'
        Assert-Condition ($contract.MinimumResizePreview.ScalePercent -eq 60) '缩放预览必须精确钳制到 60%。'
        Assert-Condition ($contract.MaximumResizePreview.ScalePercent -eq 130) '缩放预览必须精确钳制到 130%。'
        Assert-Condition `
            ($contract.MinimumResizePreview.FixedTopLeft.X -eq 1400 -and $contract.MinimumResizePreview.FixedTopLeft.Y -eq 100) `
            '最小缩放必须保持固定左上角。'
        Assert-Condition `
            ($contract.MaximumResizePreview.FixedTopLeft.X -eq 1400 -and $contract.MaximumResizePreview.FixedTopLeft.Y -eq 100) `
            '最大缩放必须保持固定左上角。'
        foreach ($lostCapture in @($contract.LostMoveCapture, $contract.LostResizeCapture)) {
            Assert-Condition $lostCapture.ActiveBeforeInterruption '产生预览后手势必须仍处于活动状态。'
            Assert-Condition (-not $lostCapture.ActiveAfterInterruption) '外部 capture loss 必须释放手势状态。'
            Assert-Condition (-not $lostCapture.ActiveAfterRepeatedSignals) '重复 capture loss/MouseUp 不得重新激活或重复完成。'
            Assert-Condition (-not $lostCapture.CaptureAfterInterruption) '外部 capture loss 后窗体不得保留鼠标捕获。'
            Assert-Condition ($lostCapture.CompletionCount -eq 1) '外部 capture loss 必须恰好完成一次手势。'
            Assert-Condition ($lostCapture.Completed.Kind -eq $lostCapture.ExpectedKind) 'capture loss 完成事件必须保留手势类型。'
            Assert-Condition `
                ($lostCapture.Completed.CursorScreen.X -eq $lostCapture.Preview.CursorScreen.X -and $lostCapture.Completed.CursorScreen.Y -eq $lostCapture.Preview.CursorScreen.Y) `
                'capture loss 完成事件必须使用最后一次生产预览光标。'
            Assert-Condition ($lostCapture.Completed.ScalePercent -eq $lostCapture.Preview.ScalePercent) 'capture loss 完成事件必须保留最后一次生产预览缩放。'
        }
        Assert-Condition ($contract.LostMoveCapture.Completed.CursorScreen.X -eq 1529 -and $contract.LostMoveCapture.Completed.CursorScreen.Y -eq 136) 'Move capture loss 必须回报精确屏幕光标。'
        Assert-Condition ($contract.LostResizeCapture.Completed.CursorScreen.X -eq 1621 -and $contract.LostResizeCapture.Completed.CursorScreen.Y -eq 147) 'Resize capture loss 必须回报精确屏幕光标。'
        Assert-Condition ($contract.CancelCapture.CancelRequestCount -eq 1) 'Esc 取消路径必须触发一次取消请求。'
        Assert-Condition ($contract.CancelCapture.CompletionCount -eq 0) 'Esc/EndEditMode 不得产生虚假手势完成。'
        Assert-Condition (-not $contract.CancelCapture.ActiveAfterInterruption -and -not $contract.CancelCapture.CaptureAfterInterruption) 'Esc/EndEditMode 必须静默清理捕获和手势状态。'
        Assert-Condition ($contract.DisposeCapture.CompletionCount -eq 0) 'Dispose 不得产生虚假手势完成。'
        Assert-Condition (-not $contract.DisposeCapture.ActiveAfterInterruption -and -not $contract.DisposeCapture.CaptureAfterInterruption) 'Dispose 必须静默清理捕获和手势状态。'
        Assert-Condition ($contract.EditGestureCompletionCount -eq 3) '三次模拟手势必须各在鼠标释放时触发一次完成事件。'
        Assert-Condition ($contract.SaveRequestCount -eq 1) '编辑态 Enter 必须仅触发一次保存。'
        Assert-Condition ($contract.CancelRequestCount -eq 1) '编辑态 Esc 必须仅触发一次取消。'
        Assert-Condition $contract.RestoredWsExNoActivatePresent '结束编辑后必须恢复 WS_EX_NOACTIVATE。'
        Assert-Condition ($contract.RestoredMouseActivateResult -eq 3) '结束编辑后 WM_MOUSEACTIVATE 必须恢复 MA_NOACTIVATE。'

        Assert-Condition `
            ($contract.Metrics60.LabelFontPoints -eq 6.0 -and $contract.Metrics100.LabelFontPoints -eq 10.0 -and $contract.Metrics130.LabelFontPoints -eq 13.0) `
            '标签字体必须使用统一用户缩放因子。'
        Assert-Condition `
            ($contract.Metrics60.CompactValueFontPoints -eq 7.2 -and $contract.Metrics100.CompactValueFontPoints -eq 12.0 -and $contract.Metrics130.CompactValueFontPoints -eq 15.6) `
            '紧凑值字体必须使用统一用户缩放因子。'
        Assert-Condition `
            ($contract.Metrics60.PanelHeaderFontPoints -eq 7.8 -and $contract.Metrics100.PanelHeaderFontPoints -eq 13.0 -and $contract.Metrics130.PanelHeaderFontPoints -eq 16.9) `
            '面板标题字体必须使用统一用户缩放因子。'
        Assert-Condition `
            ($contract.Metrics60.HighlightedValueFontPoints -eq 9.0 -and $contract.Metrics100.HighlightedValueFontPoints -eq 15.0 -and $contract.Metrics130.HighlightedValueFontPoints -eq 19.5) `
            '高亮值字体必须使用统一用户缩放因子。'
        Assert-Condition `
            ($contract.Metrics60.CapsuleRadius -eq 6 -and $contract.Metrics100.CapsuleRadius -eq 10 -and $contract.Metrics130.CapsuleRadius -eq 13) `
            '胶囊圆角必须使用统一 DPI/用户缩放因子。'
        Assert-Condition `
            ($contract.Metrics60.PanelRadius -eq 8 -and $contract.Metrics100.PanelRadius -eq 14 -and $contract.Metrics130.PanelRadius -eq 18) `
            '面板圆角必须使用统一 DPI/用户缩放因子。'
        Assert-Condition `
            ($contract.Metrics60.HorizontalPadding -eq 6 -and $contract.Metrics100.HorizontalPadding -eq 10 -and $contract.Metrics130.HorizontalPadding -eq 13) `
            '水平内边距必须使用统一 DPI/用户缩放因子。'
        Assert-Condition `
            ($contract.Metrics60.MetricGap -eq 5 -and $contract.Metrics100.MetricGap -eq 8 -and $contract.Metrics130.MetricGap -eq 10) `
            '指标间距必须使用统一 DPI/用户缩放因子。'
        Assert-Condition `
            ($contract.Metrics60.DividerHeight -eq 8 -and $contract.Metrics100.DividerHeight -eq 14 -and $contract.Metrics130.DividerHeight -eq 18) `
            '分隔线必须使用统一 DPI/用户缩放因子。'
        Assert-Condition `
            ($contract.Metrics60.PanelPadding -eq 8 -and $contract.Metrics100.PanelPadding -eq 14 -and $contract.Metrics130.PanelPadding -eq 18) `
            '面板内边距必须使用统一 DPI/用户缩放因子。'
        Assert-Condition `
            ($contract.Metrics60.EditHandleSize -eq 7 -and $contract.Metrics100.EditHandleSize -eq 12 -and $contract.Metrics130.EditHandleSize -eq 16) `
            '编辑缩放柄必须使用统一 DPI/用户缩放因子。'

        Assert-Condition $contract.HighlightWsExToolWindowPresent '目标高亮必须设置 WS_EX_TOOLWINDOW。'
        Assert-Condition $contract.HighlightWsExNoActivatePresent '目标高亮必须设置 WS_EX_NOACTIVATE。'
        Assert-Condition $contract.HighlightWsExTransparentPresent '目标高亮必须设置 WS_EX_TRANSPARENT。'
        Assert-Condition (-not $contract.HighlightShowInTaskbar) '目标高亮不得出现在任务栏。'
        Assert-Condition ($contract.HighlightSetBoundsCoreDelta -eq 1) 'ShowTarget 必须仅用一次 SetBounds 更新目标边界。'
        Assert-Rect $contract.HighlightBounds 300 240 420 260 '目标高亮必须匹配目标窗口边界。'
        $expectedHighlightThickness = [Math]::Max(
            1,
            [int][Math]::Round(
                2 * $contract.HighlightDeviceDpi / 96.0,
                [MidpointRounding]::AwayFromZero))
        Assert-Condition `
            ($contract.HighlightExpectedRingThicknessPixels -eq $expectedHighlightThickness) `
            "目标高亮 2 DIP 环形宽度必须按当前 DPI 换算。dpi=$($contract.HighlightDeviceDpi) expected=$expectedHighlightThickness probe=$($contract.HighlightExpectedRingThicknessPixels)"
        Assert-Condition $contract.HighlightHasRingRegion '目标高亮必须使用精确 2 DIP 的四边环形 Region。'
        Assert-Condition ($contract.HighlightHitTest -eq -1) '目标高亮必须点击穿透。'
        Assert-Condition $contract.HighlightHiddenAfterClear 'ClearTarget 必须隐藏目标高亮。'
        Assert-Condition $contract.HighlightRegionCleared 'ClearTarget 必须释放并清空旧 Region。'
    }

    Write-Host "Overlay 逻辑测试通过：$($areas -join ', ')"
}
finally {
    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $isInsideTemporaryRoot = $resolvedTestRoot.StartsWith(
        $temporaryRoot,
        [StringComparison]::OrdinalIgnoreCase)
    $hasExpectedPrefix = (Split-Path -Leaf $resolvedTestRoot).StartsWith(
        'CodexTokenOverlayLogicTests-',
        [StringComparison]::Ordinal)
    if ($isInsideTemporaryRoot -and $hasExpectedPrefix) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
