using System.Runtime.InteropServices;

namespace CodexTokenOverlay;

internal sealed class OverlayContext : ApplicationContext
{
    private readonly OverlaySettings _settings;
    private readonly CodexIpcActiveThreadMonitor _routeMonitor = new();
    private readonly TokenLogMonitor _monitor;
    private readonly TokenStripForm _form = new();
    private readonly AttachmentTargetHighlightForm _targetHighlight = new();
    private readonly OverlayThemeBinding _themeBinding;
    private readonly NotifyIcon _trayIcon;
    private readonly System.Windows.Forms.Timer _timer;
    private readonly System.Windows.Forms.Timer _outsideClickTimer;
    private readonly ToolStripMenuItem _sessionMenuItem;
    private readonly ToolStripMenuItem _visibilityMenuItem;
    private readonly ToolStripMenuItem _pinSessionMenuItem;
    private readonly ToolStripMenuItem _adjustManualMenuItem;
    private readonly ToolStripMenuItem _saveManualMenuItem;
    private readonly ToolStripMenuItem _cancelManualMenuItem;
    private readonly ToolStripMenuItem _resetManualMenuItem;
    private readonly ToolStripMenuItem _traditionalMenuItem;
    private readonly Dictionary<AnchorMode, ToolStripMenuItem> _anchorItems = new();
    private readonly Dictionary<DisplayField, ToolStripMenuItem> _fieldItems = new();
    private readonly Dictionary<(CollapsedSlot Slot, DisplayField Field), ToolStripMenuItem>
        _collapsedFieldItems = new();
    private readonly OverlayInteractionState _interaction = new();
    private readonly ActiveRouteThreadState _activeRouteThread = new();
    private readonly OverlayAnchorTargetState _anchorTargetState = new();
    private readonly ManualAttachmentCoordinator _manualAttachment = new();
    private readonly string? _settingsPath;
    private OverlayPresentation _presentation;
    private CodexWindowTarget? _currentTarget;
    private ManualPlacementSnapshot? _settingsSnapshotBeforeEdit;
    private bool _saveFailureNotified;
    private TokenSnapshot? _lastSnapshot;
    private bool _manuallyHidden;
    private int _pollInFlight;
    private int _disposed;
    private TokenSnapshot? _pendingSnapshot;
    private long _pendingSessionVersion = -1;
    private string? _pendingThreadId;
    private long _observedSessionVersion = -1;
    private string? _observedThreadId;
    private ActiveThreadRouteStatus _pendingRouteStatus = new(null, 0, false, 0, null);
    private long _observedRouteVersion = -1;

