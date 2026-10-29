package slog

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"

// TIME_KEY is the key of the built-in time attribute.
TIME_KEY :: "time"
// LEVEL_KEY is the key of the built-in level attribute.
LEVEL_KEY :: "level"
// MESSAGE_KEY is the key of the built-in message attribute.
MESSAGE_KEY :: "msg"
// SOURCE_KEY is the key of the built-in source attribute, written when Handler_Options.add_source is set.
SOURCE_KEY :: "source"

/*
Replace_Attr_Proc rewrites or drops an attribute before a handler writes it.

`groups` lists the groups that enclose the attribute, outermost first; it is
empty for the built-in attributes. Return `keep = false` to drop the attribute.
The procedure is not called for group attributes themselves, only for their
members. The built-in attributes arrive as follows: time as a `time.Time`,
level, message and source as strings.
*/
Replace_Attr_Proc :: #type proc(groups: []string, a: Attr, user_data: rawptr) -> (result: Attr, keep: bool)

// Handler_Options configures Text_Handler and JSON_Handler. The zero value logs `.Info` and above.
Handler_Options :: struct {
	// level is the minimum level to write. Ignored when level_var is set.
	level:             Level,
	// level_var, when set, holds a minimum level that can change at run time.
	level_var:         ^Level_Var,
	// add_source writes the caller's `file:line` as the source attribute.
	add_source:        bool,
	// omit_time leaves out the time attribute, which helps tests and log
	// collectors that add their own timestamps.
	omit_time:         bool,
	// replace_attr, when set, sees every attribute before it is written.
	replace_attr:      Replace_Attr_Proc,
	// replace_attr_data is passed to replace_attr as `user_data`.
	replace_attr_data: rawptr,
}

/*
Text_Handler writes each record as one line of space-separated `key=value`
pairs, in the format of Go's slog.TextHandler:

	time=2026-10-29T17:13:00.123Z level=INFO msg="request done" req.path=/ status=200

Values that contain spaces, quotes, `=` or unprintable characters are quoted
with Go-style escapes. Keys inside groups are joined with dots.

A Text_Handler is safe to use from several threads at once: it formats each
record into its own buffer and writes it with a single call while holding a
mutex. It must not be copied after text_handler_init.
*/
Text_Handler :: struct {
	state: Stream_State,
}

/*
JSON_Handler writes each record as one JSON object per line, in the format of
Go's slog.JSONHandler:

	{"time":"2026-10-29T17:13:00.123Z","level":"INFO","msg":"request done","req":{"path":"/"},"status":200}

Groups become nested objects. Durations are written as integer nanoseconds,
and NaN and infinite floats as the strings "NaN", "+Inf" and "-Inf".

A JSON_Handler has the same thread safety as Text_Handler and must not be
copied after json_handler_init.
*/
JSON_Handler :: struct {
	state: Stream_State,
}

// Stream_State is the shared state of Text_Handler and JSON_Handler. Treat it as opaque.
Stream_State :: struct {
	writer:    io.Writer,
	options:   Handler_Options,
	allocator: runtime.Allocator,
	json:      bool,
	mutex:     sync.Mutex,
	line:      strings.Builder,
	scratch:   strings.Builder,
	groups:    [dynamic]string,
}

/*
text_handler_init prepares `h` to write text records to `w`.

`allocator` backs the handler's reusable line buffer. Call
text_handler_destroy when every logger that uses the handler is done.
*/
text_handler_init :: proc(h: ^Text_Handler, w: io.Writer, options := Handler_Options{}, allocator := context.allocator) {
	stream_init(&h.state, w, options, false, allocator)
}

// text_handler_destroy frees the buffers of `h`. It does not close the writer.
text_handler_destroy :: proc(h: ^Text_Handler) {
	stream_destroy(&h.state)
}

// text_handler returns the Handler interface of `h`, for logger_make. `h` must outlive the loggers.
text_handler :: proc(h: ^Text_Handler) -> Handler {
	return Handler{stream_handle, stream_enabled, &h.state}
}

/*
json_handler_init prepares `h` to write JSON records to `w`.

`allocator` backs the handler's reusable line buffer. Call
json_handler_destroy when every logger that uses the handler is done.
*/
json_handler_init :: proc(h: ^JSON_Handler, w: io.Writer, options := Handler_Options{}, allocator := context.allocator) {
	stream_init(&h.state, w, options, true, allocator)
}

