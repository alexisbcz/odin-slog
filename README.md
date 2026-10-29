# slog

[![CI](https://github.com/alexisbcz/odin-slog/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-slog/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

Structured, leveled logging for Odin in the style of Go's `log/slog`: key-value attributes, groups, child loggers, text and JSON output to any `io.Writer`, and an adapter so that `context.logger` and `core:log` write structured records too.

## Install

The repository root is the package, so you can vendor it in two ways.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/odin-slog libs/slog
```

```odin
import "libs/slog"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/odin-slog ~/odin-shared/slog
odin build . -collection:shared=$HOME/odin-shared
```

```odin
import "shared:slog"
```

Odin names an import after its directory, and `odin-slog` isn't a valid identifier. Clone into a directory called `slog`, as above, or name the import yourself: `import slog "shared:odin-slog"`.

## Quick start

```odin
package main

import "core:os"
import "shared:slog"

main :: proc() {
	text: slog.Text_Handler
	slog.text_handler_init(&text, os.to_writer(os.stdout), {level = .Debug})
	defer slog.text_handler_destroy(&text)

	logger := slog.logger_make(slog.text_handler(&text))
	slog.info(&logger, "server started", "port", 8080, "tls", false)
}
```

```text
time=2026-10-29T16:24:25.211Z level=INFO msg="server started" port=8080 tls=false
```

Arguments after the message are key-value pairs. You can also pass `Attr` values built with `slog.attr`, `slog.attr_u64`, `slog.attr_time` and friends. A key with no value, or a value with no key, shows up under the key `!BADKEY` instead of disappearing.

### Child loggers and groups

`logger_with` binds attributes to a new logger. `logger_with_group` nests every later attribute under a group name. Children own copies of everything they bind, so destroy each one with `logger_destroy`.

```odin
request, err := slog.logger_with(&logger, "request_id", "7f3a", "method", "GET")
if err != nil {
	return
}
defer slog.logger_destroy(&request)
slog.warn(&request, "slow response", "elapsed", 2300 * time.Millisecond)
```

```text
time=2026-10-29T16:24:25.211Z level=WARN msg="slow response" request_id=7f3a method=GET elapsed=2.3s
```

Pass a group's members as a slice literal. It lives until the end of the enclosing block, so `group` never allocates:

```odin
slog.info(&jlog, "request done", slog.group("http", {slog.attr("path", "/users"), slog.attr("status", 200)}))
```

```json
{"level":"INFO","msg":"request done","http":{"path":"/users","status":200}}
```

### Use with core:log

```odin
context.logger = slog.runtime_logger(&jlog)
log.infof("cache warmed with %d entries", 128)
```

```json
{"level":"INFO","msg":"cache warmed with 128 entries"}
```

## API overview

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `logger_make(handler, allocator)` | Make a root `Logger` | No | Not needed |
| `logger_with(l, ..args, allocator)` | Child logger with bound attributes | Yes | `logger_destroy` |
| `logger_with_attrs(l, ..attrs, allocator)` | Same, from `Attr` values | Yes | `logger_destroy` |
| `logger_with_group(l, name, allocator)` | Child logger that nests under a group | Yes | `logger_destroy` |
| `debug`, `info`, `warn`, `error`, `log` | Emit a record; return the writer's error | Only past 16 arguments, freed before returning | Not needed |
| `log_attrs(l, level, msg, ..attrs)` | Emit a record from `Attr` values | No | Not needed |
| `enabled(l, level)` | Check a level before doing expensive work | No | Not needed |
| `text_handler_init`, `json_handler_init` | Prepare a handler that writes to an `io.Writer` | Its line buffer | `text_handler_destroy`, `json_handler_destroy` |
| `text_handler`, `json_handler`, `discard_handler` | Get the `Handler` for `logger_make` | No | Not needed |
| `Handler_Options` | Minimum level, `Level_Var`, source, time and `replace_attr` | No | Not needed |
| `attr`, `attr_*`, `group` | Build attributes; they borrow their strings | No | Not needed |
| `attr_clone` | Deep-copy an `Attr` | Yes | `attr_destroy` |
| `level_string`, `level_parse` | Convert a `Level` to and from text such as `INFO+2` | No | Not needed |
| `runtime_logger(l, lowest_level)` | Adapt a `Logger` to `runtime.Logger` | No | Not needed |
| `Error` | Union of `Level_Error`, `io.Error` and `runtime.Allocator_Error` | No | Not needed |

Write your own back end by filling in a `Handler` with a `handle` procedure that receives a `^Record`.

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic
```

## Design notes

- Every allocating procedure takes `allocator := context.allocator` and says who owns the result. Log calls with up to 16 arguments don't allocate, apart from the handler's reusable line buffer.
- Fallible procedures return `Error`. A failed write comes back from the log call as an `io.Error`. The library never panics on bad input.
- The text format and the JSON format follow Go's `TextHandler` and `JSONHandler`. Times are UTC with millisecond precision. JSON durations are integer nanoseconds.
- A `Logger` is read-only once made, and the built-in handlers serialize writes with a mutex, so several threads may share one logger. Each record reaches the writer in a single write call.
- The package keeps no global mutable state. Change the level at run time with a `Level_Var`, which uses atomic loads and stores.

## Testing

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
vale sync && vale *.md
```

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Commits follow Conventional Commits, and every change that users can see gets a line in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
