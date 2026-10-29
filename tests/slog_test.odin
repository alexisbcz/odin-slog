// Package slog_tests holds the unit tests for slog. Run them with `odin test tests`.
package slog_tests

import slog ".."
import "base:runtime"
import "core:io"
import "core:log"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

// ---- Fixtures ----

// Fixture wires a logger to an in-memory buffer through a tracking allocator.
Fixture :: struct {
	t:      ^testing.T,
	track:  mem.Tracking_Allocator,
	alloc:  runtime.Allocator,
	out:    strings.Builder,
	text:   slog.Text_Handler,
	json:   slog.JSON_Handler,
	logger: slog.Logger,
}

NO_TIME :: slog.Handler_Options{omit_time = true}

fixture_init :: proc(f: ^Fixture, t: ^testing.T, json := false, options := NO_TIME) {
	f.t = t
	mem.tracking_allocator_init(&f.track, context.allocator)
	f.alloc = mem.tracking_allocator(&f.track)
	f.out = strings.builder_make(f.alloc)
	if json {
		slog.json_handler_init(&f.json, strings.to_writer(&f.out), options, f.alloc)
		f.logger = slog.logger_make(slog.json_handler(&f.json), f.alloc)
	} else {
		slog.text_handler_init(&f.text, strings.to_writer(&f.out), options, f.alloc)
		f.logger = slog.logger_make(slog.text_handler(&f.text), f.alloc)
	}
}

// fixture_destroy frees everything and fails the test on any leak or bad free.
fixture_destroy :: proc(f: ^Fixture) {
	slog.text_handler_destroy(&f.text)
	slog.json_handler_destroy(&f.json)
	strings.builder_destroy(&f.out)
	testing.expectf(f.t, len(f.track.allocation_map) == 0, "leaked %d allocations", len(f.track.allocation_map))
	testing.expectf(f.t, len(f.track.bad_free_array) == 0, "%d bad frees", len(f.track.bad_free_array))
	mem.tracking_allocator_destroy(&f.track)
}

// take returns what was logged so far and resets the buffer. The result is only valid until the next log call.
take :: proc(f: ^Fixture) -> string {
	s := strings.clone(strings.to_string(f.out), context.temp_allocator)
	strings.builder_reset(&f.out)
	return s
}

// Failing_Allocator fails every allocation after `remaining` successful ones.
Failing_Allocator :: struct {
	backing:   runtime.Allocator,
	remaining: int,
}

failing_allocator :: proc(fa: ^Failing_Allocator) -> runtime.Allocator {
	return {procedure = failing_allocator_proc, data = fa}
}

failing_allocator_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	fa := (^Failing_Allocator)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if fa.remaining <= 0 {
			return nil, .Out_Of_Memory
		}
		fa.remaining -= 1
	}
	return fa.backing.procedure(fa.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// Broken_Writer returns `err` from every write, or accepts only half the bytes when `err` is nil.
Broken_Writer :: struct {
	err: io.Error,
}

broken_writer :: proc(w: ^Broken_Writer) -> io.Writer {
	return {procedure = broken_writer_proc, data = w}
}

broken_writer_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	w := (^Broken_Writer)(data)
	#partial switch mode {
	case .Write:
		if w.err != nil {
			return 0, w.err
		}
		return i64(len(p) / 2), nil
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Unsupported
}

Color :: enum {
	Red,
	Green,
}

User_Id :: distinct int

Point :: struct {
	x, y: int,
}

// ---- Levels ----

@(test)
test_level_string_named_levels :: proc(t: ^testing.T) {
	buf: [slog.LEVEL_STRING_SIZE]byte
	testing.expect_value(t, slog.level_string(.Debug, buf[:]), "DEBUG")
	testing.expect_value(t, slog.level_string(.Info, buf[:]), "INFO")
	testing.expect_value(t, slog.level_string(.Warn, buf[:]), "WARN")
	testing.expect_value(t, slog.level_string(.Error, buf[:]), "ERROR")
}

@(test)
test_level_string_offsets :: proc(t: ^testing.T) {
	buf: [slog.LEVEL_STRING_SIZE]byte
	testing.expect_value(t, slog.level_string(slog.Level(2), buf[:]), "INFO+2")
	testing.expect_value(t, slog.level_string(slog.Level(-5), buf[:]), "DEBUG-1")
	testing.expect_value(t, slog.level_string(slog.Level(5), buf[:]), "WARN+1")
	testing.expect_value(t, slog.level_string(slog.Level(12), buf[:]), "ERROR+4")
}

@(test)
test_level_string_extremes_fit_buffer :: proc(t: ^testing.T) {
	buf: [slog.LEVEL_STRING_SIZE]byte
	testing.expect_value(t, slog.level_string(slog.Level(max(i32)), buf[:]), "ERROR+2147483639")
	testing.expect_value(t, slog.level_string(slog.Level(min(i32)), buf[:]), "DEBUG-2147483644")
}