// json_handler_destroy frees the buffers of `h`. It does not close the writer.
json_handler_destroy :: proc(h: ^JSON_Handler) {
	stream_destroy(&h.state)
}

// json_handler returns the Handler interface of `h`, for logger_make. `h` must outlive the loggers.
json_handler :: proc(h: ^JSON_Handler) -> Handler {
	return Handler{stream_handle, stream_enabled, &h.state}
}

@(private)
stream_init :: proc(s: ^Stream_State, w: io.Writer, options: Handler_Options, json: bool, allocator: runtime.Allocator) {
	s^ = {}
	s.writer = w
	s.options = options
	s.json = json
	s.allocator = allocator
	s.line = strings.builder_make_none(allocator)
	s.scratch = strings.builder_make_none(allocator)
	s.groups = make([dynamic]string, allocator)
}

@(private)
stream_destroy :: proc(s: ^Stream_State) {
	strings.builder_destroy(&s.line)
	strings.builder_destroy(&s.scratch)
	delete(s.groups)
	s^ = {}
}

@(private)
stream_enabled :: proc(data: rawptr, level: Level) -> bool {
	s := (^Stream_State)(data)
	minimum := s.options.level
	if s.options.level_var != nil {
		minimum = level_var_get(s.options.level_var)
	}
	return level >= minimum
}

@(private)
stream_handle :: proc(data: rawptr, r: ^Record) -> Error {
	s := (^Stream_State)(data)
	sync.mutex_guard(&s.mutex)

	strings.builder_reset(&s.line)
	clear(&s.groups)
	if s.json {
		json_record(s, r)
	} else {
		text_record(s, r)
	}
	strings.write_byte(&s.line, '\n')

	out := s.line.buf[:]
	n, err := io.write(s.writer, out)
	if err != nil {
		return err
	}
	if n < len(out) {
		return io.Error.Short_Write
	}
	return nil
}

// builtin_attrs collects the time, level, source and message attributes in output order.
@(private)
builtin_attrs :: proc(s: ^Stream_State, r: ^Record, level_buf: []byte, source_buf: []byte) -> (attrs: [4]Attr, n: int) {
	if !s.options.omit_time && r.time != {} {
		attrs[n] = {TIME_KEY, r.time}
		n += 1
	}
	attrs[n] = {LEVEL_KEY, level_string(r.level, level_buf)}
	n += 1
	if s.options.add_source {
		b := strings.builder_from_bytes(source_buf)
		strings.write_string(&b, r.location.file_path)
		strings.write_byte(&b, ':')
		strings.write_int(&b, int(r.location.line))
		attrs[n] = {SOURCE_KEY, strings.to_string(b)}
		n += 1
	}
	attrs[n] = {MESSAGE_KEY, r.message}
	n += 1
	return
}

// replace applies the user's replace_attr hook, if any. Group attributes pass through.
@(private)
replace :: proc(s: ^Stream_State, a: Attr) -> (Attr, bool) {
	if s.options.replace_attr == nil {
		return a, true
	}
	if _, is_group := a.value.([]Attr); is_group {
		return a, true
	}
	return s.options.replace_attr(s.groups[:], a, s.options.replace_attr_data)
}

// attr_is_empty reports whether `a` would write nothing: an empty key with a nil value, or a group with no members.
@(private)
attr_is_empty :: proc(a: Attr) -> bool {
	if g, is_group := a.value.([]Attr); is_group {
		return !attrs_have_output(g)
	}
	return a.key == "" && a.value == nil
}

@(private)
attrs_have_output :: proc(attrs: []Attr) -> bool {
	for a in attrs {
		if !attr_is_empty(a) {
			return true
		}
	}
	return false
}

// ---- Text ----

@(private)
text_record :: proc(s: ^Stream_State, r: ^Record) {
	level_buf: [LEVEL_STRING_SIZE]byte
	source_buf: [512]byte
	builtins, n := builtin_attrs(s, r, level_buf[:], source_buf[:])
	for a in builtins[:n] {
		text_attr(s, a)
	}
	for scope in r.scopes {
		if scope.group != "" {
			append(&s.groups, scope.group)
		}
		for a in scope.attrs {
			text_attr(s, a)
		}
	}
	for a in r.attrs {
		text_attr(s, a)
	}
}

