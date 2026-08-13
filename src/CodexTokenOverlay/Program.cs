using System.Collections.Concurrent;
using System.Buffers.Binary;
using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace CodexTokenOverlay;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        var sessionRoot = SessionPathResolver.Resolve(args);
        if (ProbeRunner.TryRun(args, sessionRoot))
        {
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

        var settingsPath = OverlaySettings.ResolveSettingsOverride(args);
        Application.Run(new OverlayContext(sessionRoot, settingsPath));
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

    public double CacheHitPercent => InputTokens <= 0
        ? 0d
        : Math.Clamp((double)CachedInputTokens * 100d / InputTokens, 0d, 100d);

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
