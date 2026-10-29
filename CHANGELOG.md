# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-10-29

### Fixed

- `JSON_Handler` now escapes U+2028 and U+2029 as `\u2028` and `\u2029`, as Go does. Before, it wrote the raw characters, which break JavaScript consumers that embed the line.
- `Text_Handler` writes positive infinity as `+Inf`, like Go, instead of `Inf`.
- `JSON_Handler` leaves out a group, bound or inline, when `replace_attr` drops every member, instead of writing `"group":{}`.
- A handler whose allocator fails while formatting no longer panics on nested groups or writes a truncated line. The log call returns `runtime.Allocator_Error` and writes nothing.

## [0.1.0] - 2026-10-29

### Added

- `Logger` with `debug`, `info`, `warn`, `error`, `log` and `log_attrs`, taking key-value pairs or `Attr` values. Malformed pairs appear under `!BADKEY`.
- Child loggers with bound attributes and groups: `logger_with`, `logger_with_attrs`, `logger_with_group` and `logger_destroy`.
- `Text_Handler` and `JSON_Handler`, which write one line per record to an `io.Writer` in the formats of Go's `log/slog`.
- `Handler_Options` with a minimum level, a run-time `Level_Var`, source locations, time omission and a `replace_attr` hook.
- `Level` with `level_string` and `level_parse`, including offsets such as `INFO+2`.
- `runtime_logger`, which adapts a `Logger` to `runtime.Logger` for `context.logger` and `core:log`.
- `Handler` interface for custom back ends, plus `discard_handler`.

[Unreleased]: https://github.com/alexisbcz/odin-slog/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/alexisbcz/odin-slog/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alexisbcz/odin-slog/releases/tag/v0.1.0