@(private)
text_attr :: proc(s: ^Stream_State, attr: Attr) {
	a, keep := replace(s, attr)
	if !keep || attr_is_empty(a) {
		return
	}
	if g, is_group := a.value.([]Attr); is_group {
		if a.key != "" {
			append(&s.groups, a.key)
		}
		for member in g {
			text_attr(s, member)
		}
		if a.key != "" {
			pop(&s.groups)
		}
		return
	}

	b := &s.line
	if len(b.buf) > 0 {
		strings.write_byte(b, ' ')
	}
	if len(s.groups) == 0 {
		text_write_string(b, a.key)
	} else {
		strings.builder_reset(&s.scratch)
		for g in s.groups {
			strings.write_string(&s.scratch, g)
			strings.write_byte(&s.scratch, '.')
		}
		strings.write_string(&s.scratch, a.key)
		text_write_string(b, strings.to_string(s.scratch))
	}
	strings.write_byte(b, '=')
	text_value(s, a.value)
}

@(private)
text_value :: proc(s: ^Stream_State, v: Value) {
	b := &s.line
	switch x in v {
	case nil:
		strings.write_string(b, "<nil>")
	case bool:
		strings.write_string(b, "true" if x else "false")
	case i64:
		strings.write_i64(b, x)
	case u64:
		strings.write_u64(b, x)
	case f64:
		write_float(b, x)
	case string:
		text_write_string(b, x)
	case time.Time:
		write_time(b, x)
	case time.Duration:
		write_duration(b, x)
	case []Attr:
		// Groups are expanded by text_attr and never reach here.
	case any:
		strings.builder_reset(&s.scratch)
		fmt.sbprint(&s.scratch, x)
		text_write_string(b, strings.to_string(s.scratch))
	}
}

// text_write_string writes `str` bare when it is safe, quoted otherwise.
@(private)
text_write_string :: proc(b: ^strings.Builder, str: string) {
	if text_needs_quoting(str) {
		write_go_quoted(b, str)
	} else {
		strings.write_string(b, str)
	}
}

@(private)
text_needs_quoting :: proc(str: string) -> bool {
	if len(str) == 0 {
		return true
	}
	for i := 0; i < len(str); {
		c := str[i]
		if c < utf8.RUNE_SELF {
			if c <= ' ' || c == '=' || c == '"' || c == 0x7f {
				return true
			}
			i += 1
			continue
		}
		r, size := utf8.decode_rune_in_string(str[i:])
		if r == utf8.RUNE_ERROR || unicode.is_space(r) || !unicode.is_print(r) {
			return true
		}
		i += size
	}
	return false
}

// write_go_quoted writes `str` as a double-quoted string with the escapes of Go's strconv.Quote.
@(private)
write_go_quoted :: proc(b: ^strings.Builder, str: string) {
	hex := "0123456789abcdef"
	strings.write_byte(b, '"')
	for i := 0; i < len(str); {
		c := str[i]
		if c >= utf8.RUNE_SELF {
			r, size := utf8.decode_rune_in_string(str[i:])
			switch {
			case r == utf8.RUNE_ERROR && size == 1:
				strings.write_string(b, `\x`)
				strings.write_byte(b, hex[c >> 4])
				strings.write_byte(b, hex[c & 0xf])
			case unicode.is_print(r):
				strings.write_string(b, str[i:i + size])
			case:
				strings.write_string(b, `\u`)
				for shift := uint(12);; shift -= 4 {
					strings.write_byte(b, hex[(u32(r) >> shift) & 0xf])
					if shift == 0 {
						break
					}
				}
			}
			i += size
			continue
		}
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			if c < ' ' || c == 0x7f {
				strings.write_string(b, `\x`)
				strings.write_byte(b, hex[c >> 4])
				strings.write_byte(b, hex[c & 0xf])
			} else {
				strings.write_byte(b, c)
			}
		}
		i += 1
	}
	strings.write_byte(b, '"')
}

// ---- JSON ----

