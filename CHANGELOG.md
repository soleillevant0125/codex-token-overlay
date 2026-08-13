# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-08-13

### Added

- New default Windows title-bar capsule with click-to-expand and outside-click collapse behavior that preserves Codex input focus.
- Tray controls for choosing the left and right metrics shown in the collapsed capsule.
- Narrow-window fallback from two collapsed metrics to one metric and then hidden, with automatic restoration when space returns.
- Main-window-only manual attachment with eight reference points, invalid-drop restoration, proportional 60–130% resizing, save/cancel, and reset.
- Selectable Windows cache-hit-rate metric, computed as cached input divided by input, with a 0% zero-input result and default visibility in new Windows settings.
- Live Windows application-theme following for the capsule, expanded panel, edit decoration, and attachment target ring.

### Changed

- Made explicit manual attachment the primary Windows placement workflow; the overlay follows the saved Codex main-window reference point instead of storing desktop coordinates, and rejects drops over the desktop, other apps, or non-main Codex surfaces.
- Preserved Title-bar top-right, Auto, inside-top-right, and inside-bottom-right Windows placements under the Traditional positioning compatibility submenu.
- Changed title-bar placement to use the largest scale that fully fits the title bar instead of moving the overlay into the Codex client area; the requested scale is retained for automatic restoration when space returns.
- Added an absolute Windows `--settings` path for isolated development and UI verification; it remains developer/test-only rather than a normal user option.
- Clarified that the Windows overlay is an independent companion window, not an injection into the Codex process or UI tree.
- Added automatic live light/dark following from the Windows application theme with no manual theme selector.
- Clarified that Windows Arm64 packages are cross-built and PE-checked but not yet natively tested on Arm64 hardware.

### Fixed

- Prevented the overlay's own shadow and helper windows from invalidating a manual Codex attachment while dragging.
- Kept two collapsed title-bar metrics readable by widening the capsule without moving it into the Codex client area.
- Moved the default and reset manual placement left far enough to avoid the Codex caption buttons.

## [0.2.1] - 2026-07-18

### Added

- Windows x64 and Arm64 Lite archives using the shared .NET 10 Desktop Runtime.
- Published-EXE probe coverage and CI size guards for the lightweight Windows build.
- Existing Windows asset names remain Standalone and continue to require no runtime installation.

### Changed

- New Windows Lite archives are about 100 KB after ZIP packaging instead of embedding roughly 50 MB of runtime files.
- Removed the macOS Beta label after successful physical-device validation.

## [0.2.0] - 2026-07-18

### Added

- Native macOS menu-bar application built with SwiftPM and AppKit.
- Apple Silicon (`macos-arm64`) and Intel (`macos-x64`) release archives.
- Unix-domain Codex IPC task following with current and legacy socket discovery.
- Immediate refresh when selecting an idle macOS task whose log has not changed.
- Synthetic XCTest coverage for token parsing, `CODEX_HOME`, idle-task switching, and IPC routing.
- macOS launch-at-login control, per-field display preferences, ad-hoc signing, and Gatekeeper guidance.
- Cross-platform CI and Release automation for two Windows and two macOS architectures.

## [0.1.0] - 2026-07-17

### Added

- Token strip for the task currently selected in Codex Desktop.
- Local IPC task tracking with recent-root-session fallback.
- Parsing of total, input, output, cached input, reasoning, and context-window token metrics.
- Configurable visible fields and overlay placement through the system tray.
- Per-user settings persisted under Local AppData.

[Unreleased]: ../../compare/v0.3.0...HEAD
[0.3.0]: ../../compare/v0.2.1...v0.3.0
[0.2.1]: ../../releases/tag/v0.2.1
[0.2.0]: ../../releases/tag/v0.2.0
[0.1.0]: ../../releases/tag/v0.1.0