@(test)
test_level_string_truncates_small_buffer :: proc(t: ^testing.T) {
	buf: [3]byte
	testing.expect_value(t, slog.level_string(.Error, buf[:]), "ERR")
}

@(test)
test_level_parse_names_case_insensitive :: proc(t: ^testing.T) {
	cases := [?]struct {
		text: string,
		want: slog.Level,
	}{{"debug", .Debug}, {"INFO", .Info}, {"Warn", .Warn}, {"warning", .Warn}, {"ERROR", .Error}}
	for c in cases {
		level, err := slog.level_parse(c.text)
		testing.expect_value(t, err, slog.Level_Error.None)
		testing.expect_value(t, level, c.want)
	}
}

@(test)
test_level_parse_offsets :: proc(t: ^testing.T) {
	level, err := slog.level_parse("info+2")
	testing.expect_value(t, err, slog.Level_Error.None)
	testing.expect_value(t, level, slog.Level(2))

	level, err = slog.level_parse("ERROR-3")
	testing.expect_value(t, err, slog.Level_Error.None)
	testing.expect_value(t, level, slog.Level(5))
}

@(test)
test_level_parse_round_trips_level_string :: proc(t: ^testing.T) {
	buf: [slog.LEVEL_STRING_SIZE]byte
	for v in -10 ..= 20 {
		level, err := slog.level_parse(slog.level_string(slog.Level(v), buf[:]))
		testing.expect_value(t, err, slog.Level_Error.None)
		testing.expect_value(t, level, slog.Level(v))
	}
}

@(test)
test_level_parse_trims_whitespace :: proc(t: ^testing.T) {
	level, err := slog.level_parse("  warn\n")
	testing.expect_value(t, err, slog.Level_Error.None)
	testing.expect_value(t, level, slog.Level.Warn)
}

@(test)
test_level_parse_rejects_empty :: proc(t: ^testing.T) {
	_, err := slog.level_parse("")
	testing.expect_value(t, err, slog.Level_Error.Empty)
	_, err = slog.level_parse("   ")
	testing.expect_value(t, err, slog.Level_Error.Empty)
}

@(test)
test_level_parse_rejects_unknown_name :: proc(t: ^testing.T) {
	for text in ([]string{"loud", "inf", "information", "+2", "fatal"}) {
		_, err := slog.level_parse(text)
		testing.expectf(t, err == .Unknown_Name, "%q: got %v", text, err)
	}
}

@(test)
test_level_parse_rejects_malformed_offset :: proc(t: ^testing.T) {
	for text in ([]string{"info+", "info-", "info+x", "info++1", "info+1.5", "info+ 1", "info+1a"}) {
		level, err := slog.level_parse(text)
		testing.expectf(t, err == .Invalid_Offset, "%q: got %v", text, err)
		testing.expect_value(t, level, slog.Level.Info)
	}
}

@(test)
test_level_parse_rejects_overflow :: proc(t: ^testing.T) {
	_, err := slog.level_parse("error+2147483647")
	testing.expect_value(t, err, slog.Level_Error.Invalid_Offset)
	_, err = slog.level_parse("info+99999999999999999999")
	testing.expect_value(t, err, slog.Level_Error.Invalid_Offset)
}

@(test)
test_level_parse_error_converts_to_error_union :: proc(t: ^testing.T) {
	_, perr := slog.level_parse("nope")
	err: slog.Error = perr
	testing.expect_value(t, err, slog.Error(slog.Level_Error.Unknown_Name))
}

// ---- Text handler ----

@(test)
test_text_basic_line :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	err := slog.info(&f.logger, "hello", "user", "ana", "n", 3)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, take(&f), "level=INFO msg=hello user=ana n=3\n")
}

@(test)
test_text_each_level_name :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, options = {level = .Debug, omit_time = true})
	defer fixture_destroy(&f)

	slog.debug(&f.logger, "a")
	slog.info(&f.logger, "b")
	slog.warn(&f.logger, "c")
	slog.error(&f.logger, "d")
	slog.log(&f.logger, slog.Level(6), "e")
	testing.expect_value(t, take(&f), "level=DEBUG msg=a\nlevel=INFO msg=b\nlevel=WARN msg=c\nlevel=ERROR msg=d\nlevel=WARN+2 msg=e\n")
}

@(test)
test_text_quotes_when_needed :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "two words", "empty", "", "eq", "a=b", "quote", `say "hi"`, "plain", "café")
	testing.expect_value(t, take(&f), `level=INFO msg="two words" empty="" eq="a=b" quote="say \"hi\"" plain=café` + "\n")
}

@(test)
test_text_escapes_control_characters :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "line1\nline2", "tab", "a\tb", "bell", "\x07", "back", `a\b`)
	testing.expect_value(t, take(&f), `level=INFO msg="line1\nline2" tab="a\tb" bell="\x07" back=a\b` + "\n")
}

@(test)
test_text_escapes_invalid_utf8_and_unprintable :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", "bad", "a\xffb", "nbsp", "a b", "zw", "a​b")
	testing.expect_value(t, take(&f), `level=INFO msg=m bad="a\xffb" nbsp="a\u00a0b" zw="a\u200bb"` + "\n")
}

