package slog

import "base:runtime"
import "core:time"

/*
Scope is one level of attributes bound to a logger.

The first scope of a logger has an empty group and holds its top-level
attributes. Each later scope comes from logger_with_group: its attributes, and
everything after it, nest under `group`.
*/
Scope :: struct {
	group: string,
	attrs: []Attr,
}

/*
Record is one log event, as a Handler receives it.

A Record and everything it points to are only valid during the handler call.
A handler that keeps a record must copy the parts it needs, for example with
attr_clone.
*/
Record :: struct {
	// time is when the logger made the record. The zero value means unknown;
	// the built-in handlers then leave out the time attribute.
	time:     time.Time,
	level:    Level,
	message:  string,
	// location is where the log call came from.
	location: runtime.Source_Code_Location,
	// scopes are the attributes and groups bound to the logger, outermost first.
	scopes:   []Scope,
	// attrs are the attributes of this call. They belong to the innermost scope.
	attrs:    []Attr,
}

// Handler_Proc writes or otherwise consumes one record.
Handler_Proc :: #type proc(data: rawptr, record: ^Record) -> Error

// Enabled_Proc reports whether a handler wants records at `level`.
Enabled_Proc :: #type proc(data: rawptr, level: Level) -> bool

/*
Handler is the back end of a Logger: a pair of procedures and the state they
share. Get one from text_handler, json_handler or discard_handler, or fill in
the fields to write your own.

A nil `enabled` means every level is enabled. A nil `handle` drops every record.
*/
Handler :: struct {
	handle:  Handler_Proc,
	enabled: Enabled_Proc,
	data:    rawptr,
}

// discard_handler returns a Handler that drops every record and reports every level as disabled.
discard_handler :: proc() -> Handler {
	return Handler {
		handle = proc(_: rawptr, _: ^Record) -> Error {
			return nil
		},
		enabled = proc(_: rawptr, _: Level) -> bool {
			return false
		},
	}
}

/*
Logger turns log calls into Records and passes them to its Handler.

Make a root logger with logger_make and child loggers with logger_with and
logger_with_group. Destroy every logger made by logger_with or
logger_with_group with logger_destroy. Destroying a parent does not affect its
children, because each child owns a full copy of its attributes.

A Logger is read-only after it is made, so several threads may log through
the same Logger at once, provided its handler is thread safe. The built-in
handlers are.
*/
Logger :: struct {
	handler:   Handler,
	scopes:    []Scope,
	allocator: runtime.Allocator,
}

/*
logger_make returns a root Logger that sends records to `handler`.

It does not allocate. `allocator` is stored for scratch space in log calls
that pass more than STACK_ATTRS attributes. A root logger needs no
logger_destroy, though calling it is harmless.
*/
logger_make :: proc(handler: Handler, allocator := context.allocator) -> Logger {
	return Logger{handler = handler, allocator = allocator}
}

/*
logger_with returns a child of `l` that adds the attributes in `args` to every
record. `args` follow the same key-value rules as info.

Inputs:
- l: the parent logger; it is not modified.
- args: key-value pairs or Attr values to bind.
- allocator: allocates the child's copy of every bound attribute.

Returns:
- child: owned by the caller; free it with logger_destroy.
- err: an allocator error. Nothing is leaked on failure.
*/
logger_with :: proc(l: ^Logger, args: ..any, allocator := context.allocator) -> (child: Logger, err: Error) {
	stack: [STACK_ATTRS]Attr
	attrs := stack[:]
	if len(args) > len(stack) {
		attrs = make([]Attr, len(args), allocator) or_return
	}
	defer if len(args) > len(stack) {
		delete(attrs, allocator)
	}
	n := args_to_attrs(args, attrs)
	return logger_with_attrs(l, ..attrs[:n], allocator = allocator)
}

/*
logger_with_attrs is logger_with for arguments that are already attributes.

Returns:
- child: owned by the caller; free it with logger_destroy.
- err: an allocator error. Nothing is leaked on failure.
*/
logger_with_attrs :: proc(l: ^Logger, attrs: ..Attr, allocator := context.allocator) -> (child: Logger, err: Error) {
	parent := l.scopes
	count := len(parent)
	if count == 0 {
		count = 1
	}
	scopes := scopes_clone(parent, count, allocator) or_return
	child = Logger{l.handler, scopes, allocator}
	defer if err != nil {
		logger_destroy(&child)
	}
	// Zeroed attributes are safe to destroy, so a partly filled slice can be
	// freed by logger_destroy if a clone fails halfway.
	last := &scopes[len(scopes) - 1]
	old := last.attrs
	merged := make([]Attr, len(old) + len(attrs), allocator) or_return
	copy(merged, old)
	delete(old, allocator)
	last.attrs = merged
	for a, i in attrs {
		merged[len(old) + i] = attr_clone(a, allocator) or_return
	}
	return child, nil
}

