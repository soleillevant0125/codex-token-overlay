# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: ../../compare/v0.2.1...HEAD
[0.2.1]: ../../releases/tag/v0.2.1
[0.2.0]: ../../releases/tag/v0.2.0
[0.1.0]: ../../releases/tag/v0.1.0