@(test)
test_text_scalar_values :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", "neg", -7, "big", max(u64), "yes", true, "no", false, "nothing", nil, "byte", u8(200))
	testing.expect_value(t, take(&f), "level=INFO msg=m neg=-7 big=18446744073709551615 yes=true no=false nothing=<nil> byte=200\n")
}

@(test)
test_text_float_formatting :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", "a", 1.5, "b", f64(1e21), "c", 0.1, "d", f32(0.25), "e", 3.0)
	testing.expect_value(t, take(&f), "level=INFO msg=m a=1.5 b=1e+21 c=0.1 d=0.25 e=3\n")
}

@(test)
test_text_duration_formatting :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	cases := [?]struct {
		d:    time.Duration,
		want: string,
	} {
		{0, "0s"},
		{1, "1ns"},
		{1500, "1.5µs"},
		{250 * time.Millisecond, "250ms"},
		{1500 * time.Millisecond, "1.5s"},
		{2 * time.Minute + 3 * time.Second, "2m3s"},
		{time.Hour, "1h0m0s"},
		{-90 * time.Second, "-1m30s"},
	}
	for c in cases {
		slog.info(&f.logger, "m", "d", c.d)
		got := take(&f)
		want := strings.concatenate({"level=INFO msg=m d=", c.want, "\n"}, context.temp_allocator)
		testing.expect_value(t, got, want)
	}
}

@(test)
test_text_time_value_is_utc_rfc3339 :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	ts := time.unix(1_700_000_000, 123_456_789)
	slog.info(&f.logger, "m", "at", ts)
	testing.expect_value(t, take(&f), "level=INFO msg=m at=2023-11-14T22:13:20.123Z\n")
}

@(test)
test_text_record_time_written_first :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, options = {})
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m")
	got := take(&f)
	// time=YYYY-MM-DDTHH:MM:SS.mmmZ is 29 bytes.
	testing.expect(t, strings.has_prefix(got, "time="))
	testing.expect_value(t, len(got), len("time=2026-10-29T17:13:00.123Z level=INFO msg=m\n"))
	testing.expect(t, strings.has_suffix(got, "Z level=INFO msg=m\n"))
}

@(test)
test_text_groups_use_dotted_keys :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", slog.group("req", {slog.attr("method", "GET"), slog.group("url", {slog.attr("path", "/a b")})}))
	testing.expect_value(t, take(&f), `level=INFO msg=m req.method=GET req.url.path="/a b"` + "\n")
}

@(test)
test_text_empty_group_is_omitted :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", slog.group("nothing", {}), slog.group("nested", {slog.group("deeper", {})}), "k", 1)
	testing.expect_value(t, take(&f), "level=INFO msg=m k=1\n")
}

@(test)
test_group_with_empty_key_is_inlined :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", slog.group("", {slog.attr("a", 1), slog.attr("b", 2)}))
	testing.expect_value(t, take(&f), "level=INFO msg=m a=1 b=2\n")
}

@(test)
test_empty_attr_is_ignored :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", slog.Attr{}, "k", "v")
	testing.expect_value(t, take(&f), "level=INFO msg=m k=v\n")
}

@(test)
test_text_quotes_keys_when_needed :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", "two words", 1, "", 2)
	testing.expect_value(t, take(&f), `level=INFO msg=m "two words"=1 ""=2` + "\n")
}

// ---- Arguments ----

@(test)
test_trailing_key_gets_bad_key :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", "k", 1, "dangling")
	testing.expect_value(t, take(&f), "level=INFO msg=m k=1 !BADKEY=dangling\n")
}

@(test)
test_non_string_key_gets_bad_key :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", 42, "k", "v")
	testing.expect_value(t, take(&f), "level=INFO msg=m !BADKEY=42 k=v\n")
}

@(test)
test_attrs_mix_with_pairs :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", slog.attr("a", true), "b", 2, slog.attr_u64("c", 3))
	testing.expect_value(t, take(&f), "level=INFO msg=m a=true b=2 c=3\n")
}

@(test)
test_other_types_are_formatted_with_fmt :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", "color", Color.Green, "id", User_Id(7), "pt", Point{1, 2}, "err", io.Error.Unexpected_EOF)
	testing.expect_value(t, take(&f), `level=INFO msg=m color=Green id=7 pt="Point{x = 1, y = 2}" err=Unexpected_EOF` + "\n")
}

@(test)
test_many_args_beyond_stack_buffer :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	COUNT :: slog.STACK_ATTRS + 4
	values: [COUNT]int
	args: [2 * COUNT]any
	key := "k"
	for i in 0 ..< COUNT {
		values[i] = i
		args[2 * i] = key
		args[2 * i + 1] = values[i]
	}
	err := slog.info(&f.logger, "m", ..args[:])
	testing.expect_value(t, err, nil)
	got := take(&f)
	testing.expect(t, strings.has_suffix(got, " k=18 k=19\n"))
	testing.expect_value(t, strings.count(got, " k="), slog.STACK_ATTRS + 4)
}

