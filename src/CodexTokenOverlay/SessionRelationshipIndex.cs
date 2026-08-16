using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;

namespace CodexTokenOverlay;

/// <summary>
/// The metadata needed to relate a Codex session to its direct parent.
/// </summary>
internal sealed record SessionRelationshipDescription(
    string SessionId,
    string FilePath,
    string? ParentThreadId,
    string? Originator,
    string? Source,
    DateTime LastWriteUtc);

/// <summary>
/// Maintains a read-only, incrementally updated index of Codex session metadata.
/// </summary>
internal sealed class SessionRelationshipIndex : IDisposable
{
    private const int ChangeRetryCount = 4;
    private const int ChangeRetryDelayMilliseconds = 40;

    private readonly string _sessionsRoot;
    private readonly string _sessionsRootPrefix;
    private readonly object _sync = new();
    private readonly Dictionary<string, SessionRelationshipDescription> _descriptionsByPath =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, SessionRelationshipDescription> _descriptionsBySessionId =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, HashSet<string>> _childrenByParentId =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly BlockingCollection<IndexChange> _pendingChanges = new();
    private readonly CancellationTokenSource _shutdown = new();
    private readonly FileSystemWatcher? _watcher;
    private readonly Task? _worker;
    private int _disposed;

    public SessionRelationshipIndex(string sessionsRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sessionsRoot);

        _sessionsRoot = Path.GetFullPath(sessionsRoot);
        _sessionsRootPrefix = _sessionsRoot.EndsWith(Path.DirectorySeparatorChar)
            || _sessionsRoot.EndsWith(Path.AltDirectorySeparatorChar)
            ? _sessionsRoot
            : _sessionsRoot + Path.DirectorySeparatorChar;

