# Codex Token 状态条

[English](README.md)

Codex Token 状态条是一个只读桌面小工具，用于显示 Codex Desktop 当前选中任务的 Token 使用情况。它支持 Windows 和 macOS，通过 Codex 本机 IPC 跟随当前任务，并从本地 JSONL 会话日志读取统计数据；因此切换到没有正在运行的旧任务时也能立即刷新。

> [!IMPORTANT]
> 这是非官方社区项目，并非由 OpenAI 开发、认可或提供支持。它依赖 Codex Desktop 的本地 JSONL 格式和内部 IPC 消息；这些内部实现可能在未来版本中改变。

## 主要功能

- 跟随 Codex Desktop 当前选中的任务，包括当前没有运行的任务。
- 切换任务时立即解析该任务已有日志，不要求日志产生新写入。
- 显示总量、输入、输出、缓存命中、推导出的缓存未命中、推理输出和上下文占用。
- 可以自由选择实际显示哪些字段，并保证至少保留一个字段。
- Windows 使用点击穿透悬浮条和系统托盘菜单。
- macOS 使用原生菜单栏，并可从菜单设置登录时启动。
- 内部 IPC 不可用时自动退回最近更新的 Codex Desktop 根会话。
- 只读取本地文件，不含遥测、分析、网络 API 或上传功能。

## 下载

请从 [GitHub Releases](../../releases) 下载最新 ZIP。

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Windows x64 轻量版 | `CodexTokenOverlay-win-x64-lite.zip` | 约 100 KB，需要 .NET 10 Desktop Runtime。 |
| Windows x64 独立版 | `CodexTokenOverlay-win-x64.zip` | 约 46 MB，无需安装 .NET，保持原下载名。 |
| Windows Arm64 轻量版 | `CodexTokenOverlay-win-arm64-lite.zip` | 约 100 KB，需要 Arm64 .NET 10 Desktop Runtime。 |
| Windows Arm64 独立版 | `CodexTokenOverlay-win-arm64.zip` | 无需安装 .NET，保持原下载名。 |
| macOS Apple Silicon | `CodexTokenOverlay-macos-arm64.zip` | M1、M2、M3、M4 及后续 M 系列芯片首选。 |
| macOS Intel | `CodexTokenOverlay-macos-x64.zip` | 运行 macOS 14 或更高版本的 Intel Mac。 |