@(test)
test_log_attrs_skips_parsing :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	err := slog.log_attrs(&f.logger, .Warn, "m", slog.attr("a", 1), slog.attr_string("b", "x"))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, take(&f), "level=WARN msg=m a=1 b=x\n")
}

// ---- Attribute values ----

@(test)
test_attr_overloads_pick_typed_values :: proc(t: ^testing.T) {
	_, is_i64 := slog.attr("n", 3).value.(i64)
	testing.expect(t, is_i64)
	_, is_f64 := slog.attr("f", 1.5).value.(f64)
	testing.expect(t, is_f64)
	_, is_str := slog.attr("s", "x").value.(string)
	testing.expect(t, is_str)
	_, is_bool := slog.attr("b", true).value.(bool)
	testing.expect(t, is_bool)
	_, is_dur := slog.attr("d", time.Second).value.(time.Duration)
	testing.expect(t, is_dur)
}

@(test)
test_value_from_any_normalizes_types :: proc(t: ^testing.T) {
	testing.expect_value(t, slog.value_from_any(u8(9)).(u64), 9)
	testing.expect_value(t, slog.value_from_any(i16(-3)).(i64), -3)
	testing.expect_value(t, slog.value_from_any(f32(0.5)).(f64), 0.5)
	testing.expect_value(t, slog.value_from_any(cstring("c")).(string), "c")
	testing.expect_value(t, slog.value_from_any(User_Id(4)).(i64), 4)
	testing.expect(t, slog.value_from_any(nil) == nil)
	_, kept := slog.value_from_any(Color.Red).(any)
	testing.expect(t, kept)
}

@(test)
test_attr_clone_is_deep_and_leak_free :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	source := strings.clone("hello", alloc)
	original := slog.group("g", {slog.attr("s", source), slog.attr_any("c", Color.Red)})
	clone, err := slog.attr_clone(original, alloc)
	testing.expect_value(t, err, nil)
	delete(source, alloc)

	members := clone.value.([]slog.Attr)
	testing.expect_value(t, clone.key, "g")
	testing.expect_value(t, members[0].value.(string), "hello")
	testing.expect_value(t, members[1].value.(string), "Red")

	slog.attr_destroy(clone, alloc)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// ---- JSON handler ----

@(test)
test_json_basic_object :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true)
	defer fixture_destroy(&f)

	slog.warn(&f.logger, "disk low", "free_mb", 12, "ratio", 0.5, "ok", false)
	testing.expect_value(t, take(&f), `{"level":"WARN","msg":"disk low","free_mb":12,"ratio":0.5,"ok":false}` + "\n")
}

@(test)
test_json_escapes_strings :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "a\"b\\c\nd", "ctl", "\x01\t\r", "sep", "x\xe2\x80\xa8y")
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"a\"b\\c\nd","ctl":"\u0001\t\r","sep":"x` + BACKSLASH + `u2028y"}` + "\n")
}

@(test)
test_json_replaces_invalid_utf8 :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", "bad\xfe", "ok\xc3")
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m","bad�":"ok�"}` + "\n")
}

@(test)
test_json_groups_nest :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", slog.group("req", {slog.attr("method", "GET"), slog.group("empty", {}), slog.group("url", {slog.attr("path", "/")})}), "after", 1)
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m","req":{"method":"GET","url":{"path":"/"}},"after":1}` + "\n")
}

@(test)
test_json_special_floats_are_strings :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", "nan", math.nan_f64(), "pos", math.inf_f64(1), "neg", math.inf_f64(-1), "big", f64(1e21))
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m","nan":"NaN","pos":"+Inf","neg":"-Inf","big":1e+21}` + "\n")
}

@(test)
test_json_time_and_duration :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", "at", time.unix(0, 0), "took", 1500 * time.Millisecond)
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m","at":"1970-01-01T00:00:00.000Z","took":1500000000}` + "\n")
}

@(test)
test_json_nil_and_formatted_values :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true)
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", "none", nil, "color", Color.Red, "pt", Point{3, 4})
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m","none":null,"color":"Red","pt":"Point{x = 3, y = 4}"}` + "\n")
}

@(test)
test_json_record_time_is_first_field :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true, options = {})
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m")
	got := take(&f)
	testing.expect(t, strings.has_prefix(got, `{"time":"`))
	testing.expect(t, strings.has_suffix(got, `Z","level":"INFO","msg":"m"}` + "\n"))
}

@(test)
test_json_with_group_nests_bound_and_call_attrs :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true)
	defer fixture_destroy(&f)

	a, _ := slog.logger_with(&f.logger, "a", 1, allocator = f.alloc)
	defer slog.logger_destroy(&a)
	g, _ := slog.logger_with_group(&a, "g", f.alloc)
	defer slog.logger_destroy(&g)
	b, _ := slog.logger_with(&g, "b", 2, allocator = f.alloc)
	defer slog.logger_destroy(&b)

	slog.info(&b, "m", "c", 3)
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m","a":1,"g":{"b":2,"c":3}}` + "\n")
}

