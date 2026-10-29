/*
Package slog provides structured, leveled logging in the style of Go's log/slog.

A Logger turns a message and a list of key-value pairs into a Record and hands
it to a Handler. The package ships two handlers that write one line per record
to any `io.Writer`: Text_Handler writes `key=value` pairs, JSON_Handler writes
one JSON object per line. Child loggers made with logger_with and
logger_with_group carry bound attributes and groups into every record they
emit, and runtime_logger adapts a Logger to `runtime.Logger` so that
`context.logger` and `core:log` write through it.

Example:
	import "core:os"
	import "shared:slog"

	main :: proc() {
		h: slog.Text_Handler
		slog.text_handler_init(&h, os.to_writer(os.stdout))
		defer slog.text_handler_destroy(&h)

		logger := slog.logger_make(slog.text_handler(&h))
		slog.info(&logger, "server started", "port", 8080, "tls", false)
	}

Output:
	time=2026-10-29T17:13:00.123Z level=INFO msg="server started" port=8080 tls=false
*/
package slog

import "base:runtime"
import "core:io"
import "core:strings"
import "core:sync"

/*
Level is the importance of a record. Higher values are more severe.

The named levels match Go's log/slog and leave gaps so that you can define
levels in between, for example `slog.Level(2)`, which prints as `INFO+2`.
*/
Level :: enum i32 {
	// Debug is for detailed diagnostics that are usually turned off.
	Debug = -4,
	// Info is for routine events. It is the zero value and the default minimum.
	Info  = 0,
	// Warn is for unexpected events that the program recovers from.
	Warn  = 4,
	// Error is for failures that need attention.
	Error = 8,
}

// Level_Error lists the ways level_parse can reject its input.
Level_Error :: enum {
	None,
	// The input was empty or only whitespace.
	Empty,
	// The level name was not one of debug, info, warn, warning or error.
	Unknown_Name,
	// The text after the name was not a valid `+N` or `-N` offset, or overflowed.
	Invalid_Offset,
}

/*
Error is the compound error type returned by every fallible procedure in this
package. `nil` means success.

- Level_Error comes from level_parse.
- io.Error comes from the writer that a handler writes to.
- runtime.Allocator_Error comes from binding attributes or groups to a child logger.
*/
Error :: union #shared_nil {
	Level_Error,
	io.Error,
	runtime.Allocator_Error,
}

// LEVEL_STRING_SIZE is the buffer size that always fits the output of level_string.
LEVEL_STRING_SIZE :: 16

/*
level_string writes the name of `level` into `buf` and returns it.

Named levels print as `DEBUG`, `INFO`, `WARN` and `ERROR`. Other values print
relative to the nearest named level below them, for example `INFO+2` or
`DEBUG-1`. The result borrows `buf`; a buffer of LEVEL_STRING_SIZE bytes is
always large enough, and shorter buffers truncate the output.
*/
level_string :: proc(level: Level, buf: []byte) -> string {
	base: Level
	name: string
	switch {
	case level < .Info:
		base, name = .Debug, "DEBUG"
	case level < .Warn:
		base, name = .Info, "INFO"
	case level < .Error:
		base, name = .Warn, "WARN"
	case:
		base, name = .Error, "ERROR"
	}
	b := strings.builder_from_bytes(buf)
	strings.write_string(&b, name)
	offset := i64(level) - i64(base)
	if offset > 0 {
		strings.write_byte(&b, '+')
	}
	if offset != 0 {
		strings.write_i64(&b, offset)
	}
	return strings.to_string(b)
}

/*
level_parse reads a level name such as `info`, `WARN` or `error+2`.

Names are case-insensitive, and `warning` is accepted as `warn`. An optional
`+N` or `-N` suffix adds an offset to the named level. Surrounding whitespace
is ignored.

Returns:
- level: the parsed level, or `.Info` on failure.
- err: `.Empty`, `.Unknown_Name` or `.Invalid_Offset` when the input is malformed.
*/
level_parse :: proc(text: string) -> (level: Level, err: Level_Error) {
	s := strings.trim_space(text)
	if len(s) == 0 {
		return .Info, .Empty
	}
	split := len(s)
	for i in 0 ..< len(s) {
		if s[i] == '+' || s[i] == '-' {
			split = i
			break
		}
	}
	name, rest := s[:split], s[split:]
	base: Level
	switch {
	case strings.equal_fold(name, "debug"):
		base = .Debug
	case strings.equal_fold(name, "info"):
		base = .Info
	case strings.equal_fold(name, "warn"), strings.equal_fold(name, "warning"):
		base = .Warn
	case strings.equal_fold(name, "error"):
		base = .Error
	case:
		return .Info, .Unknown_Name
	}
	if len(rest) == 0 {
		return base, .None
	}
	if len(rest) < 2 {
		return .Info, .Invalid_Offset
	}
	offset: i64
	for c in transmute([]byte)rest[1:] {
		if c < '0' || c > '9' {
			return .Info, .Invalid_Offset
		}
		offset = offset * 10 + i64(c - '0')
		if offset > i64(max(i32)) {
			return .Info, .Invalid_Offset
		}
	}
	if rest[0] == '-' {
		offset = -offset
	}
	total := i64(base) + offset
	if total < i64(min(i32)) || total > i64(max(i32)) {
		return .Info, .Invalid_Offset
	}
	return Level(total), .None
}

/*
Level_Var holds a level that can change while loggers use it, for example to
turn on debug output at run time. Point Handler_Options.level_var at one.

The zero value is `.Info`. Reads and writes are atomic, so a Level_Var is safe
to share between threads.
*/
Level_Var :: struct {
	value: i32,
}

// level_var_get returns the current level stored in `v`.
level_var_get :: proc "contextless" (v: ^Level_Var) -> Level {
	return Level(sync.atomic_load(&v.value))
}

// level_var_set stores `level` in `v`. Handlers that use `v` see it on their next record.
level_var_set :: proc "contextless" (v: ^Level_Var, level: Level) {
	sync.atomic_store(&v.value, i32(level))
}
