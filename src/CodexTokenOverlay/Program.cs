using System.Collections.Concurrent;
using System.Buffers.Binary;
using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace CodexTokenOverlay;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        var sessionRoot = SessionPathResolver.Resolve(args);

        // IPC 探针用于验证 Codex 当前可见任务广播，不启动悬浮条。
        if (args.Length >= 2 && args[0].Equals("--ipc-probe", StringComparison.OrdinalIgnoreCase))
        {
            using var routeMonitor = new CodexIpcActiveThreadMonitor();
            var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(5);
            ActiveThreadRouteStatus status;
            do
            {
                Thread.Sleep(100);
                status = routeMonitor.GetStatus();
            }
            while (DateTime.UtcNow < deadline && string.IsNullOrWhiteSpace(status.ThreadId));

            var json = JsonSerializer.Serialize(status, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(args[1], json, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            return;
        }

        // 窗口探针用于验证当前交互桌面可见的 Codex 顶层窗口信息。
        if (args.Length >= 2 && args[0].Equals("--window-probe", StringComparison.OrdinalIgnoreCase))
        {
            var info = CodexWindowLocator.GetForegroundWindowProbe();
            var json = JsonSerializer.Serialize(info, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(args[1], json, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            return;
        }

        // 探针模式用于构建后验证真实会话日志，不启动任何界面。
        if (args.Length >= 2 && args[0].Equals("--probe", StringComparison.OrdinalIgnoreCase))
        {
            using var monitor = new TokenLogMonitor(sessionRoot);
            if (args.Length >= 3 && !args[2].StartsWith("--", StringComparison.Ordinal))
            {
                monitor.PreferredThreadId = args[2];
            }
            var snapshot = monitor.Poll(forceFullScan: true);
            var json = JsonSerializer.Serialize(snapshot, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(args[1], json, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            return;
        }

        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        using var singleInstanceMutex = new Mutex(
            initiallyOwned: true,
            name: "Local\\CodexTokenOverlay",
            createdNew: out var createdNew);
        if (!createdNew)
        {
            return;
        }

        Application.Run(new OverlayContext(sessionRoot));
        GC.KeepAlive(singleInstanceMutex);
    }
}

internal static class SessionPathResolver
{
    public static string Resolve(IReadOnlyList<string>? arguments = null)
    {
        if (arguments is not null)
        {
            for (var index = 0; index < arguments.Count - 1; index++)
            {
                if (arguments[index].Equals("--sessions", StringComparison.OrdinalIgnoreCase)
                    && !string.IsNullOrWhiteSpace(arguments[index + 1]))
                {
                    return Normalize(arguments[index + 1]);
                }
            }
        }

        var codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (string.IsNullOrWhiteSpace(codexHome))
        {
            codexHome = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".codex");
        }

        return Path.Combine(Normalize(codexHome), "sessions");
    }

    private static string Normalize(string path)
    {
        var expanded = Environment.ExpandEnvironmentVariables(path.Trim().Trim('"'));
        if (expanded.Equals("~", StringComparison.Ordinal)
            || expanded.StartsWith($"~{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
        {
            expanded = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                expanded.Length == 1 ? string.Empty : expanded[2..]);
        }

        return Path.GetFullPath(expanded);
    }
}

internal sealed record TokenSnapshot(
    string ThreadId,
    string LogPath,
    long TotalTokens,
    long InputTokens,
    long CachedInputTokens,
    long OutputTokens,
    long ReasoningOutputTokens,
    long ContextUsedTokens,
    long ContextWindowTokens,
    DateTime UpdatedAtUtc)
{
    public double ContextPercent => ContextWindowTokens <= 0
        ? 0
        : Math.Clamp(ContextUsedTokens * 100d / ContextWindowTokens, 0, 100);

    public long UncachedInputTokens => Math.Max(0, InputTokens - CachedInputTokens);
}

internal sealed record ActiveThreadRouteStatus(
    string? ThreadId,
    int ActiveWindowCount,
    bool IsConnected,
    long Version,
    string? LastError);

internal sealed class CodexIpcActiveThreadMonitor : IDisposable
{
    private const int MaximumWireFrameBytes = 256 * 1024 * 1024;
    private const int MaximumJsonFrameBytes = 4 * 1024 * 1024;
    private readonly object _sync = new();
    private readonly CancellationTokenSource _cancellation = new();
    private readonly Dictionary<string, ActiveConversation> _activeByWindow = new(StringComparer.Ordinal);
    private readonly Task _runner;
    private string? _activeThreadId;
    private string? _lastError;
    private bool _isConnected;
    private long _sequence;
    private long _version;

    public CodexIpcActiveThreadMonitor()
    {
        _runner = Task.Run(() => RunAsync(_cancellation.Token));
    }

    public ActiveThreadRouteStatus GetStatus()
    {
        lock (_sync)
        {
            return new ActiveThreadRouteStatus(
                _activeThreadId,
                _activeByWindow.Count,
                _isConnected,
                _version,
                _lastError);
        }
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        var retryDelay = TimeSpan.FromMilliseconds(350);

        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                using var pipe = new NamedPipeClientStream(
                    ".",
                    "codex-ipc",
                    PipeDirection.InOut,
                    PipeOptions.Asynchronous);

                await pipe.ConnectAsync(2500, cancellationToken).ConfigureAwait(false);
                MarkConnected();
                retryDelay = TimeSpan.FromMilliseconds(350);
                await SendInitializeAsync(pipe, cancellationToken).ConfigureAwait(false);

                while (!cancellationToken.IsCancellationRequested && pipe.IsConnected)
                {
                    var prefix = new byte[sizeof(uint)];
                    if (!await ReadExactlyAsync(pipe, prefix, cancellationToken).ConfigureAwait(false))
                    {
                        break;
                    }

                    var frameLength = BinaryPrimitives.ReadUInt32LittleEndian(prefix);
                    if (frameLength == 0 || frameLength > MaximumWireFrameBytes)
                    {
                        throw new InvalidDataException($"Codex IPC 帧长度无效：{frameLength}");
                    }

                    if (frameLength > MaximumJsonFrameBytes)
                    {
                        await DrainExactlyAsync(pipe, frameLength, cancellationToken).ConfigureAwait(false);
                        continue;
                    }

                    var payload = new byte[(int)frameLength];
                    if (!await ReadExactlyAsync(pipe, payload, cancellationToken).ConfigureAwait(false))
                    {
                        break;
                    }
                    try
                    {
                        ProcessFrame(payload);
                    }
                    catch (Exception exception) when (exception is JsonException or InvalidOperationException)
                    {
                        // 单个未知或不完整消息不应终止整个 IPC 监听。
                    }
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException or JsonException or InvalidOperationException or TimeoutException)
            {
                MarkDisconnected(exception.Message);
            }

            MarkDisconnected(null);
            try
            {
                await Task.Delay(retryDelay, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            retryDelay = TimeSpan.FromMilliseconds(Math.Min(5000, retryDelay.TotalMilliseconds * 2));
        }
    }

    private static async Task SendInitializeAsync(Stream pipe, CancellationToken cancellationToken)
    {
        var request = new
        {
            type = "request",
            requestId = Guid.NewGuid().ToString(),
            sourceClientId = "initializing-client",
            version = 0,
            method = "initialize",
            @params = new { clientType = "codex-token-overlay" }
        };
        var payload = JsonSerializer.SerializeToUtf8Bytes(request);
        var prefix = new byte[sizeof(uint)];
        BinaryPrimitives.WriteUInt32LittleEndian(prefix, (uint)payload.Length);
        await pipe.WriteAsync(prefix.AsMemory(), cancellationToken).ConfigureAwait(false);
        await pipe.WriteAsync(payload.AsMemory(), cancellationToken).ConfigureAwait(false);
        await pipe.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private void ProcessFrame(byte[] payload)
    {
        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;
        if (!root.TryGetProperty("type", out var type)
            || type.ValueKind != JsonValueKind.String
            || type.GetString() != "broadcast"
            || !root.TryGetProperty("method", out var method)
            || method.ValueKind != JsonValueKind.String
            || !root.TryGetProperty("params", out var parameters)
            || parameters.ValueKind != JsonValueKind.Object)
        {
            return;
        }

        var methodName = method.GetString();
        if (methodName == "client-status-changed")
        {
            ProcessClientStatusChanged(parameters);
            return;
        }

        if (methodName != "thread-stream-following-changed"
            || !parameters.TryGetProperty("conversationId", out var conversationIdElement)
            || !parameters.TryGetProperty("hostId", out var hostIdElement)
            || !parameters.TryGetProperty("following", out var followingElement)
            || conversationIdElement.ValueKind != JsonValueKind.String
            || hostIdElement.ValueKind != JsonValueKind.String
            || followingElement.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            return;
        }

        var conversationId = conversationIdElement.GetString();
        var hostId = hostIdElement.GetString();
        var sourceClientId = root.TryGetProperty("sourceClientId", out var sourceElement)
            && sourceElement.ValueKind == JsonValueKind.String
            ? sourceElement.GetString()
            : null;
        if (string.IsNullOrWhiteSpace(conversationId)
            || string.IsNullOrWhiteSpace(hostId)
            || string.IsNullOrWhiteSpace(sourceClientId))
        {
            return;
        }

        var key = $"{sourceClientId}\u001f{hostId}";
        lock (_sync)
        {
            if (followingElement.GetBoolean())
            {
                _activeByWindow[key] = new ActiveConversation(conversationId, ++_sequence);
            }
            else if (_activeByWindow.TryGetValue(key, out var active)
                && active.ThreadId.Equals(conversationId, StringComparison.OrdinalIgnoreCase))
            {
                _activeByWindow.Remove(key);
            }
            RecomputeActiveThread();
        }
    }

    private void ProcessClientStatusChanged(JsonElement parameters)
    {
        if (!parameters.TryGetProperty("status", out var statusElement)
            || statusElement.ValueKind != JsonValueKind.String
            || statusElement.GetString() != "disconnected"
            || !parameters.TryGetProperty("clientId", out var clientIdElement)
            || clientIdElement.ValueKind != JsonValueKind.String)
        {
            return;
        }

        var clientId = clientIdElement.GetString();
        if (string.IsNullOrWhiteSpace(clientId))
        {
            return;
        }

        var keyPrefix = $"{clientId}\u001f";
        lock (_sync)
        {
            foreach (var key in _activeByWindow.Keys
                .Where(key => key.StartsWith(keyPrefix, StringComparison.Ordinal))
                .ToArray())
            {
                _activeByWindow.Remove(key);
            }
            RecomputeActiveThread();
        }
    }

    private void MarkConnected()
    {
        lock (_sync)
        {
            _activeByWindow.Clear();
            _activeThreadId = null;
            _lastError = null;
            _isConnected = true;
            _version++;
        }
    }

    private void MarkDisconnected(string? error)
    {
        lock (_sync)
        {
            var changed = _isConnected || _activeByWindow.Count > 0 || _activeThreadId is not null;
            _isConnected = false;
            _activeByWindow.Clear();
            _activeThreadId = null;
            if (!string.IsNullOrWhiteSpace(error))
            {
                _lastError = error;
            }
            if (changed)
            {
                _version++;
            }
        }
    }

    private void RecomputeActiveThread()
    {
        var nextThreadId = _activeByWindow.Values
            .OrderByDescending(item => item.Sequence)
            .Select(item => item.ThreadId)
            .FirstOrDefault();
        if (!string.Equals(nextThreadId, _activeThreadId, StringComparison.OrdinalIgnoreCase))
        {
            _activeThreadId = nextThreadId;
            _version++;
        }
    }

    private static async Task<bool> ReadExactlyAsync(Stream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return false;
            }
            offset += read;
        }
        return true;
    }

    private static async Task DrainExactlyAsync(Stream stream, uint bytesToDrain, CancellationToken cancellationToken)
    {
        var buffer = new byte[64 * 1024];
        var remaining = (long)bytesToDrain;
        while (remaining > 0)
        {
            var requested = (int)Math.Min(buffer.Length, remaining);
            var read = await stream.ReadAsync(buffer.AsMemory(0, requested), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                throw new EndOfStreamException("Codex IPC 在完整帧到达前关闭。");
            }
            remaining -= read;
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }
        _cancellation.Cancel();
        try
        {
            _runner.Wait(TimeSpan.FromSeconds(2));
        }
        catch (AggregateException)
        {
            // 退出时取消后台读取属于正常流程。
        }
        _cancellation.Dispose();
    }

    private int _disposed;
    private sealed record ActiveConversation(string ThreadId, long Sequence);
}

internal sealed class TokenLogMonitor : IDisposable
{
    private const int TailBytes = 4 * 1024 * 1024;
    private const int HistoricalOverlapBytes = 256 * 1024;
    private readonly string _sessionRoot;
    private readonly FileSystemWatcher? _watcher;
    private readonly ConcurrentQueue<string> _changedPaths = new();
    private readonly ConcurrentDictionary<string, bool> _rootSessionCache = new(StringComparer.OrdinalIgnoreCase);
    private string? _activeLogPath;
    private DateTime _activeWriteUtc;
    private DateTime _lastFullScanUtc = DateTime.MinValue;
    private TokenSnapshot? _lastSnapshot;
    private string? _selectedThreadId;

    public long ActiveSessionVersion { get; private set; }

    public string? ActiveThreadId => _selectedThreadId;

    public string? PreferredThreadId { get; set; }

    public TokenLogMonitor(string? sessionRoot = null)
    {
        _sessionRoot = sessionRoot ?? SessionPathResolver.Resolve();

        if (!Directory.Exists(_sessionRoot))
        {
            return;
        }

        _watcher = new FileSystemWatcher(_sessionRoot, "*.jsonl")
        {
            IncludeSubdirectories = true,
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.CreationTime | NotifyFilters.Size,
            EnableRaisingEvents = true
        };
        _watcher.Changed += OnLogChanged;
        _watcher.Created += OnLogChanged;
        _watcher.Renamed += (_, eventArgs) => _changedPaths.Enqueue(eventArgs.FullPath);
    }

    public bool PinActiveSession { get; set; }

    public TokenSnapshot? Poll(bool forceFullScan = false)
    {
        if (!Directory.Exists(_sessionRoot))
        {
            return null;
        }

        var usePreferredThread = !PinActiveSession && !string.IsNullOrWhiteSpace(PreferredThreadId);
        ProcessChangedPaths(allowAutomaticSwitch: !usePreferredThread);

        if (usePreferredThread)
        {
            SelectPreferredRootSession(PreferredThreadId!);
        }
        else if (forceFullScan || _activeLogPath is null || DateTime.UtcNow - _lastFullScanUtc > TimeSpan.FromSeconds(20))
        {
            SelectNewestRootSession();
        }

        if (_activeLogPath is null || !File.Exists(_activeLogPath))
        {
            return _lastSnapshot;
        }

        DateTime writeUtc;
        try
        {
            writeUtc = File.GetLastWriteTimeUtc(_activeLogPath);
        }
        catch (IOException)
        {
            return _lastSnapshot;
        }

        if (_lastSnapshot is not null && writeUtc == _activeWriteUtc)
        {
            return _lastSnapshot;
        }

        var parsed = TryReadLatestTokenSnapshot(_activeLogPath, writeUtc);
        if (parsed is not null)
        {
            // 只有完整解析成功后才提交文件版本，避免卡在写到一半的 JSON 行。
            _activeWriteUtc = writeUtc;
            _lastSnapshot = parsed;
        }

        return _lastSnapshot;
    }

    private void OnLogChanged(object sender, FileSystemEventArgs eventArgs)
    {
        _changedPaths.Enqueue(eventArgs.FullPath);
    }

    private void ProcessChangedPaths(bool allowAutomaticSwitch)
    {
        var newestPath = _activeLogPath;
        var newestWriteUtc = _activeLogPath is null ? DateTime.MinValue : SafeGetLastWriteUtc(_activeLogPath);
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        while (_changedPaths.TryDequeue(out var path))
        {
            if (!allowAutomaticSwitch)
            {
                continue;
            }

            if (PinActiveSession
                && _activeLogPath is not null
                && !path.Equals(_activeLogPath, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (!visited.Add(path) || !File.Exists(path) || !IsRootDesktopSession(path))
            {
                continue;
            }

            var writeUtc = SafeGetLastWriteUtc(path);
            if (writeUtc >= newestWriteUtc)
            {
                newestPath = path;
                newestWriteUtc = writeUtc;
            }
        }

        if (newestPath is not null && !newestPath.Equals(_activeLogPath, StringComparison.OrdinalIgnoreCase))
        {
            SwitchActiveLog(newestPath);
        }
    }

    private void SelectPreferredRootSession(string threadId)
    {
        if (_selectedThreadId?.Equals(threadId, StringComparison.OrdinalIgnoreCase) == true
            && _activeLogPath is not null
            && File.Exists(_activeLogPath))
        {
            return;
        }

        try
        {
            var searchPattern = $"*{threadId}.jsonl";
            var candidate = Directory.EnumerateFiles(_sessionRoot, searchPattern, SearchOption.AllDirectories)
                .Where(IsRootDesktopSession)
                .OrderByDescending(SafeGetLastWriteUtc)
                .FirstOrDefault();

            SwitchActiveLog(candidate, threadId);
        }
        catch (IOException)
        {
            SwitchActiveLog(null, threadId);
        }
        catch (UnauthorizedAccessException)
        {
            SwitchActiveLog(null, threadId);
        }
        catch (ArgumentException)
        {
            // IPC 会话 ID 理论上是 UUID；异常输入只显示等待状态。
            SwitchActiveLog(null, threadId);
        }
    }

    private void SelectNewestRootSession()
    {
        _lastFullScanUtc = DateTime.UtcNow;

        if (PinActiveSession && _activeLogPath is not null && File.Exists(_activeLogPath))
        {
            return;
        }

        try
        {
            var candidates = Directory.EnumerateFiles(_sessionRoot, "*.jsonl", SearchOption.AllDirectories)
                .Select(path => new { Path = path, WriteUtc = SafeGetLastWriteUtc(path) })
                .OrderByDescending(item => item.WriteUtc);

            foreach (var candidate in candidates)
            {
                if (!IsRootDesktopSession(candidate.Path))
                {
                    continue;
                }

                if (!_activeLogPath?.Equals(candidate.Path, StringComparison.OrdinalIgnoreCase) ?? true)
                {
                    SwitchActiveLog(candidate.Path, ExtractThreadId(candidate.Path));
                }
                return;
            }
        }
        catch (IOException)
        {
            // Codex 正在轮转日志时，下一个轮询周期会重试。
        }
        catch (UnauthorizedAccessException)
        {
            // 个别旧目录不可读时保留上一次成功结果。
        }
    }

    private bool IsRootDesktopSession(string path)
    {
        if (_rootSessionCache.TryGetValue(path, out var cached))
        {
            return cached;
        }

        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true, bufferSize: 64 * 1024);
            var firstLine = reader.ReadLine();
            if (string.IsNullOrWhiteSpace(firstLine))
            {
                // Created 事件可能早于 Codex 写完首行，不能把暂时失败永久缓存。
                return false;
            }

            using var document = JsonDocument.Parse(firstLine);
            var root = document.RootElement;
            if (!root.TryGetProperty("type", out var type) || type.GetString() != "session_meta")
            {
                _rootSessionCache[path] = false;
                return false;
            }

            if (!root.TryGetProperty("payload", out var payload))
            {
                _rootSessionCache[path] = false;
                return false;
            }

            if (!payload.TryGetProperty("originator", out var originator)
                || originator.ValueKind != JsonValueKind.String
                || !string.Equals(originator.GetString(), "Codex Desktop", StringComparison.OrdinalIgnoreCase))
            {
                _rootSessionCache[path] = false;
                return false;
            }

            // Desktop 根会话首行固定为 source="vscode"；子代理后续会重放父会话，
            // 因此必须只检查第一物理行并严格匹配字符串，不能搜索整份文件。
            var isRoot = payload.TryGetProperty("source", out var source)
                && source.ValueKind == JsonValueKind.String
                && string.Equals(source.GetString(), "vscode", StringComparison.OrdinalIgnoreCase);
            _rootSessionCache[path] = isRoot;
            return isRoot;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            // 首行可能仍在写入；不缓存失败，下次 Changed 或全扫描会重试。
            return false;
        }
    }

    private void SwitchActiveLog(string? path, string? threadId = null)
    {
        threadId ??= path is null ? null : ExtractThreadId(path);
        if (string.Equals(_activeLogPath, path, StringComparison.OrdinalIgnoreCase)
            && string.Equals(_selectedThreadId, threadId, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        _activeLogPath = path;
        _selectedThreadId = threadId;
        _activeWriteUtc = DateTime.MinValue;
        _lastSnapshot = null;
        ActiveSessionVersion++;
    }

    private static TokenSnapshot? TryReadLatestTokenSnapshot(string path, DateTime writeUtc)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var blockEnd = stream.Length;

            while (blockEnd > 0)
            {
                var blockStart = Math.Max(0, blockEnd - TailBytes);
                var bytesToRead = (int)(blockEnd - blockStart);
                var buffer = new byte[bytesToRead];
                stream.Seek(blockStart, SeekOrigin.Begin);
                var offset = 0;
                while (offset < bytesToRead)
                {
                    var read = stream.Read(buffer, offset, bytesToRead - offset);
                    if (read == 0)
                    {
                        break;
                    }
                    offset += read;
                }

                var text = Encoding.UTF8.GetString(buffer, 0, offset);
                if (blockStart > 0)
                {
                    // 当前块可能从一行中间开始；下一块会以重叠区补齐这行。
                    var firstNewLine = text.IndexOf('\n');
                    text = firstNewLine >= 0 ? text[(firstNewLine + 1)..] : string.Empty;
                }

                var parsed = TryParseLatestTokenSnapshot(text, path, writeUtc);
                if (parsed is not null)
                {
                    return parsed;
                }

                if (blockStart == 0)
                {
                    break;
                }
                blockEnd = Math.Min(stream.Length, blockStart + HistoricalOverlapBytes);
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            // 日志可能正写到一半；保留上一帧，下一次更新会再次解析。
        }

        return null;
    }

    private static TokenSnapshot? TryParseLatestTokenSnapshot(string text, string path, DateTime writeUtc)
    {
        var lines = text.Split('\n');

        for (var index = lines.Length - 1; index >= 0; index--)
        {
            var line = lines[index].Trim();
            if (line.Length == 0 || !line.Contains("\"token_count\"", StringComparison.Ordinal))
            {
                continue;
            }

            try
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (!root.TryGetProperty("type", out var eventType)
                    || eventType.ValueKind != JsonValueKind.String
                    || eventType.GetString() != "event_msg")
                {
                    continue;
                }

                if (!root.TryGetProperty("payload", out var payload)
                    || payload.ValueKind != JsonValueKind.Object
                    || !payload.TryGetProperty("type", out var payloadType)
                    || payloadType.ValueKind != JsonValueKind.String
                    || payloadType.GetString() != "token_count"
                    || !payload.TryGetProperty("info", out var info)
                    || info.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                if (!info.TryGetProperty("total_token_usage", out var total)
                    || total.ValueKind != JsonValueKind.Object
                    || !info.TryGetProperty("last_token_usage", out var last)
                    || last.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                var threadId = ExtractThreadId(path);
                return new TokenSnapshot(
                    threadId,
                    path,
                    GetLong(total, "total_tokens"),
                    GetLong(total, "input_tokens"),
                    GetLong(total, "cached_input_tokens"),
                    GetLong(total, "output_tokens"),
                    GetLong(total, "reasoning_output_tokens"),
                    GetLong(last, "total_tokens"),
                    GetLong(info, "model_context_window"),
                    writeUtc);
            }
            catch (Exception exception) when (exception is JsonException or InvalidOperationException)
            {
                // Codex 可能正在追加最后一行；继续寻找前一个完整快照。
            }
        }

        return null;
    }

    private static long GetLong(JsonElement element, string propertyName)
    {
        return element.TryGetProperty(propertyName, out var property) && property.TryGetInt64(out var value)
            ? value
            : 0;
    }

    private static string ExtractThreadId(string path)
    {
        var fileName = Path.GetFileNameWithoutExtension(path);
        return fileName.Length >= 36 ? fileName[^36..] : fileName;
    }

    private static DateTime SafeGetLastWriteUtc(string path)
    {
        try
        {
            return File.GetLastWriteTimeUtc(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return DateTime.MinValue;
        }
    }

    public void Dispose()
    {
        _watcher?.Dispose();
    }
}

internal enum AnchorMode
{
    Auto,
    InsideTopRight,
    InsideBottomRight
}

[Flags]
internal enum DisplayField
{
    None = 0,
    Total = 1 << 0,
    Input = 1 << 1,
    Output = 1 << 2,
    CacheHit = 1 << 3,
    CacheMiss = 1 << 4,
    Context = 1 << 5,
    ContextPercent = 1 << 6,
    Reasoning = 1 << 7,
    Thread = 1 << 8
}

internal sealed class OverlaySettings
{
    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "CodexTokenOverlay",
        "settings.json");

    public AnchorMode AnchorMode { get; set; } = AnchorMode.Auto;

    public DisplayField VisibleFields { get; set; } =
        DisplayField.Total
        | DisplayField.Input
        | DisplayField.Output
        | DisplayField.CacheHit
        | DisplayField.CacheMiss
        | DisplayField.Context
        | DisplayField.ContextPercent;

    public static OverlaySettings Load()
    {
        try
        {
            if (!File.Exists(SettingsPath))
            {
                return new OverlaySettings();
            }

            var json = File.ReadAllText(SettingsPath, Encoding.UTF8);
            var settings = JsonSerializer.Deserialize<OverlaySettings>(json) ?? new OverlaySettings();
            if (settings.VisibleFields == DisplayField.None)
            {
                settings.VisibleFields = DisplayField.Total;
            }
            return settings;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return new OverlaySettings();
        }
    }

    public void Save()
    {
        try
        {
            var directory = Path.GetDirectoryName(SettingsPath)!;
            Directory.CreateDirectory(directory);
            var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(SettingsPath, json, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // 设置保存失败不影响状态条继续显示。
        }
    }
}

internal sealed class OverlayContext : ApplicationContext
{
    private readonly OverlaySettings _settings;
    private readonly CodexIpcActiveThreadMonitor _routeMonitor = new();
    private readonly TokenLogMonitor _monitor;
    private readonly TokenStripForm _form = new();
    private readonly NotifyIcon _trayIcon;
    private readonly System.Windows.Forms.Timer _timer;
    private readonly ToolStripMenuItem _sessionMenuItem;
    private readonly ToolStripMenuItem _visibilityMenuItem;
    private readonly ToolStripMenuItem _pinSessionMenuItem;
    private readonly Dictionary<AnchorMode, ToolStripMenuItem> _anchorItems = new();
    private readonly Dictionary<DisplayField, ToolStripMenuItem> _fieldItems = new();
    private TokenSnapshot? _lastSnapshot;
    private AnchorMode _anchorMode;
    private DisplayField _visibleFields;
    private bool _manuallyHidden;
    private int _pollInFlight;
    private TokenSnapshot? _pendingSnapshot;
    private long _pendingSessionVersion = -1;
    private string? _pendingThreadId;
    private long _observedSessionVersion = -1;
    private ActiveThreadRouteStatus _pendingRouteStatus = new(null, 0, false, 0, null);
    private long _observedRouteVersion = -1;

    public OverlayContext(string sessionRoot)
    {
        _monitor = new TokenLogMonitor(sessionRoot);
        _settings = OverlaySettings.Load();
        _anchorMode = _settings.AnchorMode;
        _visibleFields = _settings.VisibleFields;

        var menu = new ContextMenuStrip();
        _sessionMenuItem = new ToolStripMenuItem("会话：等待数据") { Enabled = false };
        menu.Items.Add(_sessionMenuItem);
        _pinSessionMenuItem = new ToolStripMenuItem("锁定当前会话") { Enabled = false, CheckOnClick = true };
        _pinSessionMenuItem.CheckedChanged += (_, _) =>
        {
            _monitor.PinActiveSession = _pinSessionMenuItem.Checked;
            _pinSessionMenuItem.Text = _pinSessionMenuItem.Checked ? "已锁定当前会话" : "锁定当前会话";
        };
        menu.Items.Add(_pinSessionMenuItem);
        menu.Items.Add(new ToolStripSeparator());

        AddAnchorMenu(menu, "自动吸附", AnchorMode.Auto);
        AddAnchorMenu(menu, "窗口内右上", AnchorMode.InsideTopRight);
        AddAnchorMenu(menu, "窗口内右下", AnchorMode.InsideBottomRight);
        menu.Items.Add(new ToolStripSeparator());

        var fieldsMenu = new ToolStripMenuItem("显示字段");
        AddFieldMenu(fieldsMenu, "总 token", DisplayField.Total);
        AddFieldMenu(fieldsMenu, "输入 token", DisplayField.Input);
        AddFieldMenu(fieldsMenu, "输出 token", DisplayField.Output);
        AddFieldMenu(fieldsMenu, "缓存命中", DisplayField.CacheHit);
        AddFieldMenu(fieldsMenu, "缓存未命中（推导）", DisplayField.CacheMiss);
        AddFieldMenu(fieldsMenu, "上下文用量", DisplayField.Context);
        AddFieldMenu(fieldsMenu, "上下文百分比", DisplayField.ContextPercent);
        AddFieldMenu(fieldsMenu, "推理输出", DisplayField.Reasoning);
        AddFieldMenu(fieldsMenu, "会话 ID", DisplayField.Thread);
        menu.Items.Add(fieldsMenu);
        menu.Items.Add(new ToolStripSeparator());

        _visibilityMenuItem = new ToolStripMenuItem("暂时隐藏");
        _visibilityMenuItem.Click += (_, _) =>
        {
            _manuallyHidden = !_manuallyHidden;
            _visibilityMenuItem.Text = _manuallyHidden ? "恢复显示" : "暂时隐藏";
            if (_manuallyHidden)
            {
                _form.Hide();
            }
        };
        menu.Items.Add(_visibilityMenuItem);

        var exitItem = new ToolStripMenuItem("退出");
        exitItem.Click += (_, _) => ExitOverlay();
        menu.Items.Add(exitItem);

        _trayIcon = new NotifyIcon
        {
            Icon = SystemIcons.Information,
            Text = "Codex Token 状态条",
            Visible = true,
            ContextMenuStrip = menu
        };

        _form.UpdateWaitingState("正在寻找当前 Codex 会话…");
        UpdateAnchorChecks();
        UpdateFieldChecks();

        _timer = new System.Windows.Forms.Timer { Interval = 350 };
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
    }

    private void AddAnchorMenu(ContextMenuStrip menu, string text, AnchorMode mode)
    {
        var item = new ToolStripMenuItem(text);
        item.Click += (_, _) =>
        {
            _anchorMode = mode;
            _settings.AnchorMode = mode;
            _settings.Save();
            UpdateAnchorChecks();
        };
        _anchorItems[mode] = item;
        menu.Items.Add(item);
    }

    private void AddFieldMenu(ToolStripMenuItem parent, string text, DisplayField field)
    {
        var item = new ToolStripMenuItem(text) { CheckOnClick = false };
        item.Click += (_, _) =>
        {
            var updated = _visibleFields.HasFlag(field)
                ? _visibleFields & ~field
                : _visibleFields | field;
            if (updated == DisplayField.None)
            {
                return;
            }

            _visibleFields = updated;
            _settings.VisibleFields = updated;
            _settings.Save();
            UpdateFieldChecks();
            if (_lastSnapshot is not null)
            {
                _form.UpdateSnapshot(_lastSnapshot, _visibleFields);
            }
        };
        _fieldItems[field] = item;
        parent.DropDownItems.Add(item);
    }

    private void UpdateAnchorChecks()
    {
        foreach (var pair in _anchorItems)
        {
            pair.Value.Checked = pair.Key == _anchorMode;
        }
    }

    private void UpdateFieldChecks()
    {
        foreach (var pair in _fieldItems)
        {
            pair.Value.Checked = _visibleFields.HasFlag(pair.Key);
        }
    }

    private void Tick()
    {
        RequestBackgroundPoll();

        if (_pendingRouteStatus.Version != _observedRouteVersion)
        {
            _observedRouteVersion = _pendingRouteStatus.Version;
            if (_lastSnapshot is not null)
            {
                _sessionMenuItem.Text = $"会话：{ShortThreadId(_lastSnapshot.ThreadId)}{RouteStatusSuffix(_pendingRouteStatus)}";
            }
        }

        if (_pendingSessionVersion != _observedSessionVersion)
        {
            _observedSessionVersion = _pendingSessionVersion;
            _lastSnapshot = null;
            var shortPendingId = string.IsNullOrWhiteSpace(_pendingThreadId)
                ? "等待识别"
                : ShortThreadId(_pendingThreadId);
            _sessionMenuItem.Text = $"会话：{shortPendingId}{RouteStatusSuffix(_pendingRouteStatus)}";
            _pinSessionMenuItem.Enabled = !string.IsNullOrWhiteSpace(_pendingThreadId);
            _form.UpdateWaitingState($"等待会话 {shortPendingId} 的 token 数据…");
        }

        var snapshot = _pendingSnapshot;
        if (snapshot is not null && snapshot != _lastSnapshot)
        {
            _lastSnapshot = snapshot;
            _form.UpdateSnapshot(snapshot, _visibleFields);
            var shortId = ShortThreadId(snapshot.ThreadId);
            _sessionMenuItem.Text = $"会话：{shortId}{RouteStatusSuffix(_pendingRouteStatus)}";
            _pinSessionMenuItem.Enabled = true;
            _trayIcon.Text = TrimTrayText($"Codex {shortId} · {TokenStripForm.FormatTokenCount(snapshot.TotalTokens)} tokens");
        }

        if (_manuallyHidden || !CodexWindowLocator.TryGetForegroundCodexWindow(out var windowRectangle))
        {
            if (_form.Visible)
            {
                _form.Hide();
            }
            return;
        }

        var location = CalculateLocation(windowRectangle, _form.Size, _anchorMode);
        if (_form.Location != location)
        {
            _form.Location = location;
        }
        if (!_form.Visible)
        {
            _form.Show();
        }
    }

    private void RequestBackgroundPoll()
    {
        if (Interlocked.CompareExchange(ref _pollInFlight, 1, 0) != 0)
        {
            return;
        }

        var uiScheduler = TaskScheduler.FromCurrentSynchronizationContext();
        _ = Task.Run(() =>
            {
                var routeStatus = _routeMonitor.GetStatus();
                if (!_monitor.PinActiveSession)
                {
                    if (!string.IsNullOrWhiteSpace(routeStatus.ThreadId))
                    {
                        _monitor.PreferredThreadId = routeStatus.ThreadId;
                    }
                    else if (!routeStatus.IsConnected)
                    {
                        _monitor.PreferredThreadId = null;
                    }
                }
                var snapshot = _monitor.Poll();
                return (
                    Snapshot: snapshot,
                    Version: _monitor.ActiveSessionVersion,
                    ThreadId: _monitor.ActiveThreadId,
                    RouteStatus: routeStatus);
            })
            .ContinueWith(task =>
            {
                try
                {
                    if (task.Status == TaskStatus.RanToCompletion)
                    {
                        _pendingSnapshot = task.Result.Snapshot;
                        _pendingSessionVersion = task.Result.Version;
                        _pendingThreadId = task.Result.ThreadId;
                        _pendingRouteStatus = task.Result.RouteStatus;
                    }
                }
                finally
                {
                    Interlocked.Exchange(ref _pollInFlight, 0);
                }
            }, CancellationToken.None, TaskContinuationOptions.None, uiScheduler);
    }

    private static Point CalculateLocation(Rectangle window, Size overlay, AnchorMode mode)
    {
        const int gap = 10;
        const int insideMargin = 18;
        const int headerOffset = 56;
        var workingArea = Screen.FromRectangle(window).WorkingArea;

        if (mode == AnchorMode.Auto)
        {
            if (workingArea.Right - window.Right >= overlay.Width + gap)
            {
                return new Point(window.Right + gap, Math.Max(workingArea.Top + gap, window.Bottom - overlay.Height - 70));
            }
            if (window.Left - workingArea.Left >= overlay.Width + gap)
            {
                return new Point(window.Left - overlay.Width - gap, Math.Max(workingArea.Top + gap, window.Bottom - overlay.Height - 70));
            }
            mode = AnchorMode.InsideTopRight;
        }

        return mode == AnchorMode.InsideBottomRight
            ? new Point(
                Math.Max(workingArea.Left + gap, window.Right - overlay.Width - insideMargin),
                window.Bottom - overlay.Height - insideMargin)
            : new Point(
                Math.Max(workingArea.Left + gap, window.Right - overlay.Width - insideMargin),
                window.Top + headerOffset);
    }

    private static string ShortThreadId(string threadId)
    {
        return threadId.Length <= 12 ? threadId : $"{threadId[..4]}…{threadId[^6..]}";
    }

    private static string TrimTrayText(string value)
    {
        return value.Length <= 63 ? value : value[..63];
    }

    private static string RouteStatusSuffix(ActiveThreadRouteStatus status)
    {
        if (status.ActiveWindowCount > 1)
        {
            return $" · 多窗口 {status.ActiveWindowCount}";
        }
        return status.IsConnected ? " · 已同步" : " · 日志模式";
    }

    private void ExitOverlay()
    {
        _timer.Stop();
        _trayIcon.Visible = false;
        _trayIcon.Dispose();
        _routeMonitor.Dispose();
        _monitor.Dispose();
        _form.Close();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _timer.Dispose();
            _trayIcon.Dispose();
            _routeMonitor.Dispose();
            _monitor.Dispose();
            _form.Dispose();
        }
        base.Dispose(disposing);
    }
}

internal sealed class TokenStripForm : Form
{
    private const int WsExTransparent = 0x00000020;
    private const int WsExToolWindow = 0x00000080;
    private const int WsExNoActivate = 0x08000000;
    private readonly Label _label;
    private double _contextPercent;

    public TokenStripForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(30, 32, 38);
        ForeColor = Color.FromArgb(235, 239, 246);
        Opacity = 0.94;
        Size = new Size(610, 36);
        Padding = new Padding(12, 2, 12, 4);
        DoubleBuffered = true;

        _label = new Label
        {
            Dock = DockStyle.Fill,
            BackColor = Color.Transparent,
            ForeColor = ForeColor,
            Font = new Font("Segoe UI", 9.5f, FontStyle.Regular, GraphicsUnit.Point),
            TextAlign = ContentAlignment.MiddleCenter,
            AutoEllipsis = true
        };
        Controls.Add(_label);
        UpdateRoundedRegion();
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.ExStyle |= WsExTransparent | WsExToolWindow | WsExNoActivate;
            return parameters;
        }
    }

    public void UpdateWaitingState(string message)
    {
        _contextPercent = 0;
        _label.Text = message;
        Invalidate();
    }

    public void UpdateSnapshot(TokenSnapshot snapshot, DisplayField visibleFields)
    {
        _contextPercent = snapshot.ContextPercent;
        var fields = new List<string>();

        AddIfVisible(DisplayField.Total, $"总 {FormatTokenCount(snapshot.TotalTokens)}");
        AddIfVisible(DisplayField.Input, $"输入 {FormatTokenCount(snapshot.InputTokens)}");
        AddIfVisible(DisplayField.Output, $"输出 {FormatTokenCount(snapshot.OutputTokens)}");
        AddIfVisible(DisplayField.CacheHit, $"命中 {FormatTokenCount(snapshot.CachedInputTokens)}");
        AddIfVisible(DisplayField.CacheMiss, $"未命中 {FormatTokenCount(snapshot.UncachedInputTokens)}");
        AddIfVisible(DisplayField.Context, $"上下文 {FormatTokenCount(snapshot.ContextUsedTokens)}/{FormatTokenCount(snapshot.ContextWindowTokens)}");
        AddIfVisible(DisplayField.ContextPercent, $"{snapshot.ContextPercent:0}%");
        AddIfVisible(DisplayField.Reasoning, $"推理 {FormatTokenCount(snapshot.ReasoningOutputTokens)}");
        AddIfVisible(DisplayField.Thread, $"会话 {ShortThreadId(snapshot.ThreadId)}");

        _label.Text = string.Join("  ·  ", fields);
        var measured = TextRenderer.MeasureText(_label.Text, _label.Font, Size.Empty, TextFormatFlags.NoPadding);
        Width = Math.Clamp(measured.Width + 38, 260, 1180);
        Invalidate();

        void AddIfVisible(DisplayField field, string text)
        {
            if (visibleFields.HasFlag(field))
            {
                fields.Add(text);
            }
        }
    }

    private static string ShortThreadId(string threadId)
    {
        return threadId.Length <= 12 ? threadId : $"{threadId[..4]}…{threadId[^6..]}";
    }

    public static string FormatTokenCount(long value)
    {
        return value switch
        {
            >= 1_000_000 => $"{value / 1_000_000d:0.00}M",
            >= 1_000 => $"{value / 1_000d:0.0}K",
            _ => value.ToString("N0")
        };
    }

    protected override void OnResize(EventArgs eventArgs)
    {
        base.OnResize(eventArgs);
        UpdateRoundedRegion();
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;

        var trackRectangle = new Rectangle(10, Height - 3, Width - 20, 2);
        using var trackBrush = new SolidBrush(Color.FromArgb(55, 255, 255, 255));
        eventArgs.Graphics.FillRectangle(trackBrush, trackRectangle);

        var progressWidth = (int)Math.Round(trackRectangle.Width * _contextPercent / 100d);
        if (progressWidth <= 0)
        {
            return;
        }

        var progressColor = _contextPercent switch
        {
            >= 85 => Color.FromArgb(255, 99, 110),
            >= 65 => Color.FromArgb(255, 190, 92),
            _ => Color.FromArgb(91, 202, 255)
        };
        using var progressBrush = new SolidBrush(progressColor);
        eventArgs.Graphics.FillRectangle(progressBrush, new Rectangle(trackRectangle.X, trackRectangle.Y, progressWidth, trackRectangle.Height));
    }

    private void UpdateRoundedRegion()
    {
        if (Width <= 0 || Height <= 0)
        {
            return;
        }

        using var path = CreateRoundedRectanglePath(new Rectangle(0, 0, Width, Height), 11);
        Region?.Dispose();
        Region = new Region(path);
    }

    private static GraphicsPath CreateRoundedRectanglePath(Rectangle rectangle, int radius)
    {
        var diameter = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(rectangle.Left, rectangle.Top, diameter, diameter, 180, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Top, diameter, diameter, 270, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rectangle.Left, rectangle.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}

internal static class CodexWindowLocator
{
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint GaRoot = 2;
    private const int DwmwaExtendedFrameBounds = 9;

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr windowHandle, StringBuilder text, int maximumCount);

    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr windowHandle, uint flags);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr windowHandle, out uint processId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(IntPtr windowHandle, out NativeRectangle rectangle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(IntPtr windowHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageName(
        IntPtr processHandle,
        uint flags,
        StringBuilder executablePath,
        ref uint pathLength);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(
        IntPtr windowHandle,
        int attribute,
        out NativeRectangle value,
        int valueSize);

    public static bool TryGetForegroundCodexWindow(out Rectangle rectangle)
    {
        rectangle = Rectangle.Empty;
        var windowHandle = GetForegroundWindow();
        windowHandle = GetAncestor(windowHandle, GaRoot);
        if (windowHandle == IntPtr.Zero || IsIconic(windowHandle))
        {
            return false;
        }

        GetWindowThreadProcessId(windowHandle, out var processId);
        if (processId == 0)
        {
            return false;
        }

        if (!IsCodexDesktopProcess(processId, windowHandle))
        {
            return false;
        }

        var dwmResult = DwmGetWindowAttribute(
            windowHandle,
            DwmwaExtendedFrameBounds,
            out var nativeRectangle,
            Marshal.SizeOf<NativeRectangle>());
        if (dwmResult != 0 && !GetWindowRect(windowHandle, out nativeRectangle))
        {
            return false;
        }

        rectangle = Rectangle.FromLTRB(
            nativeRectangle.Left,
            nativeRectangle.Top,
            nativeRectangle.Right,
            nativeRectangle.Bottom);
        return rectangle.Width >= 500 && rectangle.Height >= 400;
    }

    public static object GetForegroundWindowProbe()
    {
        var windowHandle = GetAncestor(GetForegroundWindow(), GaRoot);
        if (windowHandle == IntPtr.Zero)
        {
            return new { Found = false };
        }

        GetWindowThreadProcessId(windowHandle, out var processId);
        var title = new StringBuilder(1024);
        GetWindowText(windowHandle, title, title.Capacity);
        return new
        {
            Found = true,
            Handle = windowHandle.ToInt64(),
            ProcessId = processId,
            IsCodex = processId != 0 && IsCodexDesktopProcess(processId, windowHandle),
            Title = title.ToString()
        };
    }

    private static bool IsCodexDesktopProcess(uint processId, IntPtr windowHandle)
    {
        var processHandle = OpenProcess(ProcessQueryLimitedInformation, inheritHandle: false, processId);
        if (processHandle == IntPtr.Zero)
        {
            return false;
        }

        try
        {
            var capacity = 2048u;
            var path = new StringBuilder((int)capacity);
            if (!QueryFullProcessImageName(processHandle, 0, path, ref capacity))
            {
                return false;
            }

            var executablePath = path.ToString();
            var executableName = Path.GetFileName(executablePath);
            var isKnownExecutableName = executableName.Equals("ChatGPT.exe", StringComparison.OrdinalIgnoreCase)
                || executableName.Equals("Codex.exe", StringComparison.OrdinalIgnoreCase);
            if (!isKnownExecutableName)
            {
                return false;
            }

            // Microsoft Store/MSIX 版仍使用 ChatGPT.exe，但安装包路径可稳定区分 Codex。
            if (executablePath.Contains("\\WindowsApps\\OpenAI.Codex_", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            // 兼容未来或企业分发的独立 Codex.exe。
            if (executableName.Equals("Codex.exe", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            // 非 MSIX 的 ChatGPT.exe 只有在路径和窗口标题都明确指向 Codex 时才接受，
            // 避免吸附到普通 ChatGPT 客户端。
            var title = new StringBuilder(1024);
            GetWindowText(windowHandle, title, title.Capacity);
            return title.ToString().Contains("Codex", StringComparison.OrdinalIgnoreCase)
                && (executablePath.Contains("\\OpenAI.Codex", StringComparison.OrdinalIgnoreCase)
                    || executablePath.Contains("\\Codex\\", StringComparison.OrdinalIgnoreCase));
        }
        finally
        {
            CloseHandle(processHandle);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRectangle
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
