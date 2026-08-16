using System.Globalization;

namespace CodexTokenOverlay;

internal sealed record OverlayMetric(
    DisplayField Field,
    string CompactLabel,
    string ExpandedLabel,
    string Value,
    bool HasValue);

internal sealed record OverlayPresentation(
    OverlayMetric Primary,
    OverlayMetric Secondary,
    IReadOnlyList<OverlayMetric> ExpandedRows,
    double ContextPercent,
    bool ShowContextProgress,
    string? StatusText);

internal static class OverlayPresentationBuilder
{
    private const string NoValue = "—";

    public static OverlayPresentation CreateWaiting(
        string statusText,
        DisplayField primaryField,
        DisplayField secondaryField,
        DisplayField visibleFields)
    {
        ValidateHighlightedFields(primaryField, secondaryField);
        return new OverlayPresentation(
            CreateWaitingMetric(primaryField),
            CreateWaitingMetric(secondaryField),
            CreateExpandedRows(visibleFields, primaryField, secondaryField, CreateWaitingMetric),
            0,
            false,
            SanitizeSingleLine(statusText));
    }

    public static OverlayPresentation Create(
        TokenSnapshot snapshot,
        DisplayField primaryField,
        DisplayField secondaryField,
        DisplayField visibleFields)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ValidateHighlightedFields(primaryField, secondaryField);
        var contextPercent = Math.Clamp(snapshot.ContextPercent, 0, 100);
        return new OverlayPresentation(
            CreateMetric(snapshot, primaryField, contextPercent),
            CreateMetric(snapshot, secondaryField, contextPercent),
            CreateExpandedRows(
                visibleFields,
                primaryField,
                secondaryField,
                field => CreateMetric(snapshot, field, contextPercent)),
            contextPercent,
            (visibleFields & DisplayField.ContextPercent) != 0,
            null);
    }

    public static string FormatTokenCount(long value) => value switch
    {
        >= 1_000_000 => (value / 1_000_000d).ToString("0.00", CultureInfo.InvariantCulture) + "M",
        >= 1_000 => (value / 1_000d).ToString("0.0", CultureInfo.InvariantCulture) + "k",
        _ => value.ToString("N0", CultureInfo.InvariantCulture)
    };

    public static string FormatUsd(decimal value) =>
        "$" + Math.Max(0, value).ToString("0.00", CultureInfo.InvariantCulture);

    public static string ShortThreadId(string threadId, int maximumLength = 12)
    {
        var singleLineThreadId = SanitizeSingleLine(threadId);
        if (singleLineThreadId.Length <= maximumLength)
        {
            return singleLineThreadId;
        }

        if (maximumLength <= 1)
        {
            return maximumLength == 1 ? "…" : string.Empty;
        }

        var prefixLength = Math.Min(4, maximumLength - 1);
        var suffixLength = Math.Min(6, maximumLength - prefixLength - 1);
        return string.Concat(
            singleLineThreadId.AsSpan(0, prefixLength),
            "…",
            singleLineThreadId.AsSpan(singleLineThreadId.Length - suffixLength, suffixLength));
    }

    public static string GetFieldMenuText(DisplayField field)
    {
        return field switch
        {
            DisplayField.Total => "总 token",
            DisplayField.Input => "输入 token",
            DisplayField.Output => "输出 token",
            DisplayField.CacheHit => "缓存命中",
            DisplayField.CacheHitRate => "缓存命中率",
            DisplayField.CacheMiss => "缓存未命中（推导）",
            DisplayField.Context => "上下文用量",
            DisplayField.ContextPercent => "上下文百分比",
            DisplayField.Reasoning => "推理输出",
            DisplayField.Thread => "会话 ID",
            DisplayField.TotalCost => "估算总价",
            DisplayField.MainAgent => "主代理 Token",
            DisplayField.Subagents => "子代理 Token",
            DisplayField.MainAgentCost => "主代理费用",
            DisplayField.SubagentsCost => "子代理费用",
            _ => throw new ArgumentOutOfRangeException(nameof(field), field, "不支持的展示字段。")
        };
    }

    private static void ValidateHighlightedFields(DisplayField primaryField, DisplayField secondaryField)
    {
        if (!DisplayFieldRules.IsSingleSupported(primaryField)
            || !DisplayFieldRules.IsSingleSupported(secondaryField))
        {
            throw new ArgumentException("收起指标必须是受支持的单个字段。");
        }
    }

    private static IReadOnlyList<OverlayMetric> CreateExpandedRows(
        DisplayField visibleFields,
        DisplayField primaryField,
        DisplayField secondaryField,
        Func<DisplayField, OverlayMetric> createMetric)
    {
        return DisplayFieldRules.Ordered
            .Where(field => (visibleFields & field) != 0)
            .Where(field => field != primaryField && field != secondaryField)
            .Select(createMetric)
            .ToArray();
    }

    private static OverlayMetric CreateWaitingMetric(DisplayField field)
    {
        var labels = GetLabels(field);
        return new OverlayMetric(field, labels.Compact, labels.Expanded, NoValue, false);
    }

    private static OverlayMetric CreateMetric(
        TokenSnapshot snapshot,
        DisplayField field,
        double contextPercent)
    {
        var labels = GetLabels(field);
        var cost = TokenCostEstimator.Estimate(snapshot);
        var mainAgentUsages = snapshot.PricingUsages.Where(usage => usage.IsMainAgent).ToArray();
        var subagentUsages = snapshot.PricingUsages.Where(usage => !usage.IsMainAgent).ToArray();
        var mainAgent = CreateAgentBreakdown(mainAgentUsages, snapshot, isMainAgent: true);
        var subagents = CreateAgentBreakdown(subagentUsages, snapshot, isMainAgent: false);
        labels = field switch
        {
            DisplayField.MainAgent => (labels.Compact, $"主代理（{mainAgent.ModelText}）"),
            DisplayField.Subagents => (labels.Compact, $"子代理（{subagents.ModelText}）"),
            _ => labels
        };
        var value = field switch
        {
            DisplayField.Total => FormatTokenCount(snapshot.TotalTokens),
            DisplayField.Input => $"{FormatTokenCount(snapshot.InputTokens)} · {FormatUsd(cost.InputCostUsd)}",
            DisplayField.Output => $"{FormatTokenCount(snapshot.OutputTokens)} · {FormatUsd(cost.OutputCostUsd)}",
            DisplayField.CacheHit => $"{FormatTokenCount(snapshot.CachedInputTokens)} · {FormatUsd(cost.CachedInputCostUsd)}",
            DisplayField.CacheHitRate => $"{snapshot.CacheHitPercent:0}%",
            DisplayField.CacheMiss => FormatTokenCount(snapshot.UncachedInputTokens),
            DisplayField.Context => $"{FormatTokenCount(snapshot.ContextUsedTokens)} / {FormatTokenCount(snapshot.ContextWindowTokens)}",
            DisplayField.ContextPercent => $"{contextPercent:0}%",
            DisplayField.Reasoning => FormatTokenCount(snapshot.ReasoningOutputTokens),
            DisplayField.Thread => ShortThreadId(snapshot.ThreadId),
            DisplayField.TotalCost => FormatUsd(cost.TotalCostUsd),
            DisplayField.MainAgent => FormatTokenCount(mainAgent.TotalTokens),
            DisplayField.MainAgentCost => FormatUsd(mainAgent.TotalCostUsd),
            DisplayField.Subagents => FormatTokenCount(subagents.TotalTokens),
            DisplayField.SubagentsCost => FormatUsd(subagents.TotalCostUsd),
            _ => throw new ArgumentOutOfRangeException(nameof(field), field, "不支持的展示字段。")
        };
        var hasValue = field != DisplayField.Thread || !string.IsNullOrWhiteSpace(snapshot.ThreadId);
        return new OverlayMetric(field, labels.Compact, labels.Expanded, value, hasValue);
    }

    private static (string Compact, string Expanded) GetLabels(DisplayField field)
    {
        return field switch
        {
            DisplayField.Total => ("总", "总 Token"),
            DisplayField.Input => ("入", "输入"),
            DisplayField.Output => ("出", "输出"),
            DisplayField.CacheHit => ("命中", "缓存命中"),
            DisplayField.CacheHitRate => ("命中率", "缓存命中率"),
            DisplayField.CacheMiss => ("未中", "缓存未命中"),
            DisplayField.Context => ("上下文", "上下文用量"),
            DisplayField.ContextPercent => ("上下文", "上下文占用"),
            DisplayField.Reasoning => ("推理", "推理输出"),
            DisplayField.Thread => ("会话", "会话"),
            DisplayField.TotalCost => ("总价", "估算总价"),
            DisplayField.MainAgent => ("主代理", "主代理"),
            DisplayField.Subagents => ("子代理", "子代理"),
            DisplayField.MainAgentCost => ("主费", "主代理费用"),
            DisplayField.SubagentsCost => ("子费", "子代理费用"),
            _ => throw new ArgumentOutOfRangeException(nameof(field), field, "不支持的展示字段。")
        };
    }

    private static AgentBreakdown CreateAgentBreakdown(
        IReadOnlyList<TokenPricingUsage> usages,
        TokenSnapshot snapshot,
        bool isMainAgent)
    {
        if (usages.Count == 0)
        {
            return isMainAgent
                ? new AgentBreakdown("Sol", snapshot.TotalTokens, TokenCostEstimator.Estimate(snapshot).TotalCostUsd)
                : new AgentBreakdown("无", 0, 0);
        }

        var modelGroups = usages
            .GroupBy(
                usage => usage.Model.Contains("luna", StringComparison.OrdinalIgnoreCase) ? "Luna" : "Sol",
                StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var countText = string.Join("+", modelGroups.Select(group =>
            isMainAgent && group.Count() == 1 ? group.Key : $"{group.Key}×{group.Count()}"));
        var tokens = usages.Aggregate(0L, (sum, usage) =>
            long.MaxValue - sum < Math.Max(0, usage.TotalTokens)
                ? long.MaxValue
                : sum + Math.Max(0, usage.TotalTokens));
        var cost = TokenCostEstimator.Estimate(usages).TotalCostUsd;
        return new AgentBreakdown(countText, tokens, cost);
    }

    private sealed record AgentBreakdown(string ModelText, long TotalTokens, decimal TotalCostUsd);

    private static string SanitizeSingleLine(string value)
    {
        return value.Replace("\r", string.Empty, StringComparison.Ordinal)
            .Replace("\n", string.Empty, StringComparison.Ordinal);
    }
}