@(test)
test_json_empty_logger_group_is_omitted :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true)
	defer fixture_destroy(&f)

	g, _ := slog.logger_with_group(&f.logger, "g", f.alloc)
	defer slog.logger_destroy(&g)
	h, _ := slog.logger_with_group(&g, "h", f.alloc)
	defer slog.logger_destroy(&h)

	slog.info(&h, "m")
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m"}` + "\n")
	slog.info(&h, "m", "k", 1)
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m","g":{"h":{"k":1}}}` + "\n")
}

@(test)
test_json_partially_empty_logger_groups :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true)
	defer fixture_destroy(&f)

	g, _ := slog.logger_with_group(&f.logger, "g", f.alloc)
	defer slog.logger_destroy(&g)
	gb, _ := slog.logger_with(&g, "b", 2, allocator = f.alloc)
	defer slog.logger_destroy(&gb)
	h, _ := slog.logger_with_group(&gb, "h", f.alloc)
	defer slog.logger_destroy(&h)

	slog.info(&h, "m")
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m","g":{"b":2}}` + "\n")
}

// ---- Filtering ----

@(test)
test_records_below_minimum_are_dropped :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, options = {level = .Warn, omit_time = true})
	defer fixture_destroy(&f)

	slog.debug(&f.logger, "a")
	slog.info(&f.logger, "b")
	slog.log(&f.logger, slog.Level(3), "c")
	slog.warn(&f.logger, "d")
	testing.expect_value(t, take(&f), "level=WARN msg=d\n")
}

@(test)
test_default_minimum_is_info :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	testing.expect(t, !slog.enabled(&f.logger, .Debug))
	testing.expect(t, slog.enabled(&f.logger, .Info))
	testing.expect(t, slog.enabled(&f.logger, .Error))
}

@(test)
test_level_var_changes_minimum_at_run_time :: proc(t: ^testing.T) {
	lv: slog.Level_Var
	f: Fixture
	fixture_init(&f, t, options = {level_var = &lv, level = .Error, omit_time = true})
	defer fixture_destroy(&f)

	testing.expect_value(t, slog.level_var_get(&lv), slog.Level.Info)
	slog.debug(&f.logger, "hidden")
	slog.info(&f.logger, "shown")
	slog.level_var_set(&lv, .Debug)
	slog.debug(&f.logger, "now shown")
	testing.expect_value(t, take(&f), "level=INFO msg=shown\nlevel=DEBUG msg=\"now shown\"\n")
}

@(test)
test_discard_handler_drops_everything :: proc(t: ^testing.T) {
	l := slog.logger_make(slog.discard_handler())
	testing.expect(t, !slog.enabled(&l, .Error))
	testing.expect_value(t, slog.error(&l, "m", "k", 1), nil)
}

@(test)
test_nil_and_zero_loggers_are_no_ops :: proc(t: ^testing.T) {
	testing.expect_value(t, slog.info(nil, "m"), nil)
	testing.expect(t, !slog.enabled(nil, .Error))
	zero: slog.Logger
	testing.expect_value(t, slog.error(&zero, "m", "k", 1), nil)
	slog.logger_destroy(&zero)
}

@(test)
test_custom_handler_receives_record :: proc(t: ^testing.T) {
	Seen :: struct {
		level:   slog.Level,
		message: string,
		count:   int,
		line:    i32,
	}
	seen: Seen
	h := slog.Handler {
		handle = proc(data: rawptr, r: ^slog.Record) -> slog.Error {
			s := (^Seen)(data)
			s.level, s.message, s.count, s.line = r.level, r.message, len(r.attrs), r.location.line
			return nil
		},
		data = &seen,
	}
	l := slog.logger_make(h)
	testing.expect(t, slog.enabled(&l, .Debug))
	here := #location()
	slog.debug(&l, "custom", "a", 1, "b", 2, loc = here)
	testing.expect_value(t, seen.level, slog.Level.Debug)
	testing.expect_value(t, seen.message, "custom")
	testing.expect_value(t, seen.count, 2)
	testing.expect_value(t, seen.line, here.line)
}

// ---- Handler options ----

@(test)
test_add_source_writes_file_and_line :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, options = {add_source = true, omit_time = true})
	defer fixture_destroy(&f)

	loc := #location()
	slog.info(&f.logger, "m", loc = loc)
	got := take(&f)
	want := strings.concatenate({"level=INFO source=", loc.file_path, ":"}, context.temp_allocator)
	testing.expectf(t, strings.has_prefix(got, want), "got %q", got)
	testing.expect(t, strings.has_suffix(got, " msg=m\n"))
}

