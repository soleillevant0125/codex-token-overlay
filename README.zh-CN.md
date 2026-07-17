# Codex Token 状态条

[English](README.md)

Codex Token 状态条是一个独立的 Windows 小工具，用于显示 Codex Desktop 当前选中任务的 token 使用情况。它常驻系统托盘，并在 Codex 窗口旁显示一个不会拦截点击的状态条。

> [!IMPORTANT]
> 这是非官方社区项目，并非由 OpenAI 开发、认可或提供支持。它依赖 Codex Desktop 的本地 JSONL 会话格式和内部 IPC 消息；这些内部实现可能在未来版本中改变。

## 主要功能

- 跟随 Codex Desktop 当前选中的任务，包括当前没有运行的任务。
- Codex 更新本地 JSONL 会话日志后自动刷新。
- 显示总量、输入、输出、缓存命中、推导出的缓存未命中、推理输出和上下文占用。
- 可从托盘菜单自由选择显示字段。
- 支持自动吸附、窗口内右上和窗口内右下。
- 状态条点击穿透，不会抢走 Codex 的键盘焦点。
- 内部 IPC 不可用时，自动退回最近更新的 Codex Desktop 根会话日志。
- 按 Windows 用户保存显示设置。

## 下载和运行

1. 打开本仓库的 [Releases](../../releases) 页面。
2. 根据电脑架构下载 ZIP：
   - 大多数 Intel、AMD Windows 电脑选择 `win-x64`。
   - Windows on Arm 设备选择 `win-arm64`。
3. 将 ZIP 解压到任意位置。
4. 双击 `CodexTokenOverlay.exe`。

发布版程序已经包含运行所需组件，**不需要** PowerShell、.NET Runtime 或 .NET SDK。解压目录可以放在任意位置，程序不依赖固定安装路径。

当可识别的 Codex Desktop 窗口位于前台时，状态条才会显示。右键单击托盘图标可以选择字段、调整位置、锁定当前任务、临时隐藏状态条或退出程序。

## 使用要求

- 仅支持 Windows（`win-x64` 或 `win-arm64`）。
- Codex Desktop 与本工具需要在同一个 Windows 交互用户下运行。
- 当前用户能够读取 Codex Desktop 的本地会话日志。

程序按以下顺序寻找会话目录：

1. 如果设置了 `CODEX_HOME`，使用 `%CODEX_HOME%\sessions`。
2. 否则使用 Codex 默认目录 `%USERPROFILE%\.codex\sessions`。

`CodexTokenOverlay.exe` 本身没有固定放置位置要求。

## 指标说明

| 字段 | 含义 |
| --- | --- |
| 总量 | 当前任务累计的 `total_token_usage.total_tokens`。 |
| 输入 | 累计输入 token。 |
| 输出 | 累计输出 token。 |
| 缓存命中 | 累计缓存输入 token；它是输入 token 的子集。 |
| 缓存未命中 | 由“输入 token - 缓存输入 token”推导得到。 |
| 上下文 | 最近一次模型调用的 token 数与 `model_context_window` 的对比。 |
| 推理 | 日志中存在该字段时显示累计推理输出 token。 |
| 任务 ID | Codex conversation/thread 标识。 |

这些数值来自本地会话日志事件，**不等同于**账单、API 费用计算或权威的 ChatGPT 套餐用量。

## 工作原理

Codex Token 状态条仅执行只读操作：

1. 监听 Codex Desktop 的本地内部 IPC，识别界面当前选中的任务。
2. 在 Codex 会话目录中寻找对应的根会话 JSONL 文件。
3. 读取最后一个完整的 `token_count` 事件，并在日志发生变化后刷新状态条。
4. IPC 不可用时，退回最近更新的 Codex Desktop 根会话日志。

IPC 协议和 JSONL 结构都是 Codex 的内部实现，并非公开兼容性接口。未来的 Codex Desktop 更新可能暂时导致任务识别或指标解析失效，需要等待本项目适配。

## 隐私说明

- 会话文件只在本机读取，不会被修改。
- 程序不包含遥测、分析、网络 API 或上传功能。
- token 数值和任务标识不会离开本机。
- 显示设置保存在 `%LOCALAPPDATA%\CodexTokenOverlay\settings.json`。

Codex 会话 JSONL 可能包含对话内容。报告问题时请勿上传这些文件；通常只需提供现象描述和 Codex Token 状态条版本。

## Windows SmartScreen

GitHub Release 中的程序可能没有代码签名，因此即使 SHA-256 与发布页一致，Windows SmartScreen 仍可能提示“Windows 已保护你的电脑”或“无法识别的应用”。请先确认文件来自本仓库 Releases 页面并核对校验值，再选择“更多信息 > 仍要运行”。不要对来源不可信的文件绕过警告。

每个 Release ZIP 旁都会提供对应的 `.sha256` 文件。

## 常见问题

### 托盘图标已经出现，但没有状态条

- 将 Codex Desktop 切换到前台。
- 打开至少已经完成过一次模型回复的任务。
- 确认 `%CODEX_HOME%\sessions` 或 `%USERPROFILE%\.codex\sessions` 存在且可读。
- Codex 更新后可以尝试同时重启 Codex Desktop 和本工具。

### 切换任务后状态条没有更新

当前任务信号来自 Codex 的内部 IPC 消息。如果 Codex Desktop 刚刚更新，请检查本项目是否有新版本。日志回退模式可以显示近期 token 数据，但不一定能识别界面中选中的未运行任务。

### 卸载

先从托盘退出，然后删除解压目录即可。如需同时清除显示设置，可以另外删除 `%LOCALAPPDATA%\CodexTokenOverlay`。

## 从源码构建

开发时需要安装 .NET 10 SDK。程序本身不依赖 PowerShell。

```powershell
dotnet restore .\src\CodexTokenOverlay\CodexTokenOverlay.csproj
dotnet build .\src\CodexTokenOverlay\CodexTokenOverlay.csproj -c Release
dotnet run --project .\src\CodexTokenOverlay\CodexTokenOverlay.csproj
```

生成自包含单文件版本：

```powershell
dotnet publish .\src\CodexTokenOverlay\CodexTokenOverlay.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true
```

GitHub Actions 会同时构建 `win-x64` 和 `win-arm64` 发布包。

可用的开发脚本：

```powershell
.\scripts\Test-LogParser.ps1
.\scripts\Publish-Local.ps1 -RuntimeIdentifier win-x64
```

## 仓库文件说明

- `src/CodexTokenOverlay/Program.cs`：状态条界面、Codex 任务识别和 token 日志解析。
- `src/CodexTokenOverlay/CodexTokenOverlay.csproj`：.NET 10 Windows 工程及单文件发布设置。
- `scripts/Test-LogParser.ps1`：合成日志与 `CODEX_HOME` 兼容性测试，不会读取或保存真实对话。
- `scripts/Publish-Local.ps1`：本地生成 x64/Arm64 ZIP 和 SHA-256 校验文件。
- `.github/workflows/ci.yml`：构建、解析测试和发布形态验证。
- `.github/workflows/release.yml`：GitHub Release 自动发布。
- `README.md`、`README.zh-CN.md`、`LICENSE`、`CHANGELOG.md`：用户及项目文档。

编译程序只需要源码工程。供普通用户下载的 Release ZIP 刻意只包含 `CodexTokenOverlay.exe`、两份 README 和 `LICENSE`，ZIP 的校验文件会作为相邻资产发布。

## 许可证

本项目使用 MIT License，详见 [LICENSE](LICENSE)。
