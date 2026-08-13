using System.Drawing;

namespace CodexTokenOverlay;

internal enum AttachmentReferencePoint
{
    TopLeft,
    TopCenter,
    TopRight,
    LeftCenter,
    RightCenter,
    BottomLeft,
    BottomCenter,
    BottomRight
}

internal sealed record WindowAttachment(
    AttachmentReferencePoint ReferencePoint,
    double OffsetXDip,
    double OffsetYDip);

internal sealed record ManualPlacementSnapshot(
    bool Enabled,
    WindowAttachment MainAttachment,
    int ScalePercent);

internal sealed record AttachmentTargetBounds(
    long MainHandle,
    IntRect MainBounds,
    IntRect WorkingArea,
    uint Dpi);

internal sealed record AttachmentTargetHit(
    long Handle,
    IntRect Bounds);

internal static class ManualAttachmentRules
{
    public const int MinimumScalePercent = 60;
    public const int MaximumScalePercent = 130;
    public const int DefaultScalePercent = 100;
    public const double MaximumAbsoluteOffsetDip = 4096d;

    public static readonly WindowAttachment DefaultMainAttachment =
        new(AttachmentReferencePoint.TopRight, -344d, 24d);

    public static int SanitizeScale(int? value) =>
        Math.Clamp(value ?? DefaultScalePercent, MinimumScalePercent, MaximumScalePercent);

    public static WindowAttachment SanitizeMain(WindowAttachment? value) =>
        TrySanitize(value, out var result) ? result : DefaultMainAttachment;

    public static bool TrySanitize(WindowAttachment? value, out WindowAttachment result)
    {
        if (value is not null
            && Enum.IsDefined(value.ReferencePoint)
            && double.IsFinite(value.OffsetXDip)
            && double.IsFinite(value.OffsetYDip)
            && Math.Abs(value.OffsetXDip) <= MaximumAbsoluteOffsetDip
            && Math.Abs(value.OffsetYDip) <= MaximumAbsoluteOffsetDip)
        {
            result = new WindowAttachment(
                value.ReferencePoint,
                value.OffsetXDip,
                value.OffsetYDip);
            return true;
        }

        result = null!;
        return false;
    }
}

internal static class ManualAttachmentCalculator
{
    public static AttachmentReferencePoint SelectReferencePoint(IntRect target, Point center)
    {
        ValidateTarget(target);
        return EnumerateReferencePoints(target)
            .Select(item => (item.Kind, Distance: SquaredDistance(item.Point, center)))
            .OrderBy(item => item.Distance)
            .ThenBy(item => item.Kind)
            .First().Kind;
    }

    public static WindowAttachment Capture(IntRect target, Point center, uint dpi)
    {
        ValidateTargetAndDpi(target, dpi);
        var referencePoint = SelectReferencePoint(target, center);
        var referencePosition = GetReferencePoint(target, referencePoint);
        return new WindowAttachment(
            referencePoint,
            ((long)center.X - referencePosition.X) * 96d / dpi,
            ((long)center.Y - referencePosition.Y) * 96d / dpi);
    }

    public static Point ResolveCenter(IntRect target, WindowAttachment attachment, uint dpi)
    {
        ArgumentNullException.ThrowIfNull(attachment);
        ValidateTargetAndDpi(target, dpi);
        var referencePosition = GetReferencePoint(target, attachment.ReferencePoint);
        var offsetX = (int)Math.Round(
            attachment.OffsetXDip * dpi / 96d,
            MidpointRounding.AwayFromZero);
        var offsetY = (int)Math.Round(
            attachment.OffsetYDip * dpi / 96d,
            MidpointRounding.AwayFromZero);
        return new Point(
            checked(referencePosition.X + offsetX),
            checked(referencePosition.Y + offsetY));
    }

    public static AttachmentTargetHit? SelectTarget(
        AttachmentTargetBounds targets,
        Point cursor,
        bool hostSurfaceHit)
    {
        return hostSurfaceHit && !targets.MainBounds.IsEmpty && targets.MainBounds.Contains(cursor.X, cursor.Y)
            ? new AttachmentTargetHit(
                targets.MainHandle,
                targets.MainBounds)
            : null;
    }

    public static int CalculateScale(
        Size startSize,
        int startScalePercent,
        int deltaX,
        int deltaY)
    {
        var sanitizedStartScale = ManualAttachmentRules.SanitizeScale(startScalePercent);
        if (startSize.Width <= 0 || startSize.Height <= 0)
        {
            return sanitizedStartScale;
        }

        var widthRatio = Math.Max(0d, ((double)startSize.Width + deltaX) / startSize.Width);
        var heightRatio = Math.Max(0d, ((double)startSize.Height + deltaY) / startSize.Height);
        var desiredScale = (int)Math.Round(
            sanitizedStartScale * Math.Max(widthRatio, heightRatio),
            MidpointRounding.AwayFromZero);
        return ManualAttachmentRules.SanitizeScale(desiredScale);
    }