@(test)
test_replace_attr_renames_and_drops :: proc(t: ^testing.T) {
	replace :: proc(groups: []string, a: slog.Attr, _: rawptr) -> (slog.Attr, bool) {
		switch a.key {
		case slog.TIME_KEY, "secret":
			return {}, false
		case slog.MESSAGE_KEY:
			return slog.Attr{"message", a.value}, true
		}
		return a, true
	}
	f: Fixture
	fixture_init(&f, t, options = {replace_attr = replace})
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", "secret", "hunter2", "user", "ana")
	testing.expect_value(t, take(&f), "level=INFO message=m user=ana\n")
}

@(test)
test_replace_attr_sees_groups :: proc(t: ^testing.T) {
	replace :: proc(groups: []string, a: slog.Attr, data: rawptr) -> (slog.Attr, bool) {
		if a.key == "k" {
			b := (^strings.Builder)(data)
			strings.write_string(b, strings.join(groups, "/", context.temp_allocator))
			strings.write_byte(b, ';')
		}
		return a, true
	}
	paths := strings.builder_make()
	defer strings.builder_destroy(&paths)
	f: Fixture
	fixture_init(&f, t, json = true, options = {omit_time = true, replace_attr = replace, replace_attr_data = &paths})
	defer fixture_destroy(&f)

	g, _ := slog.logger_with_group(&f.logger, "outer", f.alloc)
	defer slog.logger_destroy(&g)
	slog.info(&g, "m", "k", 1, slog.group("inner", {slog.attr("k", 2)}))
	testing.expect_value(t, strings.to_string(paths), "outer;outer/inner;")
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m","outer":{"k":1,"inner":{"k":2}}}` + "\n")
}

// ---- Child loggers ----

@(test)
test_logger_with_binds_attrs :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	child, err := slog.logger_with(&f.logger, "service", "api", "pid", 42, allocator = f.alloc)
	testing.expect_value(t, err, nil)
	defer slog.logger_destroy(&child)

	slog.info(&child, "up", "port", 80)
	slog.info(&f.logger, "parent")
	testing.expect_value(t, take(&f), "level=INFO msg=up service=api pid=42 port=80\nlevel=INFO msg=parent\n")
}

@(test)
test_logger_with_copies_borrowed_strings :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	key := strings.clone("user", f.alloc)
	value := strings.clone("ana", f.alloc)
	child, _ := slog.logger_with(&f.logger, key, value, slog.group("g", {slog.attr("v", value)}), allocator = f.alloc)
	defer slog.logger_destroy(&child)
	delete(key, f.alloc)
	delete(value, f.alloc)

	slog.info(&child, "m")
	testing.expect_value(t, take(&f), "level=INFO msg=m user=ana g.v=ana\n")
}

@(test)
test_logger_with_formats_any_at_bind_time :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	pt := Point{1, 2}
	child, _ := slog.logger_with(&f.logger, "pt", pt, "color", Color.Green, allocator = f.alloc)
	defer slog.logger_destroy(&child)
	pt = Point{9, 9}

	slog.info(&child, "m")
	testing.expect_value(t, take(&f), `level=INFO msg=m pt="Point{x = 1, y = 2}" color=Green` + "\n")
}

@(test)
test_child_outlives_destroyed_parent :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	parent, _ := slog.logger_with(&f.logger, "a", 1, allocator = f.alloc)
	child, _ := slog.logger_with(&parent, "b", 2, allocator = f.alloc)
	defer slog.logger_destroy(&child)
	slog.logger_destroy(&parent)

	slog.info(&child, "m")
	testing.expect_value(t, take(&f), "level=INFO msg=m a=1 b=2\n")
}

@(test)
test_with_group_then_with_matches_go_semantics :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	a, _ := slog.logger_with(&f.logger, "a", 1, allocator = f.alloc)
	defer slog.logger_destroy(&a)
	g, _ := slog.logger_with_group(&a, "g", f.alloc)
	defer slog.logger_destroy(&g)
	b, _ := slog.logger_with(&g, "b", 2, allocator = f.alloc)
	defer slog.logger_destroy(&b)

	slog.info(&b, "m", "c", 3)
	testing.expect_value(t, take(&f), "level=INFO msg=m a=1 g.b=2 g.c=3\n")
	slog.info(&a, "m", "c", 3)
	testing.expect_value(t, take(&f), "level=INFO msg=m a=1 c=3\n")
}

@(test)
test_with_group_empty_name_adds_no_group :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	g, err := slog.logger_with_group(&f.logger, "", f.alloc)
	testing.expect_value(t, err, nil)
	defer slog.logger_destroy(&g)
	slog.info(&g, "m", "k", 1)
	testing.expect_value(t, take(&f), "level=INFO msg=m k=1\n")
}

@(test)
test_nested_with_group_chain :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	x, _ := slog.logger_with_group(&f.logger, "x", f.alloc)
	defer slog.logger_destroy(&x)
	y, _ := slog.logger_with_group(&x, "y", f.alloc)
	defer slog.logger_destroy(&y)
	slog.info(&y, "m", "k", 1, slog.group("z", {slog.attr("w", 2)}))
	testing.expect_value(t, take(&f), "level=INFO msg=m x.y.k=1 x.y.z.w=2\n")
}

