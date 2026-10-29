// Example basic shows text and JSON output, child loggers, groups and the core:log adapter.
// Run it with `odin run examples/basic`.
package main

import slog "../.."
import "core:log"
import "core:os"
import "core:time"

main :: proc() {
	stdout := os.to_writer(os.stdout)

	// A text handler writes key=value lines. Debug records are enabled here.
	text: slog.Text_Handler
	slog.text_handler_init(&text, stdout, {level = .Debug})
	defer slog.text_handler_destroy(&text)

	logger := slog.logger_make(slog.text_handler(&text))
	slog.info(&logger, "server started", "port", 8080, "tls", false)
	slog.debug(&logger, "config loaded", "path", "/etc/app.toml", "took", 1500 * time.Microsecond)

	// A child logger carries bound attributes into every record.
	request, err := slog.logger_with(&logger, "request_id", "7f3a", "method", "GET")
	if err != nil {
		slog.error(&logger, "could not bind attributes", "err", err)
		return
	}
	defer slog.logger_destroy(&request)
	slog.warn(&request, "slow response", "elapsed", 2300 * time.Millisecond)

	// The JSON handler writes one object per line. Groups become nested objects.
	json: slog.JSON_Handler
	slog.json_handler_init(&json, stdout, {omit_time = true})
	defer slog.json_handler_destroy(&json)

	jlog := slog.logger_make(slog.json_handler(&json))
	slog.info(&jlog, "request done", slog.group("http", {slog.attr("path", "/users"), slog.attr("status", 200)}))

	// The adapter lets core:log, and any library that uses context.logger, log through slog.
	context.logger = slog.runtime_logger(&jlog)
	log.infof("cache warmed with %d entries", 128)
}