    private static IReadOnlyList<(AttachmentReferencePoint Kind, Point Point)> EnumerateReferencePoints(
        IntRect target) =>
        [
            (AttachmentReferencePoint.TopLeft, new Point(target.Left, target.Top)),
            (AttachmentReferencePoint.TopCenter, new Point(CenterX(target), target.Top)),
            (AttachmentReferencePoint.TopRight, new Point(target.Right, target.Top)),
            (AttachmentReferencePoint.LeftCenter, new Point(target.Left, CenterY(target))),
            (AttachmentReferencePoint.RightCenter, new Point(target.Right, CenterY(target))),
            (AttachmentReferencePoint.BottomLeft, new Point(target.Left, target.Bottom)),
            (AttachmentReferencePoint.BottomCenter, new Point(CenterX(target), target.Bottom)),
            (AttachmentReferencePoint.BottomRight, new Point(target.Right, target.Bottom))
        ];

    private static Point GetReferencePoint(IntRect target, AttachmentReferencePoint referencePoint)
    {
        if (!Enum.IsDefined(referencePoint))
        {
            throw new ArgumentOutOfRangeException(nameof(referencePoint));
        }

        return EnumerateReferencePoints(target)[(int)referencePoint].Point;
    }

    private static int CenterX(IntRect target) => target.Left + (target.Width / 2);

    private static int CenterY(IntRect target) => target.Top + (target.Height / 2);

    private static long SquaredDistance(Point left, Point right)
    {
        var deltaX = (long)left.X - right.X;
        var deltaY = (long)left.Y - right.Y;
        return checked((deltaX * deltaX) + (deltaY * deltaY));
    }

    private static void ValidateTargetAndDpi(IntRect target, uint dpi)
    {
        ValidateTarget(target);
        if (dpi == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(dpi));
        }
    }

    private static void ValidateTarget(IntRect target)
    {
        if (target.IsEmpty)
        {
            throw new ArgumentOutOfRangeException(nameof(target));
        }
    }
}

internal sealed class ManualPlacementEditState
{
    private ManualPlacementSnapshot? _original;
    private ManualPlacementSnapshot? _draft;

    public bool IsActive => _draft is not null;

    public ManualPlacementSnapshot Draft =>
        _draft ?? throw new InvalidOperationException("手动定位编辑尚未开始。");

    public void Begin(ManualPlacementSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (IsActive)
        {
            throw new InvalidOperationException("手动定位编辑已经开始。");
        }

        _original = snapshot;
        _draft = snapshot with { };
    }

    public void ApplyAttachment(WindowAttachment attachment)
    {
        ArgumentNullException.ThrowIfNull(attachment);
        _draft = Draft with { MainAttachment = attachment };
    }

    public void ApplyScale(int scalePercent)
    {
        _draft = Draft with
        {
            ScalePercent = ManualAttachmentRules.SanitizeScale(scalePercent)
        };
    }

    public void ApplyEnabled(bool enabled)
    {
        _draft = Draft with { Enabled = enabled };
    }

    public ManualPlacementSnapshot Commit()
    {
        var committed = Draft;
        End();
        return committed;
    }

    public ManualPlacementSnapshot Cancel()
    {
        _ = Draft;
        var original = _original
            ?? throw new InvalidOperationException("手动定位编辑尚未开始。");
        End();
        return original;
    }

    private void End()
    {
        _original = null;
        _draft = null;
    }
}

internal sealed record ManualAttachmentTransition(
    ManualPlacementSnapshot Draft,
    bool IsEditing,
    bool CanSave,
    bool RequiresPersist,
    bool ShouldCollapse,
    IntRect? HighlightBounds,
    Point? ResolvedCenter);

internal sealed class ManualAttachmentCoordinator
{
    private readonly ManualPlacementEditState _editState = new();
    private bool _canSave;
    private bool _gesturePreviewActive;

    public bool IsEditing => _editState.IsActive;

    public ManualPlacementSnapshot Draft => _editState.Draft;

    public bool CanSave => IsEditing && _canSave;

    public bool ShouldApplyStaticDraft => IsEditing && !_gesturePreviewActive;

    public bool ShouldShowStaticHighlight => ShouldApplyStaticDraft && CanSave;

    public ManualAttachmentTransition BeginEdit(
        ManualPlacementSnapshot original,
        AttachmentTargetBounds targets)
    {
        ArgumentNullException.ThrowIfNull(original);
        ArgumentNullException.ThrowIfNull(targets);
        _gesturePreviewActive = false;
        _editState.Begin(SanitizeSnapshot(original));
        _editState.ApplyEnabled(true);
        var target = ResolveMainTarget(targets);
        _canSave = target is not null;
        return Transition(
            _editState.Draft,
            requiresPersist: false,
            shouldCollapse: true,
            target?.Bounds,
            ResolveCenter(_editState.Draft, targets));
    }

    public void BeginGesturePreview()
    {
        _ = Draft;
        _gesturePreviewActive = true;
    }

    public void EndGesturePreview()
    {
        _ = Draft;
        _gesturePreviewActive = false;
    }