@(test)
test_logger_with_attrs_binds_typed_attrs :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	child, err := slog.logger_with_attrs(&f.logger, slog.attr("a", 1.25), slog.attr_time("t", time.unix(0, 0)), allocator = f.alloc)
	testing.expect_value(t, err, nil)
	defer slog.logger_destroy(&child)
	slog.info(&child, "m")
	testing.expect_value(t, take(&f), "level=INFO msg=m a=1.25 t=1970-01-01T00:00:00.000Z\n")
}

@(test)
test_logger_with_reports_allocator_failure_without_leaks :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	parent, _ := slog.logger_with(&f.logger, "a", "x", slog.group("g", {slog.attr("b", "y")}), allocator = f.alloc)
	defer slog.logger_destroy(&parent)

	// Fail at every allocation step in turn; each attempt must clean up.
	failures := 0
	for budget in 0 ..< 32 {
		fa := Failing_Allocator{f.alloc, budget}
		child, err := slog.logger_with(&parent, "c", "z", Color.Red, allocator = failing_allocator(&fa))
		if err != nil {
			testing.expect_value(t, err, slog.Error(runtime.Allocator_Error.Out_Of_Memory))
			failures += 1
			continue
		}
		slog.info(&child, "m")
		testing.expect_value(t, take(&f), "level=INFO msg=m a=x g.b=y c=z !BADKEY=Red\n")
		slog.logger_destroy(&child)
		break
	}
	testing.expect(t, failures > 3)
}

@(test)
test_logger_with_group_reports_allocator_failure :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	for budget in 0 ..< 2 {
		fa := Failing_Allocator{f.alloc, budget}
		_, err := slog.logger_with_group(&f.logger, "g", failing_allocator(&fa))
		testing.expect_value(t, err, slog.Error(runtime.Allocator_Error.Out_Of_Memory))
	}
}

// ---- Writer errors ----

@(test)
test_writer_error_is_returned :: proc(t: ^testing.T) {
	w := Broken_Writer{.Closed}
	h: slog.Text_Handler
	slog.text_handler_init(&h, broken_writer(&w))
	defer slog.text_handler_destroy(&h)
	l := slog.logger_make(slog.text_handler(&h))

	testing.expect_value(t, slog.info(&l, "m"), slog.Error(io.Error.Closed))
}

@(test)
test_short_write_is_reported :: proc(t: ^testing.T) {
	w := Broken_Writer{}
	h: slog.JSON_Handler
	slog.json_handler_init(&h, broken_writer(&w))
	defer slog.json_handler_destroy(&h)
	l := slog.logger_make(slog.json_handler(&h))

	testing.expect_value(t, slog.info(&l, "m"), slog.Error(io.Error.Short_Write))
}

@(test)
test_disabled_level_skips_writer :: proc(t: ^testing.T) {
	w := Broken_Writer{.Closed}
	h: slog.Text_Handler
	slog.text_handler_init(&h, broken_writer(&w))
	defer slog.text_handler_destroy(&h)
	l := slog.logger_make(slog.text_handler(&h))

	testing.expect_value(t, slog.debug(&l, "m"), nil)
}

// ---- runtime.Logger adapter ----

@(test)
test_runtime_logger_routes_core_log :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, options = {level = .Debug, omit_time = true})
	defer fixture_destroy(&f)

	child, _ := slog.logger_with(&f.logger, "component", "db", allocator = f.alloc)
	defer slog.logger_destroy(&child)

	context.logger = slog.runtime_logger(&child)
	log.infof("connected to %s", "primary")
	log.debug("pool", 4)
	log.warn("slow")
	log.error("down")
	testing.expect_value(t, take(&f), "level=INFO msg=\"connected to primary\" component=db\nlevel=DEBUG msg=\"pool 4\" component=db\nlevel=WARN msg=slow component=db\nlevel=ERROR msg=down component=db\n")
}

@(test)
test_runtime_logger_lowest_level_filters :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, options = {level = .Debug, omit_time = true})
	defer fixture_destroy(&f)

	context.logger = slog.runtime_logger(&f.logger, .Warning)
	log.info("hidden")
	log.warn("shown")
	testing.expect_value(t, take(&f), "level=WARN msg=shown\n")
}

@(test)
test_runtime_logger_passes_location :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, options = {add_source = true, omit_time = true})
	defer fixture_destroy(&f)

	context.logger = slog.runtime_logger(&f.logger)
	loc := #location()
	log.info("here", location = loc)
	got := take(&f)
	testing.expectf(t, strings.contains(got, loc.file_path), "got %q", got)
}

@(test)
test_level_from_runtime_maps_every_level :: proc(t: ^testing.T) {
	testing.expect_value(t, slog.level_from_runtime(.Debug), slog.Level.Debug)
	testing.expect_value(t, slog.level_from_runtime(.Info), slog.Level.Info)
	testing.expect_value(t, slog.level_from_runtime(.Warning), slog.Level.Warn)
	testing.expect_value(t, slog.level_from_runtime(.Error), slog.Level.Error)
	buf: [slog.LEVEL_STRING_SIZE]byte
	testing.expect_value(t, slog.level_string(slog.level_from_runtime(.Fatal), buf[:]), "ERROR+4")
}