/*
logger_with_group returns a child of `l` that nests every later attribute,
bound or passed to a log call, under the group `name`. Groups that end up with
no attributes are left out of the output.

An empty `name` adds no group; the child then behaves like `l`.

Returns:
- child: owned by the caller; free it with logger_destroy.
- err: an allocator error. Nothing is leaked on failure.
*/
logger_with_group :: proc(l: ^Logger, name: string, allocator := context.allocator) -> (child: Logger, err: Error) {
	extra := 0 if len(name) == 0 else 1
	scopes := scopes_clone(l.scopes, len(l.scopes) + extra, allocator) or_return
	child = Logger{l.handler, scopes, allocator}
	if extra == 1 {
		group_name, cerr := clone_string(name, allocator)
		if cerr != nil {
			logger_destroy(&child)
			return {}, cerr
		}
		scopes[len(scopes) - 1].group = group_name
	}
	return child, nil
}

/*
logger_destroy frees the attributes and groups that `l` owns and zeroes it.
It uses the allocator that made the logger.
*/
logger_destroy :: proc(l: ^Logger) {
	scopes_destroy(l.scopes, l.allocator)
	l^ = {}
}

// enabled reports whether `l` would handle a record at `level`. A nil logger is never enabled.
enabled :: proc(l: ^Logger, level: Level) -> bool {
	if l == nil || l.handler.handle == nil {
		return false
	}
	if l.handler.enabled == nil {
		return true
	}
	return l.handler.enabled(l.handler.data, level)
}

// STACK_ATTRS is how many call attributes a log call holds without allocating.
STACK_ATTRS :: 16

/*
log emits a record at `level` with message `msg`.

`args` are key-value pairs and Attr values: `"user", name, slog.attr("n", 3)`.
A string followed by another argument is a key and its value. An Attr is used
as is. Anything else, including a trailing key with no value, gets the key
BAD_KEY so that the mistake shows in the output instead of being lost.

Returns the error from the handler, usually an `io.Error` from its writer.
Disabled levels return `nil` without formatting anything.
*/
log :: proc(l: ^Logger, level: Level, msg: string, args: ..any, loc := #caller_location) -> Error {
	if !enabled(l, level) {
		return nil
	}
	stack: [STACK_ATTRS]Attr
	attrs := stack[:]
	allocator := l.allocator if l.allocator.procedure != nil else context.allocator
	if len(args) > len(stack) {
		attrs = make([]Attr, len(args), allocator) or_return
	}
	defer if len(args) > len(stack) {
		delete(attrs, allocator)
	}
	n := args_to_attrs(args, attrs)
	return emit(l, level, msg, attrs[:n], loc)
}

/*
log_attrs emits a record whose arguments are already attributes. It skips the
key-value parsing of log and never allocates.
*/
log_attrs :: proc(l: ^Logger, level: Level, msg: string, attrs: ..Attr, loc := #caller_location) -> Error {
	if !enabled(l, level) {
		return nil
	}
	return emit(l, level, msg, attrs, loc)
}

// debug logs at Level.Debug. See log for the rules on `args`.
debug :: proc(l: ^Logger, msg: string, args: ..any, loc := #caller_location) -> Error {
	return log(l, .Debug, msg, ..args, loc = loc)
}

// info logs at Level.Info. See log for the rules on `args`.
info :: proc(l: ^Logger, msg: string, args: ..any, loc := #caller_location) -> Error {
	return log(l, .Info, msg, ..args, loc = loc)
}

// warn logs at Level.Warn. See log for the rules on `args`.
warn :: proc(l: ^Logger, msg: string, args: ..any, loc := #caller_location) -> Error {
	return log(l, .Warn, msg, ..args, loc = loc)
}

// error logs at Level.Error. See log for the rules on `args`.
error :: proc(l: ^Logger, msg: string, args: ..any, loc := #caller_location) -> Error {
	return log(l, .Error, msg, ..args, loc = loc)
}

@(private)
emit :: proc(l: ^Logger, level: Level, msg: string, attrs: []Attr, loc: runtime.Source_Code_Location) -> Error {
	record := Record {
		time     = time.now(),
		level    = level,
		message  = msg,
		location = loc,
		scopes   = l.scopes,
		attrs    = attrs,
	}
	return l.handler.handle(l.handler.data, &record)
}

// scopes_clone deep-copies `src` into a new slice of `count` scopes; extra scopes start empty.
@(private)
scopes_clone :: proc(src: []Scope, count: int, allocator: runtime.Allocator) -> (result: []Scope, err: runtime.Allocator_Error) {
	result = make([]Scope, count, allocator) or_return
	defer if err != nil {
		scopes_destroy(result, allocator)
	}
	for s, i in src {
		result[i].group = clone_string(s.group, allocator) or_return
		result[i].attrs = make([]Attr, len(s.attrs), allocator) or_return
		for a, j in s.attrs {
			result[i].attrs[j] = attr_clone(a, allocator) or_return
		}
	}
	return result, nil
}

@(private)
scopes_destroy :: proc(scopes: []Scope, allocator: runtime.Allocator) {
	for s in scopes {
		delete(s.group, allocator)
		for a in s.attrs {
			attr_destroy(a, allocator)
		}
		delete(s.attrs, allocator)
	}
	delete(scopes, allocator)
}
