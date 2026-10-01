# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-29

### Added

- Cursor-movement time tracking with a 250 ms poll and a 2 px jitter threshold.
- Alarm and Windows notification after 120 seconds of cursor stillness,
  fired once per idle episode and cancelled the moment movement resumes.
- Lock-screen and screen-saver suppression: no alarm, no toast, no banked time,
  and no ambush alarm on unlock.
- Always-on-top draggable readout with a tray icon and a right-click menu
  (Pause / Resume, Reset today, Open data folder, Exit).
- Per-day JSON persistence with automatic midnight rollover.
- `install-to-projects.ps1` with optional logon autostart.

### Changed

- Decision logic extracted from the GUI script into `src/TimeTracker.Core.psm1`
  so the idle rule and lock suppression can be unit tested.

### CI

- GitHub Actions: PSScriptAnalyzer lint (strict), Pester 5 unit and syntax tests
  with JaCoCo coverage of the core module, and a packaged zip plus SHA256 on
  every run.
- Tag-triggered release workflow that re-runs every gate before publishing.

[Unreleased]: https://github.com/Alexander00718/test/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Alexander00718/test/releases/tag/v1.0.0
