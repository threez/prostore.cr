# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.1] - 2026-10-11

### Changed

- Bumped the `ameba` development dependency from `~> 1.6.0` to `~> 1.7.0`.
- Refreshed the `tui` dependency (`~> 0.5.0`) to pick up its own ameba 1.7.0
  upgrade; no public API changes, no code changes required here.
- `lib/ameba/bin/ameba`'s Makefile rule now runs `shards build ameba` after
  `shards install`, since ameba 1.7.0 dropped its `postinstall` build hook.
- CI (`.github/workflows/ci.yml`): added explicit "Build ameba" and "Lint"
  steps to the `lint` job (ameba was previously configured via `.ameba.yml`
  but never actually run in CI); pinned Crystal to `1.20.2`.

### Fixed

- Resolved ameba 1.7 lint findings without changing behavior:
  `Style/RedundantNilInControlExpression`, `Style/HeredocIndent`,
  `Performance/TimesMap`, `Style/MultilineCurlyBlock`
  (`src/prostore/tui/widgets/record_detail.cr`,
  `src/prostore/tui/widgets/record_grid.cr`).
- Silenced one `Lint/UselessAssign` false positive in
  `spec/integration/shared/backup_spec.cr` with an inline
  `# ameba:disable` comment — the assignment seeds a cleanup variable used
  in an `ensure` block if the following call raises.
