using System.Drawing.Drawing2D;

namespace CodexTokenOverlay;

internal enum OverlayEditGestureKind
{
    Move,
    Resize
}

internal sealed record OverlayEditPreviewEventArgs(
    OverlayEditGestureKind Kind,
    Point CursorScreen,
    Point FixedTopLeft,
    int ScalePercent);

internal readonly record struct OverlayRenderMetrics(
    double LabelFontPoints,
    double CompactValueFontPoints,
    double PanelHeaderFontPoints,
    double HighlightedValueFontPoints,
    int CapsuleRadius,
    int PanelRadius,
    int HorizontalPadding,
    int MetricGap,
    int DividerHeight,
    int PanelPadding,
    int HeaderHeight,
    int HighlightTopGap,
    int HighlightHeight,
    int ProgressTrackHeight,
    int ProgressVerticalGap,
    int CompactMetricGap,
    int EditHandleSize,
    int StrokeWidth)
{
    public static OverlayRenderMetrics Create(uint dpi, int scalePercent)
    {
        var effectiveDpi = dpi == 0 ? 96u : dpi;
        var sanitizedScale = ManualAttachmentRules.SanitizeScale(scalePercent);
        var userFactor = sanitizedScale / 100d;
        var pixelFactor = effectiveDpi / 96d * userFactor;
        int Scale(int dip) => (int)Math.Round(
            dip * pixelFactor,
            MidpointRounding.AwayFromZero);
        double ScaleFont(double points) => Math.Round(
            points * userFactor,
            2,
            MidpointRounding.AwayFromZero);

        return new OverlayRenderMetrics(
            ScaleFont(10d),
            ScaleFont(12d),
            ScaleFont(13d),
            ScaleFont(15d),
            Scale(10),
            Scale(14),
            Scale(10),
            Scale(8),
            Scale(14),
            Scale(14),
            Scale(22),
            Scale(6),
            Scale(44),
            Math.Max(1, Scale(4)),
            Scale(10),
            Scale(4),
            Math.Max(1, Scale(12)),
            Math.Max(1, Scale(1)));
    }
}

internal readonly record struct OverlayRenderDecorationState(
    bool ShowBorder,
    bool ShowDragHint,
    bool ShowResizeHandle,
    string DragHintText,
    IntRect DragHintBounds,
    double DragHintFontPoints);

internal sealed class TokenStripForm : Form
{
    private const int WsExToolWindow = 0x00000080;
    private const int WsExNoActivate = 0x08000000;
    private const int CsDropShadow = 0x00020000;
    private const int WmMouseActivate = 0x0021;
    private const int WmNcHitTest = 0x0084;
    private const int MaNoActivate = 3;
    private const int HtTransparent = -1;

    private const TextFormatFlags TextFlags = TextFormatFlags.NoPadding
        | TextFormatFlags.SingleLine
        | TextFormatFlags.EndEllipsis
        | TextFormatFlags.VerticalCenter;

    private OverlayPresentation _presentation;
    private OverlayThemePalette _palette = OverlayThemePalette.For(OverlayThemeKind.Dark);
    private OverlayEditGestureKind? _editGesture;
    private Point _gestureStartCursorScreen;
    private Rectangle _gestureStartBounds;
    private Point _fixedTopLeft;
    private int _gestureStartScalePercent = ManualAttachmentRules.DefaultScalePercent;
    private OverlayEditPreviewEventArgs? _lastEditPreview;

    public TokenStripForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = _palette.Background;
        ForeColor = _palette.Value;
        Opacity = 0.97;
        DoubleBuffered = true;

