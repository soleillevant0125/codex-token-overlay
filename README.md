# Codex Token Overlay

[简体中文](README.zh-CN.md)

Codex Token Overlay is a small, standalone Windows utility that displays token usage for the task currently selected in Codex Desktop. It runs in the system tray and shows a click-through status strip attached to the Codex window.

> [!IMPORTANT]
> This is an unofficial community project. It is not developed, endorsed, or supported by OpenAI. It depends on Codex Desktop's local JSONL session format and internal IPC messages, which may change in future Codex releases.

## Features

- Follows the task currently selected in Codex Desktop, including tasks that are not actively running.
- Updates when Codex appends token data to its local JSONL session log.
- Displays total, input, output, cache-hit, derived cache-miss, reasoning, and context-window usage.
- Lets you choose which fields are visible from the tray menu.
- Supports automatic placement, inside top-right, and inside bottom-right.
- Stays click-through and does not take keyboard focus from Codex.
- Falls back to the most recently updated root Codex Desktop session when internal IPC is unavailable.
- Stores display preferences per Windows user.

## Download and run

1. Open the repository's [Releases](../../releases) page.
2. Download the ZIP that matches your computer:
   - `win-x64` for most Intel and AMD Windows PCs.
   - `win-arm64` for Windows on Arm devices.
3. Extract the ZIP anywhere you like.
4. Double-click `CodexTokenOverlay.exe`.

The published executable is self-contained. It does **not** require PowerShell, the .NET runtime, or the .NET SDK. The extracted folder may be placed anywhere; the application does not rely on a fixed installation path.

The status strip appears while a recognized Codex Desktop window is in the foreground. Right-click the tray icon to select fields, change placement, lock the current task, temporarily hide the strip, or exit.

## Requirements

- Windows only (`win-x64` or `win-arm64`).
- Codex Desktop running under the same interactive Windows user.
- Read access to Codex Desktop's local session logs.

The application checks the session directory in this order:

1. `%CODEX_HOME%\sessions`, when `CODEX_HOME` is set.
2. `%USERPROFILE%\.codex\sessions`, the default Codex location.

No particular location is required for `CodexTokenOverlay.exe` itself.

## Metrics

| Field | Meaning |
| --- | --- |
| Total | `total_token_usage.total_tokens` accumulated for the selected task. |
| Input | Accumulated input tokens. |
| Output | Accumulated output tokens. |
| Cache hit | Accumulated cached input tokens. This is a subset of input tokens. |
| Cache miss | Derived as `input tokens - cached input tokens`. |
| Context | Tokens used by the latest model call compared with `model_context_window`. |
| Reasoning | Accumulated reasoning output tokens when present in the log. |
| Task ID | The Codex conversation/thread identifier. |

These values describe local session-log events. They are **not** an invoice, API charge calculation, or authoritative ChatGPT plan-usage counter.

## How it works

Codex Token Overlay is read-only:

1. It listens to Codex Desktop's local internal IPC channel to learn which task is selected.
2. It locates the corresponding root-session JSONL file in the Codex session directory.
3. It reads the most recent complete `token_count` event and refreshes the strip when the log changes.
4. If IPC is unavailable, it falls back to the newest root Codex Desktop session log.

The IPC protocol and JSONL schema are internal Codex implementation details, not a public compatibility contract. A future Codex Desktop update may temporarily break task detection or metric parsing until this project is updated.

## Privacy

- Session files are read locally and are never modified.
- The application contains no telemetry, analytics, network API, or upload function.
- Token values and task identifiers remain on your computer.
- Preferences are stored in `%LOCALAPPDATA%\CodexTokenOverlay\settings.json`.

Because Codex session JSONL files may contain conversation data, do not share those files when reporting an issue. A description of the symptom and the Codex Token Overlay version is usually sufficient.

## Windows SmartScreen

GitHub release executables may be unsigned. Windows SmartScreen can therefore show an "unrecognized app" warning even when the SHA-256 checksum matches the release asset. Verify that the file came from this repository's Releases page and compare its checksum before choosing **More info > Run anyway**. Never bypass the warning for a file from an untrusted source.

Each release includes a `.sha256` file next to its ZIP archive.

## Troubleshooting

### The tray icon appears, but the strip does not

- Bring Codex Desktop to the foreground.
- Open a task that already has at least one completed model response.
- Confirm that `%CODEX_HOME%\sessions` or `%USERPROFILE%\.codex\sessions` exists and is readable.
- Restart both Codex Desktop and Codex Token Overlay after a Codex update.

### Switching tasks does not update the strip

The selected-task signal comes from an internal Codex IPC message. Check for a newer Codex Token Overlay release when Codex Desktop has recently changed. The fallback log mode can show recent token data, but it cannot always identify an idle task selected in the UI.

### Remove the application

Exit it from the tray, then delete the extracted folder. You may optionally delete `%LOCALAPPDATA%\CodexTokenOverlay` to remove saved display preferences.

## Build from source

Development requires the .NET 10 SDK. PowerShell is not required by the application itself.

```powershell
dotnet restore .\src\CodexTokenOverlay\CodexTokenOverlay.csproj
dotnet build .\src\CodexTokenOverlay\CodexTokenOverlay.csproj -c Release
dotnet run --project .\src\CodexTokenOverlay\CodexTokenOverlay.csproj
```

Create a self-contained single-file build with:

```powershell
dotnet publish .\src\CodexTokenOverlay\CodexTokenOverlay.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true
```

GitHub Actions builds both `win-x64` and `win-arm64` release archives.

Useful development scripts:

```powershell
.\scripts\Test-LogParser.ps1
.\scripts\Publish-Local.ps1 -RuntimeIdentifier win-x64
```

## Repository contents

- `src/CodexTokenOverlay/Program.cs`: overlay UI, Codex task routing, and token-log parser.
- `src/CodexTokenOverlay/CodexTokenOverlay.csproj`: .NET 10 Windows project and single-file publish settings.
- `scripts/Test-LogParser.ps1`: synthetic-log and `CODEX_HOME` compatibility test; it never reads or stores a real conversation.
- `scripts/Publish-Local.ps1`: local x64/Arm64 ZIP and SHA-256 packager.
- `.github/workflows/ci.yml`: build, parser-test, and publish validation.
- `.github/workflows/release.yml`: tagged GitHub Release automation.
- `README.md`, `README.zh-CN.md`, `LICENSE`, and `CHANGELOG.md`: user and project documentation.

Only the source project is needed to compile the application. A downloadable Release ZIP intentionally contains just `CodexTokenOverlay.exe`, the two README files, and `LICENSE`; the ZIP checksum is published beside it.

## License

MIT License. See [LICENSE](LICENSE).