每个 ZIP 旁都提供 `.sha256` 校验文件。Windows 轻量版与 macOS 包处于相近的体积档位；它使用与独立版完全相同的应用代码，只是调用系统中共享的 .NET 运行时。请从[微软官方 .NET 10 下载页](https://dotnet.microsoft.com/download/dotnet/10.0)安装与系统架构一致的 **Desktop Runtime**。不想安装运行时或不确定时，直接选择文件名中不带 `-lite` 的独立版。

所有 Windows 版本均不依赖 PowerShell。macOS 用户无需安装 Xcode、Swift 或 Homebrew。

## Windows 使用方法

1. 已安装 .NET 10 Desktop Runtime 时下载 `-lite.zip`；否则下载相同架构、文件名中不带 `-lite` 的独立版。
2. 解压到任意位置。
3. 双击 `CodexTokenOverlay.exe`。

托盘菜单可选择显示字段、调整吸附位置、锁定当前任务、临时隐藏或退出。当可识别的 Codex Desktop 窗口位于前台时，悬浮条会显示。

GitHub 上的未签名程序可能触发 Windows SmartScreen。请先确认文件来自本仓库并核对 SHA-256，再选择“更多信息 > 仍要运行”。

## macOS 使用方法

1. M 系列 Mac 下载 `CodexTokenOverlay-macos-arm64.zip`；Intel Mac 下载 x64 文件。
2. 解压后，将 `CodexTokenOverlay.app` 移入 `/Applications`。
3. 打开应用。Token 会显示在 macOS 菜单栏，不会出现 Dock 图标。
4. 点击菜单栏文字即可选择字段、锁定任务、开启登录时启动或退出。

目前公开的 macOS 包使用 ad-hoc 完整性签名，尚未使用 Developer ID 公证。首次打开时 Gatekeeper 可能要求按住 Control 点击应用并选择“打开”，或者在“系统设置 > 隐私与安全性”中选择“仍要打开”。请仅在确认下载来源和校验值后这样操作；不需要执行终端命令或全局关闭系统安全机制。

若要彻底消除首次信任提示，需要 Apple Developer Program 的 Developer ID Application 证书和 Apple 公证。仓库的打包结构已为此留好基础，但项目中不会存放 Apple 私钥或证书。

## 系统要求和路径

- Windows 10/11，或 macOS 14 及以上版本。
- Windows 轻量版需要与系统架构一致的 .NET 10 Desktop Runtime；独立版不需要。
- Codex Desktop 与本工具在同一个交互用户下运行。
- 当前用户能够读取 Codex Desktop 的本地会话数据。

会话目录按以下顺序解析：

1. 开发或测试时显式传入的 `--sessions <路径>`。
2. 设置 `CODEX_HOME` 时使用 `$CODEX_HOME/sessions`。
3. 默认使用 `~/.codex/sessions`。

应用本身没有固定位置要求，不过 macOS 推荐放入 `/Applications`，这样“登录时启动”和 Gatekeeper 的行为更稳定。

用户设置位置：

- Windows：`%LOCALAPPDATA%\CodexTokenOverlay\settings.json`
- macOS：标准偏好域 `io.github.soleillevant0125.CodexTokenOverlay`

## 指标说明

| 字段 | 含义 |
| --- | --- |
| 总量 | 当前任务累计的 `total_token_usage.total_tokens`。 |
| 输入 | 累计输入 Token。 |
| 输出 | 累计输出 Token。 |
| 缓存命中 | 累计缓存输入 Token，它是输入 Token 的子集。 |
| 缓存未命中 | 由 `max(0, 输入 - 缓存输入)` 推导。 |
| 上下文 | 最近一次模型调用的 Token 数与 `model_context_window` 的对比。 |
| 推理 | 日志中存在该字段时显示累计推理输出 Token。 |
| 任务 ID | Codex conversation/thread 标识。 |

这些数值来自本地会话日志事件，不等同于账单、API 费用计算或权威的 ChatGPT 套餐用量。

## 当前任务跟随原理

程序不会修改 Codex 数据：

1. 以只读客户端连接 Codex Desktop 的本地 IPC。
   - Windows：`\\.\pipe\codex-ipc`
   - macOS：`$CODEX_HOME/ipc/ipc.sock`，并兼容旧版临时 Socket 路径
2. 监听当前 Codex 窗口正在跟随的任务 ID。
3. 找到对应的根会话 JSONL，并读取最后一个完整的 `token_count` 事件。
4. 一旦任务 ID 改变就强制解析，因此切换到未运行任务时不依赖日志更新。
5. IPC 不可用时才退回最近更新的 Codex Desktop 根会话。

macOS 版会验证 IPC 路径确实是当前用户拥有的 Unix Socket，并验证其目录不可被其他用户写入。程序只连接，不会创建、删除或替换 Codex 的 Socket。

## 隐私说明

- 会话文件只在本机读取，不会被修改。
- Token 数值和任务 ID 不会离开电脑。
- 本程序不会传输任何会话内容。
- 源码仓库和发行包均不包含真实 Codex 会话日志。

Codex JSONL 可能包含对话内容。报告问题时请勿上传这些文件；通常只需提供现象、应用版本、操作系统和 Codex Desktop 版本。

## 常见问题

### 切换任务后没有更新

当前任务信号来自 Codex 内部 IPC。请同时重启 Codex Desktop 和本工具；如果 Codex 刚更新，请检查项目是否已有新版本。回退模式能显示近期 Token，但不一定能识别界面中选中的未运行任务。

### macOS 菜单栏显示 `Token —`

- 打开至少完成过一次模型回复的 Codex 任务。
- 确认 `~/.codex/sessions` 存在，或自定义 `CODEX_HOME` 对图形应用可见。
- 修改 `CODEX_HOME` 后重启本工具。
- 如果新版 Codex 改变了 IPC，菜单会先退回最近的兼容根会话。

### 卸载

- Windows：从托盘退出并删除解压目录；如需清除设置，可删除 `%LOCALAPPDATA%\CodexTokenOverlay`。
- macOS：从菜单栏退出，关闭“登录时启动”，再从 `/Applications` 删除 `CodexTokenOverlay.app`。

## 从源码构建

### Windows

开发需要 .NET 10 SDK：

```powershell
dotnet restore .\src\CodexTokenOverlay\CodexTokenOverlay.csproj
dotnet build .\src\CodexTokenOverlay\CodexTokenOverlay.csproj -c Release
.\scripts\Test-LogParser.ps1
```

同时生成本地轻量版和独立版发行包：

```powershell
.\scripts\Publish-Local.ps1 -RuntimeIdentifier win-x64 -Variant Both
```

也可以把 `-Variant` 设置为 `Lite` 或 `Standalone`，只生成其中一种。

### macOS

开发需要 macOS 14 或更高版本以及 Xcode Command Line Tools：

```bash
swift test --package-path macos
./script/build_and_run.sh --verify
```

仓库的 Codex 环境也会把同一个脚本显示为 **Run** 操作。生成发行形态的 `.app`：

```bash
./macos/script/package_app.sh \
  --arch "$(uname -m)" \
  --configuration release \
  --version 0.2.1 \
  --output artifacts/macos-local
```

## 仓库文件说明

- `src/CodexTokenOverlay`：保持独立的 .NET/WinForms Windows 应用。
- `packaging/windows`：Windows 轻量版的共享运行时说明。
- `macos/Package.swift`：macOS 原生 SwiftPM 工程。
- `macos/Sources/CodexTokenCore`：会话发现、Token 解析和 Unix IPC 任务路由。
- `macos/Sources/CodexTokenOverlayMac`：原生 AppKit 菜单栏应用。
- `macos/Tests`：仅使用合成数据的解析与任务切换测试。
- `macos/script/package_app.sh`：组装 `.app`、验证架构并执行 ad-hoc 签名。
- `script/build_and_run.sh`：macOS 开发构建、启动和调试入口。
- `.github/workflows`：Windows 与 macOS 的 CI 和 Release 自动化。

## 许可证

本项目使用 MIT License，详见 [LICENSE](LICENSE)。
