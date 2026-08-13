using System.Text;
using System.Text.Json;

namespace CodexTokenOverlay;

internal enum AnchorMode
{
    Auto = 0,
    InsideTopRight = 1,
    InsideBottomRight = 2,
    TitleBarTopRight = 3
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
    Thread = 1 << 8,
    CacheHitRate = 1 << 9
}

internal enum CollapsedSlot { Primary, Secondary }

internal static class DisplayFieldRules
{
    public const DisplayField SupportedMask =
        DisplayField.Total | DisplayField.Input | DisplayField.Output |
        DisplayField.CacheHit | DisplayField.CacheMiss | DisplayField.Context |
        DisplayField.ContextPercent | DisplayField.Reasoning | DisplayField.Thread |
        DisplayField.CacheHitRate;

    public static readonly IReadOnlyList<DisplayField> Ordered = new[]
    {
        DisplayField.Total, DisplayField.Input, DisplayField.Output,
        DisplayField.CacheHit, DisplayField.CacheHitRate, DisplayField.CacheMiss, DisplayField.Context,
        DisplayField.ContextPercent, DisplayField.Reasoning, DisplayField.Thread
    };

    public static bool IsSingleSupported(DisplayField field)
    {
        var value = (int)field;
        return value > 0 &&
            (value & (value - 1)) == 0 &&
            (field & SupportedMask) == field;
    }

    public static DisplayField SanitizeVisible(DisplayField fields)
    {
        var sanitized = fields & SupportedMask;
        return sanitized == DisplayField.None ? DisplayField.Total : sanitized;
    }
}

internal sealed record OverlaySettingsLoadResult(
    OverlaySettings Settings,
    bool MustPersist);