    public ManualAttachmentTransition PreviewMove(
        AttachmentTargetBounds targets,
        Point cursor,
        Point capsuleCenter,
        bool hostSurfaceHit)
    {
        _ = Draft;
        var hit = ManualAttachmentCalculator.SelectTarget(targets, cursor, hostSurfaceHit);
        _canSave = hit is not null;
        return Transition(
            Draft,
            requiresPersist: false,
            shouldCollapse: true,
            hit?.Bounds,
            hit is null ? ResolveCenter(Draft, targets) : capsuleCenter);
    }

    public ManualAttachmentTransition CompleteMove(
        AttachmentTargetBounds targets,
        Point cursor,
        Point capsuleCenter,
        bool hostSurfaceHit)
    {
        _ = Draft;
        var hit = ManualAttachmentCalculator.SelectTarget(targets, cursor, hostSurfaceHit);
        if (hit is null)
        {
            _canSave = false;
            return Transition(
                Draft,
                requiresPersist: false,
                shouldCollapse: true,
                highlightBounds: null,
                ResolveCenter(Draft, targets));
        }

        _editState.ApplyAttachment(
            ManualAttachmentCalculator.Capture(hit.Bounds, capsuleCenter, targets.Dpi));
        _editState.ApplyEnabled(true);
        _canSave = true;
        return Transition(
            Draft,
            requiresPersist: false,
            shouldCollapse: true,
            hit.Bounds,
            ManualAttachmentCalculator.ResolveCenter(
                hit.Bounds,
                Draft.MainAttachment,
                targets.Dpi));
    }

    public ManualAttachmentTransition PreviewResize(
        AttachmentTargetBounds targets,
        Point fixedTopLeft,
        int scalePercent,
        CollapsedDisplayMode display)
    {
        var draft = Draft;
        var target = ResolveMainTarget(targets);
        if (target is null || targets.Dpi == 0)
        {
            _canSave = false;
            return Transition(
                draft,
                requiresPersist: false,
                shouldCollapse: true,
                highlightBounds: null,
                resolvedCenter: null);
        }

        var sanitizedScale = ManualAttachmentRules.SanitizeScale(scalePercent);
        var size = OverlayLayoutCalculator.GetCollapsedSize(
            targets.Dpi,
            sanitizedScale,
            display);
        var center = new Point(
            checked(fixedTopLeft.X + (size.Width / 2)),
            checked(fixedTopLeft.Y + (size.Height / 2)));
        _editState.ApplyScale(sanitizedScale);
        _editState.ApplyAttachment(
            ManualAttachmentCalculator.Capture(target.Bounds, center, targets.Dpi));
        _editState.ApplyEnabled(true);
        _canSave = true;
        return Transition(
            Draft,
            requiresPersist: false,
            shouldCollapse: true,
            target.Bounds,
            center);
    }

    public ManualAttachmentTransition Commit()
    {
        if (!CanSave)
        {
            throw new InvalidOperationException("当前手势没有有效的 Codex 吸附目标。");
        }

        var committed = _editState.Commit() with { Enabled = true };
        _canSave = false;
        _gesturePreviewActive = false;
        return Transition(
            committed,
            requiresPersist: true,
            shouldCollapse: true,
            highlightBounds: null,
            resolvedCenter: null);
    }

    public ManualAttachmentTransition Cancel()
    {
        var cancelled = _editState.Cancel();
        _canSave = false;
        _gesturePreviewActive = false;
        return Transition(
            cancelled,
            requiresPersist: false,
            shouldCollapse: true,
            highlightBounds: null,
            resolvedCenter: null);
    }

    public static Point? ResolveCenter(
        ManualPlacementSnapshot snapshot,
        AttachmentTargetBounds targets)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(targets);
        var target = ResolveMainTarget(targets);
        if (target is null || targets.Dpi == 0)
        {
            return null;
        }

        return ManualAttachmentCalculator.ResolveCenter(
            target.Bounds,
            snapshot.MainAttachment,
            targets.Dpi);
    }

    private ManualAttachmentTransition Transition(
        ManualPlacementSnapshot snapshot,
        bool requiresPersist,
        bool shouldCollapse,
        IntRect? highlightBounds,
        Point? resolvedCenter) => new(
            snapshot,
            IsEditing,
            CanSave,
            requiresPersist,
            shouldCollapse,
            highlightBounds,
            resolvedCenter);

    private static ManualPlacementSnapshot SanitizeSnapshot(ManualPlacementSnapshot snapshot)
    {
        return new ManualPlacementSnapshot(
            snapshot.Enabled,
            ManualAttachmentRules.SanitizeMain(snapshot.MainAttachment),
            ManualAttachmentRules.SanitizeScale(snapshot.ScalePercent));
    }

    private static AttachmentTargetHit? ResolveMainTarget(AttachmentTargetBounds targets) =>
        !targets.MainBounds.IsEmpty
            ? new AttachmentTargetHit(targets.MainHandle, targets.MainBounds)
            : null;
}