@(test)
test_level_to_runtime_rounds_down :: proc(t: ^testing.T) {
	testing.expect_value(t, slog.level_to_runtime(.Debug), runtime.Logger_Level.Debug)
	testing.expect_value(t, slog.level_to_runtime(slog.Level(2)), runtime.Logger_Level.Info)
	testing.expect_value(t, slog.level_to_runtime(.Warn), runtime.Logger_Level.Warning)
	testing.expect_value(t, slog.level_to_runtime(slog.Level(11)), runtime.Logger_Level.Error)
	testing.expect_value(t, slog.level_to_runtime(slog.Level(12)), runtime.Logger_Level.Fatal)
}

@(test)
test_runtime_logger_with_nil_logger_is_safe :: proc(t: ^testing.T) {
	context.logger = slog.runtime_logger(nil)
	log.info("nowhere")
	testing.expect(t, true)
}

// ---- Concurrency ----

@(test)
test_concurrent_logging_keeps_lines_whole :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true)
	defer fixture_destroy(&f)

	THREADS :: 4
	LINES :: 200
	Worker :: struct {
		logger: ^slog.Logger,
		id:     int,
	}
	work := proc(data: rawptr) {
		w := (^Worker)(data)
		for i in 0 ..< LINES {
			slog.info(w.logger, "tick", "worker", w.id, "i", i, "pad", "some text to make lines longer")
		}
	}
	workers: [THREADS]Worker
	threads: [THREADS]^thread.Thread
	for i in 0 ..< THREADS {
		workers[i] = {&f.logger, i}
		threads[i] = thread.create_and_start_with_data(&workers[i], work)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	out := strings.to_string(f.out)
	lines := 0
	for line in strings.split_lines_iterator(&out) {
		testing.expect(t, strings.has_prefix(line, `{"level":"INFO","msg":"tick","worker":`))
		testing.expect(t, strings.has_suffix(line, `"pad":"some text to make lines longer"}`))
		lines += 1
	}
	testing.expect_value(t, lines, THREADS * LINES)
}

// ---- Regressions ----

@(test)
test_json_escapes_line_and_paragraph_separators :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true)
	defer fixture_destroy(&f)

	// U+2028 and U+2029 are valid in JSON but end a line in JavaScript, so Go escapes them.
	slog.info(&f.logger, "a\xe2\x80\xa8b", "k", "c\xe2\x80\xa9d")
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"a` + BACKSLASH + `u2028b","k":"c` + BACKSLASH + `u2029d"}` + "\n")
}

@(test)
test_text_positive_infinity_keeps_sign :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t)
	defer fixture_destroy(&f)

	// Go's TextHandler uses strconv.FormatFloat, which writes +Inf.
	slog.info(&f.logger, "m", "pos", math.inf_f64(1), "neg", math.inf_f64(-1), "nan", math.nan_f64(), "x", 2.5)
	testing.expect_value(t, take(&f), "level=INFO msg=m pos=+Inf neg=-Inf nan=NaN x=2.5\n")
}

// BACKSLASH spells escapes like u2028 without writing them literally.
BACKSLASH :: "\x5c"

drop_secret :: proc(groups: []string, a: slog.Attr, _: rawptr) -> (slog.Attr, bool) {
	return a, a.key != "secret"
}

@(test)
test_json_omits_group_emptied_by_replace_attr :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true, options = {omit_time = true, replace_attr = drop_secret})
	defer fixture_destroy(&f)

	slog.info(&f.logger, "m", slog.group("auth", {slog.attr("secret", "x")}), "after", 1)
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m","after":1}` + "\n")
	slog.info(&f.logger, "m", slog.group("outer", {slog.group("auth", {slog.attr("secret", "x")})}))
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m"}` + "\n")
}

@(test)
test_json_omits_logger_group_emptied_by_replace_attr :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, t, json = true, options = {omit_time = true, replace_attr = drop_secret})
	defer fixture_destroy(&f)

	g, err := slog.logger_with_group(&f.logger, "g", f.alloc)
	testing.expect_value(t, err, nil)
	defer slog.logger_destroy(&g)
	slog.info(&g, "m", "secret", "x")
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m"}` + "\n")

	// A bound attribute that is dropped leaves the inner group in place.
	b, berr := slog.logger_with(&g, "secret", "y", allocator = f.alloc)
	testing.expect_value(t, berr, nil)
	defer slog.logger_destroy(&b)
	h, herr := slog.logger_with_group(&b, "h", f.alloc)
	testing.expect_value(t, herr, nil)
	defer slog.logger_destroy(&h)
	slog.info(&h, "m", "c", 3)
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m","g":{"h":{"c":3}}}` + "\n")
	slog.info(&h, "m", "secret", "z")
	testing.expect_value(t, take(&f), `{"level":"INFO","msg":"m"}` + "\n")
}