internal sealed class OverlaySettings
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    private static readonly string DefaultSettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "CodexTokenOverlay",
        "settings.json");

    private const DisplayField DefaultVisibleFields =
        DisplayField.Total
        | DisplayField.Input
        | DisplayField.Output
        | DisplayField.CacheHit
        | DisplayField.CacheHitRate
        | DisplayField.CacheMiss
        | DisplayField.Context
        | DisplayField.ContextPercent;

    private sealed class PersistedSettings
    {
        public int? SettingsVersion { get; set; }
        public int? AnchorMode { get; set; }
        public int? VisibleFields { get; set; }
        public int? CollapsedPrimaryField { get; set; }
        public int? CollapsedSecondaryField { get; set; }
        public bool? ManualPlacementEnabled { get; set; }
        public PersistedWindowAttachment? MainAttachment { get; set; }
        public int? OverlayScalePercent { get; set; }
    }

    private sealed class PersistedWindowAttachment
    {
        public int? ReferencePoint { get; set; }
        public double? OffsetXDip { get; set; }
        public double? OffsetYDip { get; set; }
    }

    public const int CurrentSettingsVersion = 1;
    public int SettingsVersion { get; private set; }
    public AnchorMode AnchorMode { get; set; }
    public DisplayField VisibleFields { get; set; }
    public DisplayField CollapsedPrimaryField { get; private set; }
    public DisplayField CollapsedSecondaryField { get; private set; }
    public bool ManualPlacementEnabled { get; set; }
    public WindowAttachment MainAttachment { get; set; } = ManualAttachmentRules.DefaultMainAttachment;
    public int OverlayScalePercent { get; set; }

    public static OverlaySettings CreateDefault()
    {
        return new OverlaySettings
        {
            SettingsVersion = CurrentSettingsVersion,
            AnchorMode = AnchorMode.TitleBarTopRight,
            VisibleFields = DefaultVisibleFields,
            CollapsedPrimaryField = DisplayField.Total,
            CollapsedSecondaryField = DisplayField.ContextPercent,
            ManualPlacementEnabled = true,
            MainAttachment = ManualAttachmentRules.DefaultMainAttachment,
            OverlayScalePercent = ManualAttachmentRules.DefaultScalePercent
        };
    }

    public static OverlaySettings Load(string? settingsPath = null)
    {
        var path = settingsPath ?? DefaultSettingsPath;
        var result = LoadFromFile(path);
        if (result.MustPersist)
        {
            result.Settings.Save(path);
        }

        return result.Settings;
    }

    internal static OverlaySettingsLoadResult LoadFromFile(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return new OverlaySettingsLoadResult(CreateDefault(), false);
            }

            return ParseJson(File.ReadAllText(path, Encoding.UTF8));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return new OverlaySettingsLoadResult(CreateDefault(), false);
        }
    }

    internal static OverlaySettingsLoadResult ParseJson(string json)
    {
        try
        {
            var persisted = JsonSerializer.Deserialize<PersistedSettings>(json, JsonOptions);
            if (persisted is null)
            {
                return new OverlaySettingsLoadResult(CreateDefault(), false);
            }

            if (!persisted.SettingsVersion.HasValue)
            {
                var migrated = CreateDefault();
                migrated.VisibleFields = DisplayFieldRules.SanitizeVisible(
                    (DisplayField)(persisted.VisibleFields ?? (int)DefaultVisibleFields));
                migrated.ManualPlacementEnabled = persisted.ManualPlacementEnabled ?? false;
                return new OverlaySettingsLoadResult(migrated, true);
            }

            var settings = CreateDefault();
            settings.AnchorMode = SanitizeAnchorMode(persisted.AnchorMode);
            settings.VisibleFields = DisplayFieldRules.SanitizeVisible(
                (DisplayField)(persisted.VisibleFields ?? (int)DefaultVisibleFields));
            settings.SetCollapsedFields(
                (DisplayField)(persisted.CollapsedPrimaryField ?? (int)DisplayField.Total),
                (DisplayField)(persisted.CollapsedSecondaryField ?? (int)DisplayField.ContextPercent));
            settings.ManualPlacementEnabled = persisted.ManualPlacementEnabled ?? false;
            settings.MainAttachment = ManualAttachmentRules.SanitizeMain(
                DeserializeAttachment(persisted.MainAttachment));

            settings.OverlayScalePercent = ManualAttachmentRules.SanitizeScale(
                persisted.OverlayScalePercent);
            return new OverlaySettingsLoadResult(settings, false);
        }
        catch (JsonException)
        {
            return new OverlaySettingsLoadResult(CreateDefault(), false);
        }
    }

    internal string Serialize()
    {
        var persisted = new PersistedSettings
        {
            SettingsVersion = CurrentSettingsVersion,
            AnchorMode = (int)SanitizeAnchorMode((int)AnchorMode),
            VisibleFields = (int)DisplayFieldRules.SanitizeVisible(VisibleFields),
            CollapsedPrimaryField = (int)CollapsedPrimaryField,
            CollapsedSecondaryField = (int)CollapsedSecondaryField,
            ManualPlacementEnabled = ManualPlacementEnabled,
            MainAttachment = SerializeAttachment(ManualAttachmentRules.SanitizeMain(MainAttachment)),
            OverlayScalePercent = ManualAttachmentRules.SanitizeScale(OverlayScalePercent)
        };
        return JsonSerializer.Serialize(persisted, JsonOptions);
    }

    public bool TrySave(string? settingsPath = null)
    {
        var path = settingsPath ?? DefaultSettingsPath;
        try
        {
            var directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.WriteAllText(path, Serialize(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    public void Save(string? settingsPath = null) => TrySave(settingsPath);

    public bool SelectCollapsedField(CollapsedSlot slot, DisplayField field)
    {
        if (!DisplayFieldRules.IsSingleSupported(field))
        {
            return false;
        }

        switch (slot)
        {
            case CollapsedSlot.Primary:
                if (CollapsedPrimaryField == field)
                {
                    return false;
                }

                if (CollapsedSecondaryField == field)
                {
                    (CollapsedPrimaryField, CollapsedSecondaryField) =
                        (CollapsedSecondaryField, CollapsedPrimaryField);
                    return true;
                }

                CollapsedPrimaryField = field;
                return true;

            case CollapsedSlot.Secondary:
                if (CollapsedSecondaryField == field)
                {
                    return false;
                }

                if (CollapsedPrimaryField == field)
                {
                    (CollapsedPrimaryField, CollapsedSecondaryField) =
                        (CollapsedSecondaryField, CollapsedPrimaryField);
                    return true;
                }

                CollapsedSecondaryField = field;
                return true;

            default:
                return false;
        }
    }

    public static string? ResolveSettingsOverride(IReadOnlyList<string> args)
    {
        for (var index = 0; index < args.Count; index++)
        {
            if (!args[index].Equals("--settings", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (index + 1 >= args.Count || string.IsNullOrWhiteSpace(args[index + 1]))
            {
                throw new ArgumentException("--settings 后必须提供绝对设置文件路径。", nameof(args));
            }

            var candidate = args[index + 1];
            if (!Path.IsPathFullyQualified(candidate))
            {
                throw new ArgumentException("--settings 只接受绝对设置文件路径。", nameof(args));
            }

            return Path.GetFullPath(candidate);
        }

        return null;
    }

    private static AnchorMode SanitizeAnchorMode(int? value)
    {
        return value switch
        {
            (int)AnchorMode.Auto => AnchorMode.Auto,
            (int)AnchorMode.InsideTopRight => AnchorMode.InsideTopRight,
            (int)AnchorMode.InsideBottomRight => AnchorMode.InsideBottomRight,
            (int)AnchorMode.TitleBarTopRight => AnchorMode.TitleBarTopRight,
            _ => AnchorMode.TitleBarTopRight
        };
    }

    private static WindowAttachment? DeserializeAttachment(PersistedWindowAttachment? value)
    {
        if (value?.ReferencePoint is not int referencePoint
            || value.OffsetXDip is not double offsetXDip
            || value.OffsetYDip is not double offsetYDip)
        {
            return null;
        }

        return ManualAttachmentRules.TrySanitize(
            new WindowAttachment((AttachmentReferencePoint)referencePoint, offsetXDip, offsetYDip),
            out var attachment)
            ? attachment
            : null;
    }

    private static PersistedWindowAttachment? SerializeAttachment(WindowAttachment? value)
    {
        return value is null
            ? null
            : new PersistedWindowAttachment
            {
                ReferencePoint = (int)value.ReferencePoint,
                OffsetXDip = value.OffsetXDip,
                OffsetYDip = value.OffsetYDip
            };
    }

    private void SetCollapsedFields(DisplayField primary, DisplayField secondary)
    {
        CollapsedPrimaryField = DisplayFieldRules.IsSingleSupported(primary)
            ? primary
            : DisplayField.Total;
        CollapsedSecondaryField = DisplayFieldRules.IsSingleSupported(secondary)
            ? secondary
            : DisplayField.ContextPercent;

        if (CollapsedPrimaryField == CollapsedSecondaryField)
        {
            CollapsedSecondaryField = CollapsedPrimaryField == DisplayField.ContextPercent
                ? DisplayField.Total
                : DisplayField.ContextPercent;
        }
    }
}

internal sealed class SettingsProbeRequest
{
    public List<SettingsProbeCase> Cases { get; set; } = new();
}

internal sealed class SettingsProbeCase
{
    public string Name { get; set; } = string.Empty;
    public string Operation { get; set; } = string.Empty;
    public string? Json { get; set; }
    public string? Slot { get; set; }
    public int? Field { get; set; }
    public string? SettingsPath { get; set; }
}

internal sealed record SettingsProbeCaseResult(
    string Name,
    OverlaySettings Settings,
    bool MustPersist);

internal sealed record SettingsProbeResult(IReadOnlyList<SettingsProbeCaseResult> Cases);

internal static class SettingsProbe
{
    public static SettingsProbeResult Execute(SettingsProbeRequest request)
    {
        var results = new List<SettingsProbeCaseResult>();
        foreach (var probeCase in request.Cases)
        {
            var result = probeCase.Operation switch
            {
                "Parse" => OverlaySettings.ParseJson(RequireJson(probeCase)),
                "Select" => Select(probeCase),
                "Load" => Load(probeCase),
                "SaveReload" => SaveReload(probeCase),
                _ => throw new ArgumentException($"不支持的设置探针操作：{probeCase.Operation}")
            };
            results.Add(new SettingsProbeCaseResult(probeCase.Name, result.Settings, result.MustPersist));
        }

        return new SettingsProbeResult(results);
    }

    private static OverlaySettingsLoadResult Select(SettingsProbeCase probeCase)
    {
        var result = OverlaySettings.ParseJson(RequireJson(probeCase));
        if (!Enum.TryParse<CollapsedSlot>(probeCase.Slot, ignoreCase: true, out var slot)
            || !probeCase.Field.HasValue)
        {
            throw new ArgumentException("Select 设置探针需要有效的 Slot 和 Field。", nameof(probeCase));
        }

        result.Settings.SelectCollapsedField(slot, (DisplayField)probeCase.Field.Value);
        return result;
    }

    private static OverlaySettingsLoadResult Load(SettingsProbeCase probeCase)
    {
        var path = RequireTemporaryPath(probeCase);
        if (probeCase.Json is not null)
        {
            var directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.WriteAllText(path, probeCase.Json, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        }

        var result = OverlaySettings.LoadFromFile(path);
        if (result.MustPersist)
        {
            result.Settings.Save(path);
        }

        return result;
    }

    private static OverlaySettingsLoadResult SaveReload(SettingsProbeCase probeCase)
    {
        var path = RequireTemporaryPath(probeCase);
        var parsed = OverlaySettings.ParseJson(RequireJson(probeCase));
        parsed.Settings.Save(path);
        return new OverlaySettingsLoadResult(OverlaySettings.Load(path), false);
    }

    private static string RequireJson(SettingsProbeCase probeCase)
    {
        return probeCase.Json ?? throw new ArgumentException(
            "设置探针操作需要 Json。",
            nameof(probeCase));
    }

    private static string RequireTemporaryPath(SettingsProbeCase probeCase)
    {
        if (string.IsNullOrWhiteSpace(probeCase.SettingsPath)
            || !Path.IsPathFullyQualified(probeCase.SettingsPath))
        {
            throw new ArgumentException(
                "设置探针需要绝对临时设置路径。",
                nameof(probeCase));
        }

        var path = Path.GetFullPath(probeCase.SettingsPath);
        var temporaryRoot = Path.GetFullPath(Path.GetTempPath());
        if (!path.StartsWith(temporaryRoot, StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException(
                "设置探针只能使用临时设置路径。",
                nameof(probeCase));
        }

        return path;
    }
}
