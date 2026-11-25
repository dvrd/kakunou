package test_support

import "core:log"
import "core:strings"

Test_Log :: struct {
	warning_count:  int,
	warning:        string,
	warning_buffer: [2048]u8,
	error_count:    int,
	contains:       string,
	matched:        bool,
}

test_capture_log :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	capture := cast(^Test_Log)data
	if level == .Warning {
		capture.warning_count += 1
		length := copy(capture.warning_buffer[:], transmute([]u8)text)
		capture.warning = string(capture.warning_buffer[:length])
	}

	if level == .Error {
		capture.error_count += 1
		capture.matched = capture.matched || strings.contains(text, capture.contains)
	}
}
