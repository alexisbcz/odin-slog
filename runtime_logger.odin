package slog

import "base:runtime"

/*
runtime_logger returns a `runtime.Logger` that forwards to `l`, so that
`context.logger`, and therefore `core:log`, write structured records.

The text that `core:log` formats becomes the record's message. The
`runtime.Logger_Options` of the caller are ignored, because the handler
decides what to write. `l` must outlive every context that uses the result.

Example:
	context.logger = slog.runtime_logger(&logger)
	log.infof("listening on %d", 8080) // level=INFO msg="listening on 8080"
*/
runtime_logger :: proc(l: ^Logger, lowest_level := runtime.Logger_Level.Debug) -> runtime.Logger {
	return runtime.Logger{procedure = runtime_logger_proc, data = l, lowest_level = lowest_level}
}

/*
level_from_runtime maps a `runtime.Logger_Level` to a Level.

Debug, Info, Warning and Error map to the matching levels. Fatal has no slog
equivalent and maps to `Level.Error + 4`, which prints as `ERROR+4`.
*/
level_from_runtime :: proc(level: runtime.Logger_Level) -> Level {
	switch level {
	case .Debug:
		return .Debug
	case .Info:
		return .Info
	case .Warning:
		return .Warn
	case .Error:
		return .Error
	case .Fatal:
		return Level(i32(Level.Error) + 4)
	}
	return .Info
}

/*
level_to_runtime maps a Level to the closest `runtime.Logger_Level` at or
below it, so that a custom level like `INFO+2` stays at Info.
*/
level_to_runtime :: proc(level: Level) -> runtime.Logger_Level {
	switch {
	case level < .Info:
		return .Debug
	case level < .Warn:
		return .Info
	case level < .Error:
		return .Warning
	case level < Level(i32(Level.Error) + 4):
		return .Error
	}
	return .Fatal
}

// runtime_logger_proc is the `runtime.Logger_Proc` behind runtime_logger. `data` must point to a Logger.
runtime_logger_proc :: proc(
	data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options,
	location := #caller_location,
) {
	l := (^Logger)(data)
	if l == nil {
		return
	}
	_ = log_attrs(l, level_from_runtime(level), text, loc = location)
}