@(private)
json_record :: proc(s: ^Stream_State, r: ^Record) {
	level_buf: [LEVEL_STRING_SIZE]byte
	source_buf: [512]byte
	strings.write_byte(&s.line, '{')
	builtins, n := builtin_attrs(s, r, level_buf[:], source_buf[:])
	for a in builtins[:n] {
		json_attr(s, a)
	}
	opened := 0
	for scope, i in r.scopes {
		if scope.group != "" {
			if !scopes_have_output(r, i) {
				break
			}
			json_open_group(s, scope.group)
			opened += 1
		}
		for a in scope.attrs {
			json_attr(s, a)
		}
	}
	// When a trailing group was skipped, the call attributes belong to it and
	// are empty too, so writing them below is a no-op.
	for a in r.attrs {
		json_attr(s, a)
	}
	for _ in 0 ..< opened {
		strings.write_byte(&s.line, '}')
	}
	clear(&s.groups)
	strings.write_byte(&s.line, '}')
}

// scopes_have_output reports whether scope `from` or anything after it writes an attribute.
@(private)
scopes_have_output :: proc(r: ^Record, from: int) -> bool {
	for scope in r.scopes[from:] {
		if attrs_have_output(scope.attrs) {
			return true
		}
	}
	return attrs_have_output(r.attrs)
}

@(private)
json_separator :: proc(b: ^strings.Builder) {
	if len(b.buf) > 0 && b.buf[len(b.buf) - 1] != '{' {
		strings.write_byte(b, ',')
	}
}

@(private)
json_open_group :: proc(s: ^Stream_State, name: string) {
	json_separator(&s.line)
	json_write_string(&s.line, name)
	strings.write_string(&s.line, ":{")
	append(&s.groups, name)
}

@(private)
json_attr :: proc(s: ^Stream_State, attr: Attr) {
	a, keep := replace(s, attr)
	if !keep || attr_is_empty(a) {
		return
	}
	if g, is_group := a.value.([]Attr); is_group {
		if a.key != "" {
			json_open_group(s, a.key)
		}
		for member in g {
			json_attr(s, member)
		}
		if a.key != "" {
			pop(&s.groups)
			strings.write_byte(&s.line, '}')
		}
		return
	}
	json_separator(&s.line)
	json_write_string(&s.line, a.key)
	strings.write_byte(&s.line, ':')
	json_value(s, a.value)
}

@(private)
json_value :: proc(s: ^Stream_State, v: Value) {
	b := &s.line
	switch x in v {
	case nil:
		strings.write_string(b, "null")
	case bool:
		strings.write_string(b, "true" if x else "false")
	case i64:
		strings.write_i64(b, x)
	case u64:
		strings.write_u64(b, x)
	case f64:
		switch {
		case math.is_nan(x):
			strings.write_string(b, `"NaN"`)
		case math.is_inf(x, 1):
			strings.write_string(b, `"+Inf"`)
		case math.is_inf(x, -1):
			strings.write_string(b, `"-Inf"`)
		case:
			write_float(b, x)
		}
	case string:
		json_write_string(b, x)
	case time.Time:
		strings.write_byte(b, '"')
		write_time(b, x)
		strings.write_byte(b, '"')
	case time.Duration:
		strings.write_i64(b, i64(x))
	case []Attr:
		// Groups are expanded by json_attr and never reach here.
	case any:
		strings.builder_reset(&s.scratch)
		fmt.sbprint(&s.scratch, x)
		json_write_string(b, strings.to_string(s.scratch))
	}
}

// json_write_string writes `str` as a JSON string. Invalid UTF-8 becomes U+FFFD.
@(private)
json_write_string :: proc(b: ^strings.Builder, str: string) {
	hex := "0123456789abcdef"
	strings.write_byte(b, '"')
	for i := 0; i < len(str); {
		c := str[i]
		if c >= utf8.RUNE_SELF {
			r, size := utf8.decode_rune_in_string(str[i:])
			switch {
			case r == utf8.RUNE_ERROR && size == 1:
				strings.write_string(b, `�`)
			case r == 0x2028:
				strings.write_string(b, ` `)
			case r == 0x2029:
				strings.write_string(b, ` `)
			case:
				strings.write_string(b, str[i:i + size])
			}
			i += size
			continue
		}
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			if c < ' ' {
				strings.write_string(b, `\u00`)
				strings.write_byte(b, hex[c >> 4])
				strings.write_byte(b, hex[c & 0xf])
			} else {
				strings.write_byte(b, c)
			}
		}
		i += 1
	}
	strings.write_byte(b, '"')
}

