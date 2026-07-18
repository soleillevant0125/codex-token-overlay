# Codex Token Overlay

[简体中文](README.zh-CN.md)

Codex Token Overlay is a read-only desktop companion that shows token usage for the task currently selected in Codex Desktop. It supports Windows and macOS, follows idle task switches through Codex's local IPC channel, and reads token metrics from local JSONL session logs.

> [!IMPORTANT]
> This is an unofficial community project. It is not developed, endorsed, or supported by OpenAI. Codex Desktop's JSONL schema and IPC messages are internal implementation details and may change in a future Codex release.

## Features

- Follows the task selected in Codex Desktop, including a task that is not currently running.
- Refreshes after a task switch even when that task's log has not changed.
- Shows total, input, output, cache-hit, derived cache-miss, reasoning, and context-window token metrics.
- Lets you choose exactly which fields are visible.
- Uses a click-through floating strip and tray icon on Windows.
- Uses a native menu-bar item on macOS, with launch-at-login control in its menu.
- Falls back to the newest root Codex Desktop session when internal IPC is unavailable.
- Reads local files only; it has no telemetry, analytics, network API, or upload feature.

## Downloads

Download the newest ZIP from [GitHub Releases](../../releases).

| Platform | Asset | Notes |
| --- | --- | --- |
| Windows x64 Lite | `CodexTokenOverlay-win-x64-lite.zip` | About 100 KB; requires .NET 10 Desktop Runtime. |
| Windows x64 Standalone | `CodexTokenOverlay-win-x64.zip` | About 46 MB; no .NET installation and preserves the existing asset name. |
| Windows Arm64 Lite | `CodexTokenOverlay-win-arm64-lite.zip` | About 100 KB; requires the Arm64 .NET 10 Desktop Runtime. |
| Windows Arm64 Standalone | `CodexTokenOverlay-win-arm64.zip` | No .NET installation and preserves the existing asset name. |
| macOS Apple Silicon | `CodexTokenOverlay-macos-arm64.zip` | Recommended for M1, M2, M3, M4, and later M-series Macs. |
| macOS Intel | `CodexTokenOverlay-macos-x64.zip` | Intel Macs running macOS 14 or later. |

