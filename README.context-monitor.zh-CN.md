# Codex 上下文监视器（Windows 改造版）

基于 MIT 项目 soleillevant0125/codex-token-overlay，保留原作者许可证。
这是跟随 Codex 窗口的本地伴随工具，不是原生界面插件。

## 使用

双击 `启动上下文监视器.cmd`。显示当前选中对话的上下文剩余百分比。
托盘右键可以调整位置、选择显示字段、锁定会话、关闭提醒或退出。
首次启动默认显示累计 tokens 和上下文剩余。

提醒默认在剩余 20%、10%、5% 时触发。每个对话独立去重；从严重不足
直接跨过多个阈值只提示最严重一级。压缩后恢复超过阈值 3 个百分点，
该阈值重新启用提醒。通知由 Windows 通知设置控制。

启动脚本会创建 `local-settings.json` 作为本改造版独立配置。
退出工具后可修改 `ContextAlertThresholds`，例如 `[25, 15, 5]`，再启动。
不会覆盖原工具的用户设置。运行期间去重，重启后允许重新提醒。

## 数据与限制

剩余 = 100 × (1 - 最近一次输入 tokens / 日志报告的模型窗口)。
包含缓存输入，不能使用累计 tokens 计算上下文。数据来自最新日志事件，
不是实时预测；下一次消息、工具结果和输出仍可能触发提前压缩。

IPC 能识别当前对话时跟随对话；IPC 不可用时上游工具回退到最新会话，
托盘会标记回退状态，此时自动提醒暂停。手动锁定会话时可以提醒。
上下文窗口未知时显示破折号。IPC 和日志格式属内部接口，Codex 更新后
可能需要适配。本版未修改 macOS 实现。

## 构建与验证

构建需要 .NET 10 SDK。

```powershell
dotnet run --project tests/ContextAlerts -c Release
scripts/Test-LogParser.ps1
scripts/Test-OverlayLogic.ps1 -Area All
dotnet publish src/CodexTokenOverlay/CodexTokenOverlay.csproj -c Release -r win-x64 --self-contained true -o dist/win-x64
```

便携包位于 `dist/win-x64`，运行无需另装 .NET。
源项目：https://github.com/soleillevant0125/codex-token-overlay
