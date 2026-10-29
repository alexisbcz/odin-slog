package slog

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strings"
import "core:time"

/*
Value is the value half of an attribute.

- `nil` prints as `<nil>` in text and `null` in JSON.
- Every integer type becomes `i64`, or `u64` when unsigned. Every float becomes `f64`.
- `time.Time` and `time.Duration` keep their types so handlers can format them.
- `[]Attr` is a group: its attributes nest under the attribute's key.
- `any` holds everything else, such as enums, error unions and structs.
  Handlers format it with `fmt`.
*/
Value :: union {
	bool,
	i64,
	u64,
	f64,
	string,
	time.Time,
	time.Duration,
	[]Attr,
	any,
}

/*
Attr is a key-value pair.

An Attr borrows its key, its string value and its group slice. That is fine
for the arguments of a log call, which handlers consume before the call
returns. logger_with copies attributes, so a child logger never borrows them.
*/
Attr :: struct {
	key:   string,
	value: Value,
}

/*
BAD_KEY is the key used for a log argument that has no key: a trailing string
with no value after it, or a value that is neither a string key nor an Attr.
*/
BAD_KEY :: "!BADKEY"

// attr_bool returns an Attr holding a bool.
attr_bool :: proc(key: string, value: bool) -> Attr {
	return {key, value}
}

// attr_int returns an Attr holding an int, stored as i64.
attr_int :: proc(key: string, value: int) -> Attr {
	return {key, i64(value)}
}

// attr_i64 returns an Attr holding an i64.
attr_i64 :: proc(key: string, value: i64) -> Attr {
	return {key, value}
}

// attr_u64 returns an Attr holding a u64.
attr_u64 :: proc(key: string, value: u64) -> Attr {
	return {key, value}
}

// attr_f64 returns an Attr holding an f64.
attr_f64 :: proc(key: string, value: f64) -> Attr {
	return {key, value}
}

// attr_string returns an Attr holding a string. The Attr borrows `value`.
attr_string :: proc(key: string, value: string) -> Attr {
	return {key, value}
}

// attr_time returns an Attr holding a point in time.
attr_time :: proc(key: string, value: time.Time) -> Attr {
	return {key, value}
}

// attr_duration returns an Attr holding a duration.
attr_duration :: proc(key: string, value: time.Duration) -> Attr {
	return {key, value}
}

/*
attr_any returns an Attr for a value of any type. Numbers, bools, strings,
times and durations get their typed Value; everything else is kept as `any`
and formatted with `fmt` when a handler writes it.
*/
attr_any :: proc(key: string, value: any) -> Attr {
	return {key, value_from_any(value)}
}

/*
attr picks the typed constructor that matches `value`:
attr_bool, attr_int, attr_f64, attr_string, attr_time or attr_duration.
*/
attr :: proc {
	attr_bool,
	attr_int,
	attr_f64,
	attr_string,
	attr_time,
	attr_duration,
}

/*
group returns an Attr whose value is the group `attrs`.

Pass the members as a slice literal, which lives until the end of the
enclosing block:

	slog.info(&logger, "request", slog.group("req", {slog.attr("method", "GET"), slog.attr("status", 200)}))

The Attr borrows `attrs` and never allocates. logger_with copies groups, so a
child logger does not borrow them. A group with no attributes is left out of
the output. A group with an empty key adds its attributes to the enclosing
level instead of nesting them.
*/
group :: proc(key: string, attrs: []Attr) -> Attr {
	return {key, attrs}
}