        _presentation = OverlayPresentationBuilder.CreateWaiting(
            string.Empty,
            DisplayField.Total,
            DisplayField.ContextPercent,
            DisplayField.Total | DisplayField.ContextPercent);
        ApplyLayout(new OverlayLayoutResult(
            OverlayVisualState.Collapsed,
            CollapsedDisplayMode.TwoFields,
            ExpansionDirection.Down,
            96,
            new IntRect(0, 0, 196, 34),
            new IntRect(0, 0, 196, 34),
            default,
            0));
    }

    public event EventHandler? CapsuleClicked;
    public event EventHandler<OverlayEditPreviewEventArgs>? EditPreviewChanged;
    public event EventHandler<OverlayEditPreviewEventArgs>? EditGestureCompleted;
    public event EventHandler? EditSaveRequested;
    public event EventHandler? EditCancelRequested;

    public OverlayLayoutResult? CurrentLayout { get; private set; }
    public bool IsEditMode { get; private set; }
    internal OverlayPresentation CurrentPresentation => _presentation;
    internal OverlayThemePalette CurrentThemePalette => _palette;

    internal int SetBoundsCoreCallCount { get; private set; }
    internal bool IsEditGestureActive => _editGesture is not null;
    internal OverlayRenderDecorationState RenderDecorations
    {
        get
        {
            if (!IsEditMode
                || CurrentLayout is null
                || CurrentLayout.CapsuleBounds.IsEmpty)
            {
                return new OverlayRenderDecorationState(
                    false,
                    false,
                    false,
                    string.Empty,
                    default,
                    0d);
            }

            var metrics = OverlayRenderMetrics.Create(
                CurrentLayout.Dpi,
                CurrentLayout.ScalePercent);
            var capsule = CurrentLayout.CapsuleBounds.ToRectangle();
            var content = Rectangle.Inflate(
                capsule,
                -metrics.HorizontalPadding,
                0);
            var hintRight = Math.Max(
                content.Left,
                content.Right - metrics.EditHandleSize - metrics.MetricGap);
            return new OverlayRenderDecorationState(
                true,
                true,
                true,
                "拖动调整位置",
                new IntRect(
                    content.Left,
                    content.Top,
                    hintRight - content.Left,
                    content.Height),
                metrics.LabelFontPoints);
        }
    }

    internal Rectangle EditResizeHandleBounds
    {
        get
        {
            if (CurrentLayout is null || CurrentLayout.CapsuleBounds.IsEmpty)
            {
                return Rectangle.Empty;
            }

            var metrics = OverlayRenderMetrics.Create(
                CurrentLayout.Dpi,
                CurrentLayout.ScalePercent);
            var capsule = CurrentLayout.CapsuleBounds.ToRectangle();
            var size = Math.Min(
                metrics.EditHandleSize,
                Math.Min(capsule.Width, capsule.Height));
            return new Rectangle(
                capsule.Right - size,
                capsule.Bottom - size,
                size,
                size);
        }
    }

    protected override bool ShowWithoutActivation => !IsEditMode;

    protected override CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.ExStyle |= WsExToolWindow;
            if (!IsEditMode)
            {
                parameters.ExStyle |= WsExNoActivate;
            }
            parameters.ClassStyle |= CsDropShadow;
            return parameters;
        }
    }

    public void SetPresentation(OverlayPresentation presentation)
    {
        ArgumentNullException.ThrowIfNull(presentation);
        _presentation = presentation;
        Invalidate();
    }

    public void ApplyTheme(OverlayThemePalette palette)
    {
        ArgumentNullException.ThrowIfNull(palette);
        if (_palette == palette)
        {
            return;
        }

        _palette = palette;
        BackColor = palette.Background;
        ForeColor = palette.Value;
        Invalidate();
    }

    public void ApplyLayout(OverlayLayoutResult layout)
    {
        ArgumentNullException.ThrowIfNull(layout);
        CurrentLayout = layout;
        SetBounds(
            layout.WindowBounds.X,
            layout.WindowBounds.Y,
            layout.WindowBounds.Width,
            layout.WindowBounds.Height,
            BoundsSpecified.All);

        var metrics = OverlayRenderMetrics.Create(layout.Dpi, layout.ScalePercent);
        using var combined = new GraphicsPath();
        if (!layout.CapsuleBounds.IsEmpty)
        {
            using var capsule = CreateRoundedRectanglePath(
                layout.CapsuleBounds.ToRectangle(),
                metrics.CapsuleRadius);
            combined.AddPath(capsule, connect: false);
        }
        if (!layout.PanelBounds.IsEmpty)
        {
            using var panel = CreateRoundedRectanglePath(
                layout.PanelBounds.ToRectangle(),
                metrics.PanelRadius);
            combined.AddPath(panel, connect: false);
        }

        Region?.Dispose();
        Region = new Region(combined);
        Invalidate();
    }

    public void BeginEditMode(int scalePercent)
    {
        if (IsEditMode)
        {
            return;
        }
        if (CurrentLayout?.State != OverlayVisualState.Collapsed
            || !CurrentLayout.PanelBounds.IsEmpty)
        {
            throw new InvalidOperationException("编辑模式只能从收起布局开始。");
        }

        _gestureStartScalePercent = ManualAttachmentRules.SanitizeScale(scalePercent);
        IsEditMode = true;
        if (IsHandleCreated)
        {
            RecreateHandle();
        }
        Activate();
        Focus();
        Invalidate();
    }

    public void EndEditMode()
    {
        if (!IsEditMode)
        {
            return;
        }

        CancelEditGesture();
        IsEditMode = false;
        if (IsHandleCreated)
        {
            RecreateHandle();
        }
        Invalidate();
    }

    internal void SimulateCapsuleClick(Point screenPoint) =>
        HandleMouseUp(MouseButtons.Left, PointToClient(screenPoint), screenPoint);

    internal void SimulateEditDrag(Point startScreen, Point currentScreen)
    {
        HandleMouseDown(MouseButtons.Left, PointToClient(startScreen), startScreen);
        HandleMouseMove(PointToClient(currentScreen), currentScreen);
    }

    internal void SimulateEditResize(Point startScreen, Point currentScreen)
    {
        HandleMouseDown(MouseButtons.Left, PointToClient(startScreen), startScreen);
        HandleMouseMove(PointToClient(currentScreen), currentScreen);
    }

    internal void SimulateEditGestureCompleted(Point currentScreen) =>
        HandleMouseUp(MouseButtons.Left, PointToClient(currentScreen), currentScreen);

    internal void SimulateEditCaptureLost()
    {
        Capture = false;
        if (_editGesture is not null)
        {
            OnMouseCaptureChanged(EventArgs.Empty);
        }
    }

    internal bool SimulateEditCommand(Keys keyData) => HandleEditCommand(keyData);

    public bool ContainsScreenPoint(Point screenPoint) =>
        CurrentLayout?.ContainsScreenPoint(screenPoint) == true;

    protected override void SetBoundsCore(
        int x,
        int y,
        int width,
        int height,
        BoundsSpecified specified)
    {
        SetBoundsCoreCallCount++;
        base.SetBoundsCore(x, y, width, height, specified);
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WmMouseActivate && !IsEditMode)
        {
            message.Result = (IntPtr)MaNoActivate;
            return;
        }

        if (message.Msg == WmNcHitTest && CurrentLayout is not null)
        {
            var packed = message.LParam.ToInt64();
            var screenPoint = new Point(
                unchecked((short)(packed & 0xffff)),
                unchecked((short)((packed >> 16) & 0xffff)));
            var clientPoint = PointToClient(screenPoint);
            if (!CurrentLayout.CapsuleBounds.Contains(clientPoint.X, clientPoint.Y)
                && !CurrentLayout.PanelBounds.Contains(clientPoint.X, clientPoint.Y))
            {
                message.Result = (IntPtr)HtTransparent;
                return;
            }
        }

        base.WndProc(ref message);
    }

    protected override void OnMouseDown(MouseEventArgs eventArgs)
    {
        base.OnMouseDown(eventArgs);
        HandleMouseDown(
            eventArgs.Button,
            eventArgs.Location,
            PointToScreen(eventArgs.Location));
    }

    protected override void OnMouseMove(MouseEventArgs eventArgs)
    {
        base.OnMouseMove(eventArgs);
        HandleMouseMove(eventArgs.Location, PointToScreen(eventArgs.Location));
    }

    protected override void OnMouseUp(MouseEventArgs eventArgs)
    {
        base.OnMouseUp(eventArgs);
        HandleMouseUp(
            eventArgs.Button,
            eventArgs.Location,
            PointToScreen(eventArgs.Location));
    }

    protected override void OnMouseCaptureChanged(EventArgs eventArgs)
    {
        base.OnMouseCaptureChanged(eventArgs);
        if (Capture || _editGesture is null)
        {
            return;
        }

        if (_lastEditPreview is not null)
        {
            CompleteEditGesture(_lastEditPreview, releaseCapture: false);
        }
        else
        {
            CancelEditGesture(releaseCapture: false);
        }
    }

    protected override bool ProcessCmdKey(ref Message message, Keys keyData)
    {
        if (IsEditMode && HandleEditCommand(keyData))
        {
            return true;
        }

        return base.ProcessCmdKey(ref message, keyData);
    }

    private void HandleMouseDown(MouseButtons button, Point clientPoint, Point cursorScreen)
    {
        if (!IsEditMode
            || button != MouseButtons.Left
            || CurrentLayout is null
            || !CurrentLayout.CapsuleBounds.Contains(clientPoint.X, clientPoint.Y))
        {
            return;
        }

        _editGesture = EditResizeHandleBounds.Contains(clientPoint)
            ? OverlayEditGestureKind.Resize
            : OverlayEditGestureKind.Move;
        _gestureStartCursorScreen = cursorScreen;
        _gestureStartBounds = Bounds;
        _fixedTopLeft = Location;
        _gestureStartScalePercent = ManualAttachmentRules.SanitizeScale(
            CurrentLayout.ScalePercent);
        _lastEditPreview = null;
        Capture = true;
    }

    private void HandleMouseMove(Point clientPoint, Point cursorScreen)
    {
        _ = clientPoint;
        if (!IsEditMode || _editGesture is null)
        {
            return;
        }

        var deltaX = cursorScreen.X - _gestureStartCursorScreen.X;
        var deltaY = cursorScreen.Y - _gestureStartCursorScreen.Y;
        var scalePercent = _gestureStartScalePercent;
        if (_editGesture == OverlayEditGestureKind.Move)
        {
            Location = new Point(
                _gestureStartBounds.X + deltaX,
                _gestureStartBounds.Y + deltaY);
        }
        else
        {
            scalePercent = ManualAttachmentCalculator.CalculateScale(
                _gestureStartBounds.Size,
                _gestureStartScalePercent,
                deltaX,
                deltaY);
        }

        _lastEditPreview = new OverlayEditPreviewEventArgs(
            _editGesture.Value,
            cursorScreen,
            _fixedTopLeft,
            scalePercent);
        EditPreviewChanged?.Invoke(this, _lastEditPreview);
    }

    private void HandleMouseUp(MouseButtons button, Point clientPoint, Point cursorScreen)
    {
        if (button != MouseButtons.Left)
        {
            return;
        }

        if (IsEditMode)
        {
            if (_editGesture is null)
            {
                return;
            }

            HandleMouseMove(clientPoint, cursorScreen);
            var completed = _lastEditPreview ?? new OverlayEditPreviewEventArgs(
                _editGesture.Value,
                cursorScreen,
                _fixedTopLeft,
                _gestureStartScalePercent);
            CompleteEditGesture(completed, releaseCapture: true);
            return;
        }

        if (CurrentLayout is not null
            && CurrentLayout.CapsuleBounds.Contains(clientPoint.X, clientPoint.Y))
        {
            CapsuleClicked?.Invoke(this, EventArgs.Empty);
        }
    }

    private void CompleteEditGesture(
        OverlayEditPreviewEventArgs completed,
        bool releaseCapture)
    {
        _editGesture = null;
        _lastEditPreview = null;
        if (releaseCapture && Capture)
        {
            Capture = false;
        }
        EditGestureCompleted?.Invoke(this, completed);
    }

    private void CancelEditGesture(bool releaseCapture = true)
    {
        _editGesture = null;
        _lastEditPreview = null;
        if (releaseCapture && Capture)
        {
            Capture = false;
        }
    }

    private bool HandleEditCommand(Keys keyData)
    {
        if (!IsEditMode)
        {
            return false;
        }

        switch (keyData & Keys.KeyCode)
        {
            case Keys.Enter:
                EditSaveRequested?.Invoke(this, EventArgs.Empty);
                return true;
            case Keys.Escape:
                EditCancelRequested?.Invoke(this, EventArgs.Empty);
                return true;
            default:
                return false;
        }
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        if (CurrentLayout is null)
        {
            return;
        }

        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var metrics = OverlayRenderMetrics.Create(
            CurrentLayout.Dpi,
            CurrentLayout.ScalePercent);
        var decorations = RenderDecorations;
        using var labelFont = new Font(
            "Segoe UI",
            (float)(decorations.ShowDragHint
                ? decorations.DragHintFontPoints
                : metrics.LabelFontPoints),
            FontStyle.Regular,
            GraphicsUnit.Point);
        using var compactValueFont = new Font(
            "Segoe UI Semibold",
            (float)metrics.CompactValueFontPoints,
            FontStyle.Regular,
            GraphicsUnit.Point);
        using var panelHeaderFont = new Font(
            "Segoe UI Semibold",
            (float)metrics.PanelHeaderFontPoints,
            FontStyle.Regular,
            GraphicsUnit.Point);
        using var highlightedValueFont = new Font(
            "Segoe UI Semibold",
            (float)metrics.HighlightedValueFontPoints,
            FontStyle.Regular,
            GraphicsUnit.Point);
        using var backgroundBrush = new SolidBrush(_palette.Background);
        using var borderPen = new Pen(_palette.Border, metrics.StrokeWidth);
        using var dividerPen = new Pen(_palette.Divider, metrics.StrokeWidth);
        using var progressTrackBrush = new SolidBrush(_palette.ProgressTrack);

        DrawCapsule(
            eventArgs.Graphics,
            labelFont,
            compactValueFont,
            backgroundBrush,
            borderPen,
            dividerPen,
            metrics,
            decorations);
        if (!CurrentLayout.PanelBounds.IsEmpty)
        {
            DrawPanel(
                eventArgs.Graphics,
                labelFont,
                compactValueFont,
                panelHeaderFont,
                highlightedValueFont,
                backgroundBrush,
                borderPen,
                dividerPen,
                progressTrackBrush,
                metrics,
                decorations);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            CancelEditGesture();
            Region?.Dispose();
            Region = null;
        }
        base.Dispose(disposing);
    }

    private void DrawCapsule(
        Graphics graphics,
        Font labelFont,
        Font valueFont,
        Brush backgroundBrush,
        Pen borderPen,
        Pen dividerPen,
        OverlayRenderMetrics metrics,
        OverlayRenderDecorationState decorations)
    {
        var layout = CurrentLayout!;
        var bounds = layout.CapsuleBounds.ToRectangle();
        using var path = CreateRoundedRectanglePath(bounds, metrics.CapsuleRadius);
        graphics.FillPath(backgroundBrush, path);
        if (decorations.ShowBorder)
        {
            graphics.DrawPath(borderPen, path);
        }

        if (decorations.ShowDragHint)
        {
            TextRenderer.DrawText(
                graphics,
                decorations.DragHintText,
                labelFont,
                decorations.DragHintBounds.ToRectangle(),
                _palette.Label,
                TextFlags | TextFormatFlags.HorizontalCenter);
            DrawEditHandle(graphics, dividerPen, metrics, decorations);
            return;
        }

        var padding = metrics.HorizontalPadding;
        var content = Rectangle.Inflate(bounds, -padding, 0);
        if (!string.IsNullOrWhiteSpace(_presentation.StatusText))
        {
            TextRenderer.DrawText(
                graphics,
                _presentation.StatusText,
                labelFont,
                content,
                _palette.Label,
                TextFlags | TextFormatFlags.HorizontalCenter);
            DrawEditHandle(graphics, dividerPen, metrics, decorations);
            return;
        }

        if (layout.CollapsedDisplay == CollapsedDisplayMode.PrimaryOnly)
        {
            DrawCompactMetric(graphics, _presentation.Primary, content, labelFont, valueFont, metrics);
            DrawEditHandle(graphics, dividerPen, metrics, decorations);
            return;
        }

        var gap = metrics.MetricGap;
        var dividerX = content.Left + (content.Width / 2);
        var dividerHeight = Math.Min(metrics.DividerHeight, content.Height);
        var dividerTop = content.Top + ((content.Height - dividerHeight) / 2);
        graphics.DrawLine(dividerPen, dividerX, dividerTop, dividerX, dividerTop + dividerHeight);

        var primaryBounds = Rectangle.FromLTRB(content.Left, content.Top, dividerX - gap, content.Bottom);
        var secondaryBounds = Rectangle.FromLTRB(dividerX + gap, content.Top, content.Right, content.Bottom);
        DrawCompactMetric(graphics, _presentation.Primary, primaryBounds, labelFont, valueFont, metrics);
        DrawCompactMetric(graphics, _presentation.Secondary, secondaryBounds, labelFont, valueFont, metrics);
        DrawEditHandle(graphics, dividerPen, metrics, decorations);
    }

    private void DrawEditHandle(
        Graphics graphics,
        Pen pen,
        OverlayRenderMetrics metrics,
        OverlayRenderDecorationState decorations)
    {
        if (!decorations.ShowResizeHandle || EditResizeHandleBounds.IsEmpty)
        {
            return;
        }

        var handle = EditResizeHandleBounds;
        var inset = metrics.StrokeWidth;
        var middle = Math.Max(inset, handle.Width / 2);
        graphics.DrawLine(
            pen,
            handle.Right - middle,
            handle.Bottom - inset,
            handle.Right - inset,
            handle.Bottom - middle);
        graphics.DrawLine(
            pen,
            handle.Right - Math.Max(inset, handle.Width / 3),
            handle.Bottom - inset,
            handle.Right - inset,
            handle.Bottom - Math.Max(inset, handle.Height / 3));
    }

    private void DrawPanel(
        Graphics graphics,
        Font labelFont,
        Font valueFont,
        Font headerFont,
        Font highlightedValueFont,
        Brush backgroundBrush,
        Pen borderPen,
        Pen dividerPen,
        Brush progressTrackBrush,
        OverlayRenderMetrics metrics,
        OverlayRenderDecorationState decorations)
    {
        var layout = CurrentLayout!;
        var bounds = layout.PanelBounds.ToRectangle();
        using var path = CreateRoundedRectanglePath(bounds, metrics.PanelRadius);
        graphics.FillPath(backgroundBrush, path);
        if (decorations.ShowBorder)
        {
            graphics.DrawPath(borderPen, path);
        }

        var padding = metrics.PanelPadding;
        var content = Rectangle.Inflate(bounds, -padding, -padding);
        var headerHeight = metrics.HeaderHeight;
        TextRenderer.DrawText(
            graphics,
            "Token 详情",
            headerFont,
            new Rectangle(content.Left, content.Top, content.Width, headerHeight),
            _palette.Value,
            TextFlags);

        var highlightTop = content.Top + headerHeight + metrics.HighlightTopGap;
        var highlightHeight = metrics.HighlightHeight;
        var highlightGap = metrics.MetricGap;
        var highlightWidth = Math.Max(0, (content.Width - highlightGap) / 2);
        DrawHighlightedMetric(
            graphics,
            _presentation.Primary,
            new Rectangle(content.Left, highlightTop, highlightWidth, highlightHeight),
            labelFont,
            highlightedValueFont);
        DrawHighlightedMetric(
            graphics,
            _presentation.Secondary,
            new Rectangle(content.Left + highlightWidth + highlightGap, highlightTop, highlightWidth, highlightHeight),
            labelFont,
            highlightedValueFont);

        var rowsHeight = layout.ExpandedRowHeight > 0
            ? layout.ExpandedRowHeight * _presentation.ExpandedRows.Count
            : 0;
        var rowsTop = Math.Max(highlightTop + highlightHeight, bounds.Bottom - padding - rowsHeight);
        if (_presentation.ShowContextProgress)
        {
            var trackHeight = metrics.ProgressTrackHeight;
            var trackTop = Math.Min(
                rowsTop - trackHeight - metrics.ProgressVerticalGap,
                highlightTop + highlightHeight + metrics.ProgressVerticalGap);
            var trackBounds = new Rectangle(content.Left, trackTop, content.Width, trackHeight);
            graphics.FillRectangle(progressTrackBrush, trackBounds);
            var progressWidth = (int)Math.Round(
                trackBounds.Width * Math.Clamp(_presentation.ContextPercent, 0, 100) / 100d,
                MidpointRounding.AwayFromZero);
            if (progressWidth > 0)
            {
                var fillBounds = new Rectangle(trackBounds.X, trackBounds.Y, progressWidth, trackBounds.Height);
                using var fillBrush = new LinearGradientBrush(
                    fillBounds,
                    _palette.ProgressStart,
                    _palette.ProgressEnd,
                    LinearGradientMode.Horizontal);
                graphics.FillRectangle(fillBrush, fillBounds);
            }
        }

        for (var index = 0; index < _presentation.ExpandedRows.Count; index++)
        {
            var row = _presentation.ExpandedRows[index];
            var rowBounds = new Rectangle(
                content.Left,
                rowsTop + (index * layout.ExpandedRowHeight),
                content.Width,
                layout.ExpandedRowHeight);
            graphics.DrawLine(dividerPen, rowBounds.Left, rowBounds.Top, rowBounds.Right, rowBounds.Top);
            DrawExpandedRow(graphics, row, rowBounds, labelFont, valueFont);
        }
    }

    private void DrawCompactMetric(
        Graphics graphics,
        OverlayMetric metric,
        Rectangle bounds,
        Font labelFont,
        Font valueFont,
        OverlayRenderMetrics metrics)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0)
        {
            return;
        }

        var labelWidth = TextRenderer.MeasureText(
            graphics,
            metric.CompactLabel,
            labelFont,
            Size.Empty,
            TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Width;
        var gap = metrics.CompactMetricGap;
        labelWidth = Math.Min(labelWidth, bounds.Width);
        var labelBounds = new Rectangle(bounds.Left, bounds.Top, labelWidth, bounds.Height);
        var valueBounds = Rectangle.FromLTRB(
            Math.Min(bounds.Right, labelBounds.Right + gap),
            bounds.Top,
            bounds.Right,
            bounds.Bottom);
        TextRenderer.DrawText(graphics, metric.CompactLabel, labelFont, labelBounds, _palette.Label, TextFlags);
        TextRenderer.DrawText(
            graphics,
            metric.Value,
            valueFont,
            valueBounds,
            ValueColorFor(metric),
            TextFlags | TextFormatFlags.Right);
    }

    private void DrawHighlightedMetric(
        Graphics graphics,
        OverlayMetric metric,
        Rectangle bounds,
        Font labelFont,
        Font valueFont)
    {
        var labelHeight = Math.Max(1, bounds.Height / 2);
        TextRenderer.DrawText(
            graphics,
            metric.ExpandedLabel,
            labelFont,
            new Rectangle(bounds.Left, bounds.Top, bounds.Width, labelHeight),
            _palette.Label,
            TextFlags);
        TextRenderer.DrawText(
            graphics,
            metric.Value,
            valueFont,
            new Rectangle(bounds.Left, bounds.Top + labelHeight, bounds.Width, bounds.Height - labelHeight),
            ValueColorFor(metric),
            TextFlags);
    }

    private void DrawExpandedRow(
        Graphics graphics,
        OverlayMetric metric,
        Rectangle bounds,
        Font labelFont,
        Font valueFont)
    {
        var labelWidth = Math.Max(0, bounds.Width / 2);
        TextRenderer.DrawText(
            graphics,
            metric.ExpandedLabel,
            labelFont,
            new Rectangle(bounds.Left, bounds.Top, labelWidth, bounds.Height),
            _palette.Label,
            TextFlags);
        TextRenderer.DrawText(
            graphics,
            metric.Value,
            valueFont,
            new Rectangle(bounds.Left + labelWidth, bounds.Top, bounds.Width - labelWidth, bounds.Height),
            ValueColorFor(metric),
            TextFlags | TextFormatFlags.Right);
    }

    private Color ValueColorFor(OverlayMetric metric) =>
        metric.Field is DisplayField.Context or DisplayField.ContextPercent or DisplayField.TotalCost
            ? _palette.Accent
            : _palette.Value;

    private static GraphicsPath CreateRoundedRectanglePath(Rectangle rectangle, int radius)
    {
        var path = new GraphicsPath();
        if (rectangle.Width <= 0 || rectangle.Height <= 0)
        {
            return path;
        }

        var clampedRadius = Math.Clamp(radius, 0, Math.Min(rectangle.Width, rectangle.Height) / 2);
        if (clampedRadius == 0)
        {
            path.AddRectangle(rectangle);
            return path;
        }

        var diameter = clampedRadius * 2;
        path.AddArc(rectangle.Left, rectangle.Top, diameter, diameter, 180, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Top, diameter, diameter, 270, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rectangle.Left, rectangle.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

}
