using System;
using System.Collections.Generic;
using System.Linq;
namespace CodexTokenOverlay;
internal sealed class ContextAlertTracker
{
    private sealed class State
    {
        public DateTime Timestamp;
        public HashSet<double> Notified = new();
    }
    private readonly Dictionary<string, State> _threads = new(StringComparer.OrdinalIgnoreCase);
    public double? Observe(string threadId, long used, long window, DateTime timestamp,
        IEnumerable<double> thresholds)
    {
        if (string.IsNullOrWhiteSpace(threadId) || window <= 0 || used < 0) return null;
        if (!_threads.TryGetValue(threadId, out var state))
            _threads[threadId] = state = new State();
        if (timestamp <= state.Timestamp) return null;
        state.Timestamp = timestamp;
        var left = Math.Clamp(100 - used * 100d / window, 0, 100);
        var levels = thresholds.Where(t => double.IsFinite(t) && t > 0 && t < 100)
            .Distinct().OrderBy(t => t).ToArray();
        foreach (var level in levels)
            if (left > level + 3) state.Notified.Remove(level);
        var crossed = levels.Where(t => left <= t && !state.Notified.Contains(t)).ToArray();
        if (crossed.Length == 0) return null;
        foreach (var level in crossed) state.Notified.Add(level);
        return crossed[0];
    }
}