// ---- Shared formatting ----

// write_float writes the shortest representation of `f`, like Go's strconv 'g' with precision -1.
@(private)
write_float :: proc(b: ^strings.Builder, f: f64) {
	buf: [64]byte
	str := strconv.write_float(buf[:], f, 'g', -1, 64)
	if len(str) > 0 && str[0] == '+' {
		str = str[1:]
	}
	strings.write_string(b, str)
}

// write_time writes `t` in UTC as RFC 3339 with milliseconds, for example `2026-10-29T17:13:00.123Z`.
@(private)
write_time :: proc(b: ^strings.Builder, t: time.Time) {
	year, month, day := time.date(t)
	hour, minute, second, nanos := time.precise_clock(t)
	write_padded(b, year, 4)
	strings.write_byte(b, '-')
	write_padded(b, int(month), 2)
	strings.write_byte(b, '-')
	write_padded(b, day, 2)
	strings.write_byte(b, 'T')
	write_padded(b, hour, 2)
	strings.write_byte(b, ':')
	write_padded(b, minute, 2)
	strings.write_byte(b, ':')
	write_padded(b, second, 2)
	strings.write_byte(b, '.')
	write_padded(b, nanos / 1_000_000, 3)
	strings.write_byte(b, 'Z')
}

@(private)
write_padded :: proc(b: ^strings.Builder, value: int, width: int) {
	value := value
	if value < 0 {
		strings.write_byte(b, '-')
		value = -value
	}
	digits := 1
	for v := value / 10; v > 0; v /= 10 {
		digits += 1
	}
	for _ in digits ..< width {
		strings.write_byte(b, '0')
	}
	strings.write_int(b, value)
}

/*
write_duration writes `d` the way Go's time.Duration.String does, for example
`1.5s`, `2m3s`, `1h0m0s`, `250ms` or `0s`.
*/
@(private)
write_duration :: proc(b: ^strings.Builder, d: time.Duration) {
	buf: [32]byte
	w := len(buf)
	u := u64(d)
	negative := d < 0
	if negative {
		u = -u
	}
	if u < u64(time.Second) {
		precision := 0
		w -= 1
		buf[w] = 's'
		w -= 1
		switch {
		case u == 0:
			strings.write_string(b, "0s")
			return
		case u < u64(time.Microsecond):
			buf[w] = 'n'
		case u < u64(time.Millisecond):
			precision = 3
			// U+00B5 MICRO SIGN is two bytes in UTF-8.
			w -= 1
			buf[w], buf[w + 1] = 0xc2, 0xb5
		case:
			precision = 6
			buf[w] = 'm'
		}
		w, u = format_fraction(buf[:w], u, precision)
		w = format_uint(buf[:w], u)
	} else {
		w -= 1
		buf[w] = 's'
		w, u = format_fraction(buf[:w], u, 9)
		w = format_uint(buf[:w], u % 60)
		u /= 60
		if u > 0 {
			w -= 1
			buf[w] = 'm'
			w = format_uint(buf[:w], u % 60)
			u /= 60
			if u > 0 {
				w -= 1
				buf[w] = 'h'
				w = format_uint(buf[:w], u)
			}
		}
	}
	if negative {
		w -= 1
		buf[w] = '-'
	}
	strings.write_bytes(b, buf[w:])
}

// format_fraction writes the fractional part of `v` with `precision` digits, dropping trailing zeros.
@(private)
format_fraction :: proc(buf: []byte, v: u64, precision: int) -> (w: int, rest: u64) {
	w = len(buf)
	rest = v
	printing := false
	for _ in 0 ..< precision {
		digit := rest % 10
		printing = printing || digit != 0
		if printing {
			w -= 1
			buf[w] = byte(digit) + '0'
		}
		rest /= 10
	}
	if printing {
		w -= 1
		buf[w] = '.'
	}
	return
}

// format_uint writes `v` right-aligned at the end of `buf` and returns the start index.
@(private)
format_uint :: proc(buf: []byte, v: u64) -> int {
	w := len(buf)
	v := v
	if v == 0 {
		w -= 1
		buf[w] = '0'
		return w
	}
	for v > 0 {
		w -= 1
		buf[w] = byte(v % 10) + '0'
		v /= 10
	}
	return w
}