        // Set up the watcher before the initial scan. Events raised while the scan
        // is in progress remain queued and are applied after the initial snapshot.
        if (Directory.Exists(_sessionsRoot))
        {
            try
            {
                _watcher = new FileSystemWatcher(_sessionsRoot, "*.jsonl")
                {
                    IncludeSubdirectories = true,
                    NotifyFilter = NotifyFilters.FileName
                        | NotifyFilters.LastWrite
                        | NotifyFilters.CreationTime
                        | NotifyFilters.Size
                };
                _watcher.Created += OnCreatedOrChanged;
                _watcher.Changed += OnCreatedOrChanged;
                _watcher.Renamed += OnRenamed;
                _watcher.Deleted += OnDeleted;
                _watcher.Error += OnWatcherError;
                _watcher.EnableRaisingEvents = true;
            }
            catch (Exception exception) when (exception is ArgumentException
                or IOException
                or UnauthorizedAccessException)
            {
                // The initial read-only scan remains useful when a watcher cannot
                // be attached (for example, an inaccessible directory).
                _watcher = null;
            }

            BuildInitialIndex();
            _worker = Task.Run(ProcessChanges);
        }
    }

    /// <summary>
    /// Gets the currently selected description for a session ID.
    /// </summary>
    public bool TryGetDescription(string sessionId, out SessionRelationshipDescription? description)
    {
        if (string.IsNullOrWhiteSpace(sessionId))
        {
            description = null;
            return false;
        }

        lock (_sync)
        {
            return _descriptionsBySessionId.TryGetValue(sessionId, out description);
        }
    }

    /// <summary>
    /// Gets the path of the indexed session file for a session ID.
    /// </summary>
    public bool TryGetSessionPath(string sessionId, out string? filePath)
    {
        if (TryGetDescription(sessionId, out var description))
        {
            filePath = description!.FilePath;
            return true;
        }

        filePath = null;
        return false;
    }

    /// <summary>
    /// Returns all recursive descendants of a root thread, excluding the root.
    /// </summary>
    public IReadOnlyList<SessionRelationshipDescription> GetDescendants(string rootThreadId)
    {
        if (string.IsNullOrWhiteSpace(rootThreadId))
        {
            return Array.Empty<SessionRelationshipDescription>();
        }

        lock (_sync)
        {
            var descendants = new List<SessionRelationshipDescription>();
            var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                rootThreadId
            };
            var pendingParentIds = new Queue<string>();
            pendingParentIds.Enqueue(rootThreadId);

            while (pendingParentIds.Count > 0)
            {
                var parentId = pendingParentIds.Dequeue();
                if (!_childrenByParentId.TryGetValue(parentId, out var childIds))
                {
                    continue;
                }

                foreach (var childId in childIds
                    .OrderBy(static value => value, StringComparer.OrdinalIgnoreCase))
                {
                    if (!visited.Add(childId))
                    {
                        continue;
                    }

                    if (_descriptionsBySessionId.TryGetValue(childId, out var child))
                    {
                        descendants.Add(child);
                    }

                    // The child can have descendants even when the root itself is
                    // not present in the index, so continue from every known child ID.
                    pendingParentIds.Enqueue(childId);
                }
            }

            return descendants;
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        _watcher?.Dispose();
        _pendingChanges.CompleteAdding();
        _shutdown.Cancel();

        if (_worker is not null)
        {
            try
            {
                _worker.Wait();
            }
            catch (AggregateException exception) when (exception.InnerExceptions.All(
                static inner => inner is OperationCanceledException or ObjectDisposedException))
            {
                // Disposal is intentionally idempotent and does not expose worker
                // cancellation to callers.
            }
        }

        _pendingChanges.Dispose();
        _shutdown.Dispose();
    }

    private void BuildInitialIndex()
    {
        var parsed = new List<SessionRelationshipDescription>();

        foreach (var path in EnumerateSessionFiles())
        {
            if (TryReadDescription(path, out var description))
            {
                parsed.Add(description!);
            }
        }

        lock (_sync)
        {
            _descriptionsByPath.Clear();
            foreach (var description in parsed)
            {
                _descriptionsByPath[description.FilePath] = description;
            }

            RebuildRelationshipMaps_NoLock();
        }
    }

    private IEnumerable<string> EnumerateSessionFiles()
    {
        try
        {
            return Directory.EnumerateFiles(_sessionsRoot, "*.jsonl", SearchOption.AllDirectories)
                .Where(IsPathInSessionsRoot)
                .ToArray();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return Array.Empty<string>();
        }
    }

    private void ProcessChanges()
    {
        try
        {
            foreach (var change in _pendingChanges.GetConsumingEnumerable(_shutdown.Token))
            {
                switch (change.Kind)
                {
                    case IndexChangeKind.CreatedOrChanged:
                        ProcessCreatedOrChanged(change.Path);
                        break;
                    case IndexChangeKind.Renamed:
                        ProcessDeleted(change.OldPath!);
                        ProcessCreatedOrChanged(change.Path);
                        break;
                    case IndexChangeKind.Deleted:
                        ProcessDeleted(change.Path);
                        break;
                    case IndexChangeKind.Rescan:
                        RebuildFromDisk(_shutdown.Token);
                        break;
                }
            }
        }
        catch (OperationCanceledException) when (_shutdown.IsCancellationRequested)
        {
            // Normal shutdown.
        }
    }

    private void ProcessCreatedOrChanged(string path)
    {
        if (!IsJsonlPath(path))
        {
            return;
        }

        if (TryReadDescriptionWithRetries(path, _shutdown.Token, out var description))
        {
            lock (_sync)
            {
                _descriptionsByPath[description!.FilePath] = description;
                RebuildRelationshipMaps_NoLock();
            }
            return;
        }

        // A partial first line is deliberately retained until a later Changed event
        // succeeds. A missing file, however, must be removed immediately.
        if (!File.Exists(path))
        {
            ProcessDeleted(path);
        }
    }

    private void ProcessDeleted(string path)
    {
        var normalizedPath = NormalizePath(path);
        if (normalizedPath is null)
        {
            return;
        }

        lock (_sync)
        {
            if (_descriptionsByPath.Remove(normalizedPath))
            {
                RebuildRelationshipMaps_NoLock();
            }
        }
    }

    private void RebuildFromDisk(CancellationToken cancellationToken)
    {
        var parsed = new Dictionary<string, SessionRelationshipDescription>(StringComparer.OrdinalIgnoreCase);

        foreach (var path in EnumerateSessionFiles())
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return;
            }

            if (TryReadDescription(path, out var description))
            {
                parsed[description!.FilePath] = description;
            }
        }

        lock (_sync)
        {
            _descriptionsByPath.Clear();
            foreach (var pair in parsed)
            {
                _descriptionsByPath[pair.Key] = pair.Value;
            }

            RebuildRelationshipMaps_NoLock();
        }
    }

    private void RebuildRelationshipMaps_NoLock()
    {
        _descriptionsBySessionId.Clear();
        _childrenByParentId.Clear();

        // There should normally be one file per ID. If a rotation or a copied log
        // briefly creates duplicates, prefer the newest file and use its path as a
        // deterministic tie breaker.
        foreach (var description in _descriptionsByPath.Values)
        {
            if (!_descriptionsBySessionId.TryGetValue(description.SessionId, out var existing)
                || IsPreferred(description, existing))
            {
                _descriptionsBySessionId[description.SessionId] = description;
            }
        }

        foreach (var description in _descriptionsBySessionId.Values)
        {
            if (string.IsNullOrWhiteSpace(description.ParentThreadId))
            {
                continue;
            }

            if (!_childrenByParentId.TryGetValue(description.ParentThreadId, out var childIds))
            {
                childIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                _childrenByParentId[description.ParentThreadId] = childIds;
            }

            childIds.Add(description.SessionId);
        }
    }

    private static bool IsPreferred(
        SessionRelationshipDescription candidate,
        SessionRelationshipDescription existing)
    {
        var writeComparison = candidate.LastWriteUtc.CompareTo(existing.LastWriteUtc);
        return writeComparison > 0
            || (writeComparison == 0
                && string.Compare(candidate.FilePath, existing.FilePath, StringComparison.OrdinalIgnoreCase) < 0);
    }

    private bool TryReadDescriptionWithRetries(
        string path,
        CancellationToken cancellationToken,
        out SessionRelationshipDescription? description)
    {
        for (var attempt = 0; attempt < ChangeRetryCount; attempt++)
        {
            if (TryReadDescription(path, out description))
            {
                return true;
            }

            if (attempt + 1 >= ChangeRetryCount
                || cancellationToken.WaitHandle.WaitOne(ChangeRetryDelayMilliseconds))
            {
                break;
            }
        }

        description = null;
        return false;
    }

    private static bool TryReadDescription(string path, out SessionRelationshipDescription? description)
    {
        description = null;

        try
        {
            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete,
                bufferSize: 4096,
                options: FileOptions.SequentialScan);
            using var reader = new StreamReader(
                stream,
                Encoding.UTF8,
                detectEncodingFromByteOrderMarks: true,
                bufferSize: 4096);
            var firstLine = reader.ReadLine();
            if (string.IsNullOrWhiteSpace(firstLine))
            {
                return false;
            }

            using var document = JsonDocument.Parse(firstLine);
            var root = document.RootElement;
            if (!TryGetString(root, "type", out var type)
                || !string.Equals(type, "session_meta", StringComparison.Ordinal)
                || !root.TryGetProperty("payload", out var payload)
                || payload.ValueKind != JsonValueKind.Object
                || !TryGetString(payload, "id", out var sessionId)
                || string.IsNullOrWhiteSpace(sessionId))
            {
                return false;
            }

            var parentThreadId = TryGetString(payload, "parent_thread_id", out var parent)
                ? NormalizeOptional(parent)
                : null;
            var originator = TryGetString(payload, "originator", out var originatorValue)
                ? NormalizeOptional(originatorValue)
                : null;
            var source = TryGetString(payload, "source", out var sourceValue)
                ? NormalizeOptional(sourceValue)
                : null;

            description = new SessionRelationshipDescription(
                sessionId!,
                Path.GetFullPath(path),
                parentThreadId,
                originator,
                source,
                File.GetLastWriteTimeUtc(path));
            return true;
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException
            or JsonException
            or InvalidOperationException
            or ArgumentException)
        {
            // The first line may still be incomplete or the file may have been
            // rotated/deleted. The caller decides whether to retry or retain the
            // previous valid description.
            return false;
        }
    }

    private static bool TryGetString(JsonElement element, string propertyName, out string? value)
    {
        if (element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(propertyName, out var property)
            && property.ValueKind == JsonValueKind.String)
        {
            value = property.GetString();
            return value is not null;
        }

        value = null;
        return false;
    }

    private static string? NormalizeOptional(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private void OnCreatedOrChanged(object? sender, FileSystemEventArgs eventArgs)
    {
        Enqueue(new IndexChange(IndexChangeKind.CreatedOrChanged, eventArgs.FullPath, null));
    }

    private void OnRenamed(object? sender, RenamedEventArgs eventArgs)
    {
        Enqueue(new IndexChange(IndexChangeKind.Renamed, eventArgs.FullPath, eventArgs.OldFullPath));
    }

    private void OnDeleted(object? sender, FileSystemEventArgs eventArgs)
    {
        Enqueue(new IndexChange(IndexChangeKind.Deleted, eventArgs.FullPath, null));
    }

    private void OnWatcherError(object? sender, ErrorEventArgs eventArgs)
    {
        Enqueue(new IndexChange(IndexChangeKind.Rescan, string.Empty, null));
    }

    private void Enqueue(IndexChange change)
    {
        if (Volatile.Read(ref _disposed) != 0)
        {
            return;
        }

        try
        {
            _pendingChanges.Add(change);
        }
        catch (InvalidOperationException)
        {
            // A callback raced with Dispose after CompleteAdding.
        }
    }

    private bool IsJsonlPath(string path)
    {
        var normalizedPath = NormalizePath(path);
        return normalizedPath is not null
            && normalizedPath.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase)
            && IsPathInSessionsRoot(normalizedPath);
    }

    private bool IsPathInSessionsRoot(string path)
    {
        var normalizedPath = NormalizePath(path);
        return normalizedPath is not null
            && (normalizedPath.Equals(_sessionsRoot, StringComparison.OrdinalIgnoreCase)
                || normalizedPath.StartsWith(_sessionsRootPrefix, StringComparison.OrdinalIgnoreCase));
    }

    private string? NormalizePath(string path)
    {
        try
        {
            return Path.GetFullPath(path);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    private enum IndexChangeKind
    {
        CreatedOrChanged,
        Renamed,
        Deleted,
        Rescan
    }

    private sealed record IndexChange(IndexChangeKind Kind, string Path, string? OldPath);
}