    public OverlayContext(string sessionRoot, string? settingsPath = null)
    {
        _settingsPath = settingsPath;
        _monitor = new TokenLogMonitor(sessionRoot);
        _settings = OverlaySettings.Load(_settingsPath);
        _presentation = OverlayPresentationBuilder.CreateWaiting(
            "正在寻找当前 Codex 会话…",
            _settings.CollapsedPrimaryField,
            _settings.CollapsedSecondaryField,
            _settings.VisibleFields);
        _ = _targetHighlight.Handle;
        _themeBinding = new OverlayThemeBinding(
            _targetHighlight,
            new WindowsOverlayThemeSource(),
            ApplyTheme);

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

        _adjustManualMenuItem = new ToolStripMenuItem("调整位置和大小…");
        _adjustManualMenuItem.Click += (_, _) => BeginManualEditing();
        menu.Items.Add(_adjustManualMenuItem);
        _saveManualMenuItem = new ToolStripMenuItem("完成调整") { Visible = false };
        _saveManualMenuItem.Click += (_, _) => SaveManualEditing();
        menu.Items.Add(_saveManualMenuItem);
        _cancelManualMenuItem = new ToolStripMenuItem("取消调整") { Visible = false };
        _cancelManualMenuItem.Click += (_, _) => CancelManualEditing();
        menu.Items.Add(_cancelManualMenuItem);
        _resetManualMenuItem = new ToolStripMenuItem("重置到 Codex 右上");
        _resetManualMenuItem.Click += (_, _) => ResetManualPlacement();
        menu.Items.Add(_resetManualMenuItem);

        _traditionalMenuItem = new ToolStripMenuItem("传统定位");
        AddAnchorMenu(_traditionalMenuItem, "标题栏右上", AnchorMode.TitleBarTopRight);
        AddAnchorMenu(_traditionalMenuItem, "自动吸附", AnchorMode.Auto);
        AddAnchorMenu(_traditionalMenuItem, "窗口内右上", AnchorMode.InsideTopRight);
        AddAnchorMenu(_traditionalMenuItem, "窗口内右下", AnchorMode.InsideBottomRight);
        menu.Items.Add(_traditionalMenuItem);
        menu.Items.Add(new ToolStripSeparator());

        var collapsedFieldsMenu = new ToolStripMenuItem("收起时显示");
        var primaryMenu = new ToolStripMenuItem("左侧指标");
        var secondaryMenu = new ToolStripMenuItem("右侧指标");
        foreach (var field in DisplayFieldRules.Ordered)
        {
            var text = OverlayPresentationBuilder.GetFieldMenuText(field);
            AddCollapsedFieldMenu(primaryMenu, text, CollapsedSlot.Primary, field);
            AddCollapsedFieldMenu(secondaryMenu, text, CollapsedSlot.Secondary, field);
        }
        collapsedFieldsMenu.DropDownItems.Add(primaryMenu);
        collapsedFieldsMenu.DropDownItems.Add(secondaryMenu);
        menu.Items.Add(collapsedFieldsMenu);

        var fieldsMenu = new ToolStripMenuItem("显示字段");
        foreach (var field in DisplayFieldRules.Ordered)
        {
            AddVisibleFieldMenu(fieldsMenu, OverlayPresentationBuilder.GetFieldMenuText(field), field);
        }
        menu.Items.Add(fieldsMenu);
        menu.Items.Add(new ToolStripSeparator());

        _visibilityMenuItem = new ToolStripMenuItem("暂时隐藏");
        _visibilityMenuItem.Click += (_, _) =>
        {
            if (_manualAttachment.IsEditing)
            {
                CancelManualEditing();
            }
            _manuallyHidden = !_manuallyHidden;
            _visibilityMenuItem.Text = _manuallyHidden ? "恢复显示" : "暂时隐藏";
            if (_manuallyHidden)
            {
                CollapseAndHide();
            }
            else
            {
                Tick();
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

        _form.SetPresentation(_presentation);
        _form.CapsuleClicked += HandleCapsuleClicked;
        _form.EditPreviewChanged += HandleEditPreviewChanged;
        _form.EditGestureCompleted += HandleEditGestureCompleted;
        _form.EditSaveRequested += (_, _) => SaveManualEditing();
        _form.EditCancelRequested += (_, _) => CancelManualEditing();
        UpdateAnchorChecks();
        UpdateManualMenuState();
        UpdateFieldChecks();
        UpdateCollapsedFieldChecks();

        _timer = new System.Windows.Forms.Timer { Interval = 350 };
        _timer.Tick += (_, _) => Tick();
        _outsideClickTimer = new System.Windows.Forms.Timer { Interval = 40 };
        _outsideClickTimer.Tick += (_, _) => PollOutsidePointer();
        _timer.Start();
    }

    private void AddAnchorMenu(ToolStripMenuItem menu, string text, AnchorMode mode)
    {
        var item = new ToolStripMenuItem(text);
        item.Click += (_, _) =>
        {
            if (_manualAttachment.IsEditing)
            {
                CancelManualEditing();
            }
            _settings.ManualPlacementEnabled = false;
            _settings.AnchorMode = mode;
            _settings.Save(_settingsPath);
            UpdateAnchorChecks();
            UpdateManualMenuState();
            if (_currentTarget is not null && !_manuallyHidden)
            {
                ApplyLayout(_currentTarget);
            }
        };
        _anchorItems[mode] = item;
        menu.DropDownItems.Add(item);
    }

    private void AddVisibleFieldMenu(ToolStripMenuItem parent, string text, DisplayField field)
    {
        var item = new ToolStripMenuItem(text) { CheckOnClick = false };
        item.Click += (_, _) =>
        {
            var updated = _settings.VisibleFields.HasFlag(field)
                ? _settings.VisibleFields & ~field
                : _settings.VisibleFields | field;
            if (updated == DisplayField.None)
            {
                return;
            }

            _settings.VisibleFields = updated;
            _settings.Save(_settingsPath);
            UpdateFieldChecks();
            RefreshPresentation();
            if (_currentTarget is not null && !_manuallyHidden)
            {
                ApplyLayout(_currentTarget);
            }
        };
        _fieldItems[field] = item;
        parent.DropDownItems.Add(item);
    }

    private void AddCollapsedFieldMenu(
        ToolStripMenuItem parent,
        string text,
        CollapsedSlot slot,
        DisplayField field)
    {
        var item = new ToolStripMenuItem(text) { CheckOnClick = false };
        item.Click += (_, _) =>
        {
            if (!_settings.SelectCollapsedField(slot, field))
            {
                return;
            }

            _settings.Save(_settingsPath);
            UpdateCollapsedFieldChecks();
            RefreshPresentation();
            if (_currentTarget is not null && !_manuallyHidden)
            {
                ApplyLayout(_currentTarget);
            }
        };
        _collapsedFieldItems[(slot, field)] = item;
        parent.DropDownItems.Add(item);
    }

    private void UpdateAnchorChecks()
    {
        foreach (var pair in _anchorItems)
        {
            pair.Value.Checked = pair.Key == _settings.AnchorMode;
        }
    }

    private void UpdateManualMenuState()
    {
        var editing = _manualAttachment.IsEditing;
        _adjustManualMenuItem.Visible = !editing;
        _adjustManualMenuItem.Enabled = !editing && _currentTarget is not null;
        _saveManualMenuItem.Visible = editing;
        _saveManualMenuItem.Enabled = editing && _manualAttachment.CanSave;
        _cancelManualMenuItem.Visible = editing;
        _cancelManualMenuItem.Enabled = editing;
        _resetManualMenuItem.Enabled = !editing;
        _traditionalMenuItem.Enabled = !editing;
        foreach (var pair in _anchorItems)
        {
            pair.Value.Checked = !_settings.ManualPlacementEnabled
                && pair.Key == _settings.AnchorMode;
        }
    }

    private void UpdateFieldChecks()
    {
        foreach (var pair in _fieldItems)
        {
            pair.Value.Checked = _settings.VisibleFields.HasFlag(pair.Key);
        }
    }

    private void UpdateCollapsedFieldChecks()
    {
        foreach (var pair in _collapsedFieldItems)
        {
            pair.Value.Checked = pair.Key.Slot switch
            {
                CollapsedSlot.Primary => pair.Key.Field == _settings.CollapsedPrimaryField,
                CollapsedSlot.Secondary => pair.Key.Field == _settings.CollapsedSecondaryField,
                _ => false
            };
        }
    }

    private void Tick()
    {
        if (Volatile.Read(ref _disposed) != 0)
        {
            return;
        }

        RequestBackgroundPoll();

        if (_pendingRouteStatus.Version != _observedRouteVersion)
        {
            _observedRouteVersion = _pendingRouteStatus.Version;
            UpdateSessionMenuText();
        }

        if (_activeRouteThread.ObserveAndCollapse(_pendingRouteStatus, _interaction))
        {
            StopOutsideClickPolling();
        }

        var activeThreadChanged = !string.Equals(
            _pendingThreadId,
            _observedThreadId,
            StringComparison.OrdinalIgnoreCase);
        if (_pendingSessionVersion != _observedSessionVersion)
        {
            _observedSessionVersion = _pendingSessionVersion;
            _observedThreadId = _pendingThreadId;
            _lastSnapshot = null;
            var shortPendingId = string.IsNullOrWhiteSpace(_pendingThreadId)
                ? "等待识别"
                : OverlayPresentationBuilder.ShortThreadId(_pendingThreadId);
            _pinSessionMenuItem.Enabled = !string.IsNullOrWhiteSpace(_pendingThreadId);
            _presentation = OverlayPresentationBuilder.CreateWaiting(
                $"等待会话 {shortPendingId} 的 token 数据…",
                _settings.CollapsedPrimaryField,
                _settings.CollapsedSecondaryField,
                _settings.VisibleFields);
            _form.SetPresentation(_presentation);
            UpdateSessionMenuText();
        }

        var snapshot = _pendingSnapshot;
        if (snapshot is not null && snapshot != _lastSnapshot)
        {
            _lastSnapshot = snapshot;
            RefreshPresentation();
            var shortId = OverlayPresentationBuilder.ShortThreadId(snapshot.ThreadId);
            _pinSessionMenuItem.Enabled = true;
            _trayIcon.Text = TrimTrayText(
                $"Codex {shortId} · {OverlayPresentationBuilder.FormatTokenCount(snapshot.TotalTokens)} tokens");
            UpdateSessionMenuText();
        }

        if (_manualAttachment.IsEditing)
        {
            if (_currentTarget is null
                || !CodexWindowLocator.TryRefreshKnownCodexTarget(
                    _currentTarget,
                    out var refreshedTarget))
            {
                CancelManualEditing(restoreFocus: false, relayout: false);
                CollapseAndHide();
                return;
            }

            _currentTarget = refreshedTarget;
            if (_manualAttachment.ShouldApplyStaticDraft)
            {
                ApplyEditDraftLayout(refreshedTarget);
            }
            UpdateManualMenuState();
            return;
        }

        if (_manuallyHidden || !CodexWindowLocator.TryGetForegroundCodexTarget(out var target))
        {
            CollapseAndHide();
            UpdateManualMenuState();
            return;
        }

        if (activeThreadChanged)
        {
            _interaction.CollapseForHostChange();
            StopOutsideClickPolling();
        }

        _currentTarget = target;
        ApplyLayout(target);
        UpdateManualMenuState();
    }

    private void RequestBackgroundPoll()
    {
        if (Volatile.Read(ref _disposed) != 0
            || Interlocked.CompareExchange(ref _pollInFlight, 1, 0) != 0)
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
                    if (Volatile.Read(ref _disposed) == 0 && task.Status == TaskStatus.RanToCompletion)
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

    private void RefreshPresentation()
    {
        _presentation = _lastSnapshot is null
            ? OverlayPresentationBuilder.CreateWaiting(
                "正在寻找当前 Codex 会话…",
                _settings.CollapsedPrimaryField,
                _settings.CollapsedSecondaryField,
                _settings.VisibleFields)
            : OverlayPresentationBuilder.Create(
                _lastSnapshot,
                _settings.CollapsedPrimaryField,
                _settings.CollapsedSecondaryField,
                _settings.VisibleFields);
        _form.SetPresentation(_presentation);
    }

    private void ApplyLayout(CodexWindowTarget target)
    {
        Point? manualCenter = null;
        if (_settings.ManualPlacementEnabled)
        {
            var snapshot = SnapshotFromSettings();
            var targets = CreateAttachmentTargets(target);
            manualCenter = ManualAttachmentCoordinator.ResolveCenter(snapshot, targets);
            if (manualCenter is null)
            {
                return;
            }

            if (_anchorTargetState.ObserveAndCollapse(
                target.HostWindow.Handle.ToInt64(),
                snapshot.MainAttachment.ReferencePoint,
                _interaction))
            {
                StopOutsideClickPolling();
            }
        }
        else if (_anchorTargetState.ObserveAndCollapse(
            target.HostWindow.Handle.ToInt64(),
            AttachmentReferencePoint.TopLeft,
            _interaction))
        {
            StopOutsideClickPolling();
        }

        var layout = OverlayLayoutCalculator.Calculate(
            CreateLayoutRequest(target.HostWindow, manualCenter));
        if (_interaction.State == OverlayVisualState.Expanded
            && layout.State != OverlayVisualState.Expanded)
        {
            _interaction.CollapseForExpandedLayoutFailure();
            StopOutsideClickPolling();
            layout = OverlayLayoutCalculator.Calculate(
                CreateLayoutRequest(target.HostWindow, manualCenter));
        }

        if (layout.State == OverlayVisualState.HiddenForSpace)
        {
            _interaction.HideForSpace();
            StopOutsideClickPolling();
        }
        else
        {
            _interaction.RestoreAfterSpace();
        }

        _form.ApplyLayout(layout);
        if (layout.State == OverlayVisualState.HiddenForSpace)
        {
            _form.Hide();
        }
        else if (!_form.Visible)
        {
            _form.Show();
        }

        UpdateOutsideClickPolling();
    }

    private OverlayLayoutRequest CreateLayoutRequest(
        CodexWindowInfo hostWindow,
        Point? manualCenter = null) => new(
        hostWindow,
        _settings.AnchorMode,
        _interaction.State == OverlayVisualState.Expanded,
        _presentation.ExpandedRows.Count,
        _presentation.ShowContextProgress,
        manualCenter,
        _settings.OverlayScalePercent);

    private void BeginManualEditing()
    {
        if (_manualAttachment.IsEditing || _currentTarget is null)
        {
            return;
        }

        if (!CodexWindowLocator.TryRefreshKnownCodexTarget(
            _currentTarget,
            out var refreshedTarget))
        {
            _currentTarget = null;
            UpdateManualMenuState();
            return;
        }
        _currentTarget = refreshedTarget;

        _interaction.CollapseForHostChange();
        StopOutsideClickPolling();
        _settingsSnapshotBeforeEdit = SnapshotFromSettings();
        _saveFailureNotified = false;
        var transition = _manualAttachment.BeginEdit(
            _settingsSnapshotBeforeEdit,
            CreateAttachmentTargets(_currentTarget));
        ApplyEditTransition(_currentTarget, transition, applyLayout: true);
        _form.BeginEditMode(transition.Draft.ScalePercent);
        if (!_form.Visible)
        {
            _form.Show();
        }
        UpdateManualMenuState();
    }

    private void HandleEditPreviewChanged(
        object? sender,
        OverlayEditPreviewEventArgs eventArgs)
    {
        _ = sender;
        if (!_manualAttachment.IsEditing || _currentTarget is null)
        {
            return;
        }

        var targets = CreateAttachmentTargets(_currentTarget);
        _manualAttachment.BeginGesturePreview();
        ManualAttachmentTransition transition;
        if (eventArgs.Kind == OverlayEditGestureKind.Move)
        {
            transition = OverlayEditMoveDispatcher.Dispatch(
                _manualAttachment,
                targets,
                eventArgs,
                CurrentCapsuleCenter(),
                point => IsCursorOnKnownHost(_currentTarget!, point),
                isCompletion: false);
            ApplyEditTransition(
                _currentTarget,
                transition,
                OverlayEditPreviewLayoutPolicy.ShouldApplyLayout(eventArgs.Kind, transition));
        }
        else
        {
            transition = _manualAttachment.PreviewResize(
                targets,
                eventArgs.FixedTopLeft,
                eventArgs.ScalePercent,
                CurrentCollapsedDisplay());
            ApplyEditTransition(_currentTarget, transition, applyLayout: true);
        }
        UpdateManualMenuState();
    }

    private void HandleEditGestureCompleted(
        object? sender,
        OverlayEditPreviewEventArgs eventArgs)
    {
        _ = sender;
        if (!_manualAttachment.IsEditing || _currentTarget is null)
        {
            return;
        }

        var targets = CreateAttachmentTargets(_currentTarget);
        _manualAttachment.EndGesturePreview();
        var transition = eventArgs.Kind == OverlayEditGestureKind.Move
            ? OverlayEditMoveDispatcher.Dispatch(
                _manualAttachment,
                targets,
                eventArgs,
                CurrentCapsuleCenter(),
                point => IsCursorOnKnownHost(_currentTarget!, point),
                isCompletion: true)
            : _manualAttachment.PreviewResize(
                targets,
                eventArgs.FixedTopLeft,
                eventArgs.ScalePercent,
                CurrentCollapsedDisplay());
        ApplyEditTransition(
            _currentTarget,
            transition,
            applyLayout: true);
        UpdateManualMenuState();
    }

    private void SaveManualEditing()
    {
        if (!_manualAttachment.IsEditing)
        {
            return;
        }
        if (!_manualAttachment.CanSave)
        {
            NotifySaveFailure("请先将状态条拖到 Codex 主窗口上。");
            return;
        }

        var original = _settingsSnapshotBeforeEdit ?? SnapshotFromSettings();
        var draft = _manualAttachment.Draft with { Enabled = true };
        ApplySnapshotToSettings(draft);
        if (!_settings.TrySave(_settingsPath))
        {
            ApplySnapshotToSettings(original);
            NotifySaveFailure("无法保存设置，请检查设置文件权限后重试。");
            return;
        }

        var committed = _manualAttachment.Commit();
        ApplySnapshotToSettings(committed.Draft);
        FinishManualEditing(restoreFocus: true, relayout: true);
    }

    private void CancelManualEditing(
        bool restoreFocus = true,
        bool relayout = true)
    {
        if (!_manualAttachment.IsEditing)
        {
            return;
        }

        var cancelled = _manualAttachment.Cancel();
        ApplySnapshotToSettings(cancelled.Draft);
        FinishManualEditing(restoreFocus, relayout);
    }

    private void ResetManualPlacement()
    {
        if (_manualAttachment.IsEditing)
        {
            return;
        }

        _settings.ManualPlacementEnabled = true;
        _settings.MainAttachment = ManualAttachmentRules.DefaultMainAttachment;
        _settings.OverlayScalePercent = ManualAttachmentRules.DefaultScalePercent;
        if (!_settings.TrySave(_settingsPath))
        {
            _trayIcon.ShowBalloonTip(
                3000,
                "Codex Token 状态条",
                "无法保存重置后的设置。",
                ToolTipIcon.Warning);
        }

        _interaction.CollapseForHostChange();
        StopOutsideClickPolling();
        UpdateManualMenuState();
        if (_currentTarget is not null && !_manuallyHidden)
        {
            ApplyLayout(_currentTarget);
        }
    }

    private void ApplyEditDraftLayout(CodexWindowTarget target)
    {
        if (!_manualAttachment.IsEditing)
        {
            return;
        }

        var transition = new ManualAttachmentTransition(
            _manualAttachment.Draft,
            IsEditing: true,
            _manualAttachment.CanSave,
            RequiresPersist: false,
            ShouldCollapse: true,
            HighlightBounds: _manualAttachment.ShouldShowStaticHighlight
                ? target.HostWindow.WindowBounds
                : null,
            ResolvedCenter: ManualAttachmentCoordinator.ResolveCenter(
                _manualAttachment.Draft,
                CreateAttachmentTargets(target)));
        ApplyEditTransition(target, transition, applyLayout: true);
    }

    private void ApplyEditTransition(
        CodexWindowTarget target,
        ManualAttachmentTransition transition,
        bool applyLayout)
    {
        if (transition.HighlightBounds is IntRect highlight && !highlight.IsEmpty)
        {
            _targetHighlight.ShowTarget(highlight);
        }
        else
        {
            _targetHighlight.ClearTarget();
        }

        if (!applyLayout || transition.ResolvedCenter is not Point center)
        {
            return;
        }

        _interaction.CollapseForHostChange();
        StopOutsideClickPolling();
        var layout = OverlayLayoutCalculator.Calculate(new OverlayLayoutRequest(
            target.HostWindow,
            _settings.AnchorMode,
            RequestExpanded: false,
            _presentation.ExpandedRows.Count,
            _presentation.ShowContextProgress,
            center,
            ScalePercent: transition.Draft.ScalePercent));
        _form.ApplyLayout(layout);
        if (layout.State == OverlayVisualState.HiddenForSpace)
        {
            _form.Hide();
        }
        else if (!_form.Visible)
        {
            _form.Show();
        }
    }

    private void FinishManualEditing(bool restoreFocus, bool relayout)
    {
        var focusTarget = _currentTarget;
        _targetHighlight.ClearTarget();
        _form.EndEditMode();
        _interaction.CollapseForHostChange();
        StopOutsideClickPolling();
        _settingsSnapshotBeforeEdit = null;
        _saveFailureNotified = false;
        UpdateManualMenuState();

        if (relayout && _currentTarget is not null && !_manuallyHidden)
        {
            ApplyLayout(_currentTarget);
        }

        if (restoreFocus
            && focusTarget is not null
            && CodexWindowLocator.TryRefreshKnownCodexTarget(focusTarget, out var refreshed))
        {
            _currentTarget = refreshed;
            SetForegroundWindow(refreshed.HostWindow.Handle);
        }
    }

    private void NotifySaveFailure(string message)
    {
        if (_saveFailureNotified)
        {
            return;
        }

        _saveFailureNotified = true;
        _trayIcon.ShowBalloonTip(
            3000,
            "Codex Token 状态条",
            message,
            ToolTipIcon.Warning);
    }

    private Point CurrentCapsuleCenter()
    {
        var layout = _form.CurrentLayout
            ?? throw new InvalidOperationException("编辑布局尚未建立。");
        return new Point(
            _form.Left + layout.CapsuleBounds.X + (layout.CapsuleBounds.Width / 2),
            _form.Top + layout.CapsuleBounds.Y + (layout.CapsuleBounds.Height / 2));
    }

    private CollapsedDisplayMode CurrentCollapsedDisplay() =>
        _form.CurrentLayout?.CollapsedDisplay ?? CollapsedDisplayMode.TwoFields;

    private ManualPlacementSnapshot SnapshotFromSettings() => new(
        _settings.ManualPlacementEnabled,
        ManualAttachmentRules.SanitizeMain(_settings.MainAttachment),
        ManualAttachmentRules.SanitizeScale(_settings.OverlayScalePercent));

    private void ApplySnapshotToSettings(ManualPlacementSnapshot snapshot)
    {
        _settings.ManualPlacementEnabled = snapshot.Enabled;
        _settings.MainAttachment = ManualAttachmentRules.SanitizeMain(snapshot.MainAttachment);
        _settings.OverlayScalePercent = ManualAttachmentRules.SanitizeScale(snapshot.ScalePercent);
    }

    private static AttachmentTargetBounds CreateAttachmentTargets(CodexWindowTarget target) => new(
        target.HostWindow.Handle.ToInt64(),
        target.HostWindow.WindowBounds,
        target.HostWindow.WorkingArea,
        target.HostWindow.Dpi);

    private bool IsCursorOnKnownHost(CodexWindowTarget target, Point point) =>
        CodexWindowLocator.IsPointOnKnownHost(
            target,
            point,
            new HashSet<long>
            {
                _form.Handle.ToInt64(),
                _targetHighlight.Handle.ToInt64()
            });

    private void HandleCapsuleClicked(object? sender, EventArgs eventArgs)
    {
        if (!_interaction.OnCapsuleMouseUp() || _currentTarget is null)
        {
            return;
        }

        if (!_interaction.ShouldPollOutsideClicks)
        {
            StopOutsideClickPolling();
        }
        ApplyLayout(_currentTarget);
    }

    private void PollOutsidePointer()
    {
        if (!_interaction.ShouldPollOutsideClicks)
        {
            StopOutsideClickPolling();
            return;
        }

        if (!PointerInput.TryGetCursorPosition(out var position))
        {
            return;
        }

        if (_interaction.OnPointerSample(
            PointerInput.ReadPressedButtons(),
            _form.ContainsScreenPoint(position)))
        {
            StopOutsideClickPolling();
            if (_currentTarget is not null)
            {
                ApplyLayout(_currentTarget);
            }
        }
    }

    private void UpdateOutsideClickPolling()
    {
        if (_interaction.ShouldPollOutsideClicks && !_manuallyHidden)
        {
            _outsideClickTimer.Start();
        }
        else
        {
            StopOutsideClickPolling();
        }
    }

    private void StopOutsideClickPolling() => _outsideClickTimer.Stop();

    private void CollapseAndHide()
    {
        _interaction.CollapseForHostChange();
        StopOutsideClickPolling();
        _form.Hide();
    }

    private void UpdateSessionMenuText()
    {
        var threadId = _lastSnapshot?.ThreadId ?? _pendingThreadId;
        var shortId = string.IsNullOrWhiteSpace(threadId)
            ? "等待识别"
            : OverlayPresentationBuilder.ShortThreadId(threadId);
        _sessionMenuItem.Text = $"会话：{shortId}{RouteStatusSuffix(_pendingRouteStatus)}";
    }

    private void ApplyTheme(OverlayThemePalette palette)
    {
        _form.ApplyTheme(palette);
        _targetHighlight.ApplyTheme(palette);
    }

    private static string TrimTrayText(string value) =>
        value.Length <= 63 ? value : value[..63];

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
        if (_manualAttachment.IsEditing)
        {
            CancelManualEditing(restoreFocus: false, relayout: false);
        }
        CollapseAndHide();
        _timer.Stop();
        _outsideClickTimer.Stop();
        _trayIcon.Visible = false;
        ExitThread();
        Dispose();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing && Interlocked.Exchange(ref _disposed, 1) == 0)
        {
            if (_manualAttachment.IsEditing)
            {
                CancelManualEditing(restoreFocus: false, relayout: false);
            }
            _interaction.CollapseForHostChange();
            _timer.Stop();
            _outsideClickTimer.Stop();
            _timer.Dispose();
            _outsideClickTimer.Dispose();
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _routeMonitor.Dispose();
            _monitor.Dispose();
            DisposeThemeAndForms();
        }
        base.Dispose(disposing);
    }

    private void DisposeThemeAndForms()
    {
        _themeBinding.Dispose();
        _targetHighlight.Dispose();
        _form.Dispose();
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr windowHandle);
}

internal static class OverlayEditMoveDispatcher
{
    public static ManualAttachmentTransition Dispatch(
        ManualAttachmentCoordinator coordinator,
        AttachmentTargetBounds targets,
        OverlayEditPreviewEventArgs eventArgs,
        Point capsuleCenter,
        Func<Point, bool> hostSurfaceResolver,
        bool isCompletion)
    {
        ArgumentNullException.ThrowIfNull(coordinator);
        ArgumentNullException.ThrowIfNull(targets);
        ArgumentNullException.ThrowIfNull(eventArgs);
        ArgumentNullException.ThrowIfNull(hostSurfaceResolver);
        if (eventArgs.Kind != OverlayEditGestureKind.Move)
        {
            throw new ArgumentOutOfRangeException(nameof(eventArgs));
        }

        var hostSurfaceHit = hostSurfaceResolver(eventArgs.CursorScreen);
        return isCompletion
            ? coordinator.CompleteMove(
                targets,
                eventArgs.CursorScreen,
                capsuleCenter,
                hostSurfaceHit)
            : coordinator.PreviewMove(
                targets,
                eventArgs.CursorScreen,
                capsuleCenter,
                hostSurfaceHit);
    }
}

internal static class OverlayEditPreviewLayoutPolicy
{
    public static bool ShouldApplyLayout(
        OverlayEditGestureKind kind,
        ManualAttachmentTransition transition)
    {
        ArgumentNullException.ThrowIfNull(transition);
        return kind != OverlayEditGestureKind.Move || !transition.CanSave;
    }
}