internal sealed class PresentationProbeRequest
{
    public List<PresentationProbeCase> Cases { get; set; } = new();
}

internal sealed class PresentationProbeCase
{
    public string Name { get; set; } = string.Empty;
    public string Operation { get; set; } = string.Empty;
    public TokenSnapshot? Snapshot { get; set; }
    public int? PrimaryField { get; set; }
    public int? SecondaryField { get; set; }
    public int? VisibleFields { get; set; }
    public string? StatusText { get; set; }
}

internal sealed record PresentationProbeCaseResult(string Name, OverlayPresentation Presentation);

internal sealed record PresentationProbeResult(IReadOnlyList<PresentationProbeCaseResult> Cases);

internal static class PresentationProbe
{
    public static PresentationProbeResult Execute(PresentationProbeRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var results = new List<PresentationProbeCaseResult>();
        foreach (var probeCase in request.Cases)
        {
            var primaryField = RequireField(probeCase.PrimaryField, nameof(probeCase.PrimaryField));
            var secondaryField = RequireField(probeCase.SecondaryField, nameof(probeCase.SecondaryField));
            var visibleFields = (DisplayField)(probeCase.VisibleFields ?? 0);
            var presentation = probeCase.Operation switch
            {
                "Create" => OverlayPresentationBuilder.Create(
                    probeCase.Snapshot ?? throw new ArgumentException("Create 操作需要 Snapshot。", nameof(probeCase)),
                    primaryField,
                    secondaryField,
                    visibleFields),
                "Waiting" => OverlayPresentationBuilder.CreateWaiting(
                    probeCase.StatusText ?? string.Empty,
                    primaryField,
                    secondaryField,
                    visibleFields),
                _ => throw new ArgumentException($"不支持的展示探针操作：{probeCase.Operation}", nameof(probeCase))
            };
            results.Add(new PresentationProbeCaseResult(probeCase.Name, presentation));
        }

        return new PresentationProbeResult(results);
    }

    private static DisplayField RequireField(int? value, string parameterName)
    {
        if (!value.HasValue)
        {
            throw new ArgumentException("展示探针需要字段。", parameterName);
        }

        return (DisplayField)value.Value;
    }
}