Every ZIP has a neighboring `.sha256` checksum file. Windows Lite is close to the macOS archive size and contains the same application code as Standalone; it uses a shared system runtime instead of embedding it. Install the matching **Desktop Runtime** from [Microsoft's official .NET 10 download page](https://dotnet.microsoft.com/download/dotnet/10.0). Choose the same-architecture asset without `-lite` if you do not want to install a runtime or are unsure.

No Windows package requires PowerShell. macOS users do not need Xcode, Swift, or Homebrew.

## Run on Windows

1. Download the `-lite.zip` asset when .NET 10 Desktop Runtime is installed; otherwise choose the same architecture without `-lite`.
2. Extract it anywhere.
3. Double-click `CodexTokenOverlay.exe`.

The tray menu controls visible fields, placement, task locking, temporary visibility, and exit. The floating strip appears while a recognized Codex Desktop window is in the foreground.

Unsigned GitHub executables can trigger Windows SmartScreen. Confirm that the file came from this repository and compare its SHA-256 checksum before choosing **More info > Run anyway**.

## Run on macOS

1. Download `CodexTokenOverlay-macos-arm64.zip` for an M-series Mac, or the x64 archive for an Intel Mac.
2. Extract the ZIP and move `CodexTokenOverlay.app` to `/Applications`.
3. Open the app. Its token display appears in the macOS menu bar; there is no Dock icon.
4. Click the menu-bar text to choose fields, lock the current task, enable launch at login, or quit.

The current public macOS archives are ad-hoc signed, not Developer ID notarized. On first launch, Gatekeeper may require you to Control-click the app and choose **Open**, or approve it under **System Settings > Privacy & Security**. Only do this after confirming the download source and checksum. No Terminal command or global security bypass is required.

A Developer ID Application certificate and Apple notarization are required to remove this first-launch trust prompt. The repository is packaging-ready for that step, but no Apple certificate is stored in this project.

## Requirements and file locations

- Windows 10/11, or macOS 14 or later.
- Windows Lite requires the architecture-matching .NET 10 Desktop Runtime; Standalone does not.
- Codex Desktop running under the same interactive user.
- Read access to Codex Desktop's local session data.

The session directory is resolved in this order:

1. `--sessions <path>` when supplied by a developer or test runner.
2. `$CODEX_HOME/sessions` when `CODEX_HOME` is set.
3. The default `~/.codex/sessions` directory.

The application itself can be stored anywhere, although `/Applications` is recommended on macOS so launch-at-login and Gatekeeper behavior are predictable.

Preferences are stored per user:

- Windows: `%LOCALAPPDATA%\CodexTokenOverlay\settings.json`
- macOS: the standard preferences domain `io.github.soleillevant0125.CodexTokenOverlay`

## Metrics

| Field | Meaning |
| --- | --- |
| Total | Accumulated `total_token_usage.total_tokens` for the selected task. |
| Input | Accumulated input tokens. |
| Output | Accumulated output tokens. |
| Cache hit | Accumulated cached input tokens; this is a subset of input. |
| Cache miss | Derived as `max(0, input - cached input)`. |
| Context | Tokens used by the latest model call compared with `model_context_window`. |
| Reasoning | Accumulated reasoning output tokens when present. |
| Task ID | The Codex conversation/thread identifier. |

These values describe local session-log events. They are not an invoice, an API charge calculation, or an authoritative ChatGPT plan-usage counter.

## How task following works

The app never modifies Codex data:

1. It connects as a read-only client to Codex Desktop's local IPC endpoint.
   - Windows: `\\.\pipe\codex-ipc`
   - macOS: `$CODEX_HOME/ipc/ipc.sock`, with compatible legacy socket fallbacks
2. It listens for the task ID followed by the active Codex window.
3. It finds the matching root-session JSONL file and reads the newest complete `token_count` event.
4. A task-ID change forces an immediate parse, so switching to an idle task does not depend on a new log write.
5. If IPC is unavailable, it shows the newest Codex Desktop root session instead.

On macOS, the app validates that an IPC path is a Unix socket owned by the current user and that its directory is not writable by another user. It only connects; it never creates, deletes, or replaces Codex's socket.

## Privacy

- Session files are read locally and never modified.
- Token values and task identifiers stay on the computer.
- No session content is transmitted by this application.
- No real Codex session log is included in source control or release archives.

Session JSONL files can contain conversation data. Do not upload them when reporting an issue. A symptom description, app version, platform, and Codex Desktop version are usually enough.

## Troubleshooting

### Switching tasks does not update the display

Task selection comes from an internal Codex IPC message. Restart both Codex Desktop and Codex Token Overlay, then check for a newer release if Codex was recently updated. Fallback mode can show recent token data but cannot always identify an idle task selected in the UI.

### The macOS menu item says `Token —`

- Open a Codex task that has at least one completed model response.
- Confirm that `~/.codex/sessions` exists, or that your custom `CODEX_HOME` is available to GUI applications.
- Restart the overlay after changing `CODEX_HOME`.
- If IPC has changed in a new Codex build, the menu falls back to the newest compatible root session.

### Remove the application

- Windows: exit from the tray and delete the extracted folder. Optionally remove `%LOCALAPPDATA%\CodexTokenOverlay`.
- macOS: quit from the menu bar, disable **Launch at login**, and delete `CodexTokenOverlay.app` from `/Applications`.

## Build from source

### Windows

Development requires the .NET 10 SDK:

```powershell
dotnet restore .\src\CodexTokenOverlay\CodexTokenOverlay.csproj
dotnet build .\src\CodexTokenOverlay\CodexTokenOverlay.csproj -c Release
.\scripts\Test-LogParser.ps1
```

Create both local Lite and Standalone archives with:

```powershell
.\scripts\Publish-Local.ps1 -RuntimeIdentifier win-x64 -Variant Both
```

Set `-Variant` to `Lite` or `Standalone` to build only one form.

### macOS

Development requires macOS 14 or later with Xcode Command Line Tools:

```bash
swift test --package-path macos
./script/build_and_run.sh --verify
```

The repository's Codex environment exposes the same script as a **Run** action. To create a release-style `.app` locally:

```bash
./macos/script/package_app.sh \
  --arch "$(uname -m)" \
  --configuration release \
  --version 0.2.1 \
  --output artifacts/macos-local
```

## Repository contents

- `src/CodexTokenOverlay`: existing .NET/WinForms Windows application.
- `packaging/windows`: shared-runtime notice included in Windows Lite archives.
- `macos/Package.swift`: native SwiftPM package for macOS.
- `macos/Sources/CodexTokenCore`: session discovery, token parsing, and Unix IPC task routing.
- `macos/Sources/CodexTokenOverlayMac`: native AppKit menu-bar application.
- `macos/Tests`: synthetic parser and task-routing tests; no real conversation data.
- `macos/script/package_app.sh`: `.app` assembly, architecture validation, and ad-hoc signing.
- `script/build_and_run.sh`: macOS development build/run/debug entry point.
- `.github/workflows`: Windows and macOS CI and release automation.

## License

MIT License. See [LICENSE](LICENSE).