/*
value_from_any converts a dynamically typed value to a Value. It does not
allocate; a string Value borrows the original string.
*/
value_from_any :: proc(a: any) -> Value {
	if a.id == nil {
		return nil
	}
	switch a.id {
	case Value:
		return (^Value)(a.data)^
	case time.Time:
		return (^time.Time)(a.data)^
	case time.Duration:
		return (^time.Duration)(a.data)^
	case []Attr:
		return (^[]Attr)(a.data)^
	}
	info := runtime.type_info_base(type_info_of(a.id))
	#partial switch v in info.variant {
	case runtime.Type_Info_Boolean:
		if b, ok := reflect.as_bool(a); ok {
			return b
		}
	case runtime.Type_Info_Integer:
		if v.signed {
			if i, ok := reflect.as_i64(a); ok {
				return i
			}
		} else {
			if u, ok := reflect.as_u64(a); ok {
				return u
			}
		}
	case runtime.Type_Info_Float:
		if f, ok := reflect.as_f64(a); ok {
			return f
		}
	case runtime.Type_Info_String:
		if s, ok := reflect.as_string(a); ok {
			return s
		}
	}
	return a
}

/*
args_to_attrs turns the variadic arguments of a log call into attributes,
following Go's rules: an Attr is used as is, a string followed by another
argument is a key and its value, and anything else gets the key BAD_KEY.

`out` must hold at least `len(args)` elements. Returns how many were written.
The attributes borrow from `args`.
*/
args_to_attrs :: proc(args: []any, out: []Attr) -> int {
	n, i := 0, 0
	for i < len(args) && n < len(out) {
		arg := args[i]
		if arg.id == Attr {
			out[n] = (^Attr)(arg.data)^
			i += 1
		} else if arg.id == string && i + 1 < len(args) {
			out[n] = Attr{(^string)(arg.data)^, value_from_any(args[i + 1])}
			i += 2
		} else {
			out[n] = Attr{BAD_KEY, value_from_any(arg)}
			i += 1
		}
		n += 1
	}
	return n
}

/*
attr_clone returns a deep copy of `a` that borrows nothing.

The key, string values and groups are copied, and an `any` value is formatted
to a string with `fmt`, because the memory it points to may not outlive the
call.

Returns:
- result: owned by the caller; free it with attr_destroy and the same allocator.
- err: an allocator error. Nothing is leaked on failure.
*/
attr_clone :: proc(a: Attr, allocator := context.allocator) -> (result: Attr, err: runtime.Allocator_Error) {
	key := clone_string(a.key, allocator) or_return
	defer if err != nil {
		delete(key, allocator)
	}
	value := value_clone(a.value, allocator) or_return
	return Attr{key, value}, nil
}

// attr_destroy frees an Attr made by attr_clone. `allocator` must be the one passed to attr_clone.
attr_destroy :: proc(a: Attr, allocator := context.allocator) {
	delete(a.key, allocator)
	value_destroy(a.value, allocator)
}

@(private)
value_clone :: proc(v: Value, allocator: runtime.Allocator) -> (result: Value, err: runtime.Allocator_Error) {
	switch x in v {
	case string:
		return clone_string(x, allocator)
	case []Attr:
		attrs := make([]Attr, len(x), allocator) or_return
		for src, i in x {
			c, cerr := attr_clone(src, allocator)
			if cerr != nil {
				for j in 0 ..< i {
					attr_destroy(attrs[j], allocator)
				}
				delete(attrs, allocator)
				return nil, cerr
			}
			attrs[i] = c
		}
		return attrs, nil
	case any:
		// Reserve up front so that a failing allocator reports an error
		// instead of producing a silently empty string.
		b := strings.builder_make_len_cap(0, 32, allocator) or_return
		fmt.sbprint(&b, x)
		return strings.to_string(b), nil
	case bool, i64, u64, f64, time.Time, time.Duration:
		return v, nil
	}
	return nil, nil
}

@(private)
value_destroy :: proc(v: Value, allocator: runtime.Allocator) {
	#partial switch x in v {
	case string:
		delete(x, allocator)
	case []Attr:
		for a in x {
			attr_destroy(a, allocator)
		}
		delete(x, allocator)
	}
}

@(private)
clone_string :: proc(s: string, allocator: runtime.Allocator) -> (result: string, err: runtime.Allocator_Error) {
	if len(s) == 0 {
		return "", nil
	}
	buf := make([]byte, len(s), allocator) or_return
	copy(buf, s)
	return string(buf), nil
}
