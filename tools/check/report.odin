package main

import "base:runtime"
import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:terminal"
import "core:sys/posix"
import "core:time"

// Consume state changes from Odin's runner while it executes tests in parallel.
report_tests :: proc(args: []string) -> (code: int, err: os.Error) {
	command: [dynamic]string
	append(&command, ..args)
	for setting in ([]string{"ODIN_TEST_LOG_STATE_CHANGES=true", "ODIN_TEST_FANCY=false", "ODIN_TEST_SHORT_LOGS=true"}) {
		key, _, _ := strings.partition(setting, "=")
		prefix := fmt.tprintf("-define:%s=", key)
		supplied := false
		for arg in args {
			if strings.has_prefix(arg, prefix) {
				supplied = true
				break
			}
		}
		if !supplied {
			append(&command, fmt.tprintf("-define:%s", setting))
		}
	}

	live := terminal.is_terminal(os.stderr) && env("TERM") != "dumb"
	read_end, write_end := os.pipe() or_return
	defer os.close(read_end)
	stdout := write_end if live && terminal.is_terminal(os.stdout) else os.stdout
	child, start_err := os.process_start({command = command[:], stdout = stdout, stderr = write_end})
	os.close(write_end)
	if start_err != nil {
		return 1, start_err
	}
	progress := Progress{live = live, color = live && env("NO_COLOR") == ""}
	report_path := env("KAKUNOU_MATCHED_SELECTORS")
	if report_path != "" {
		progress.selectors = test_selection(args).names
	}
	progress.reported_total = -1
	progress.unknown_queue = env("KAKUNOU_QUEUE_UNKNOWN") == "1"
	progress.upcoming = env("KAKUNOU_UPCOMING_SUITES")
	later := env("KAKUNOU_LATER_TESTS")
	if later != "" {
		progress.later = strings.split(later, "\n")
	}
	names := env("KAKUNOU_SUITE_TESTS")
	for name in strings.split_iterator(&names, "\n") {
		if name != "" {
			append(&progress.queued, name)
		}
	}
	defer clear_status(&progress)
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_reader(read_end))
	defer bufio.reader_destroy(&reader)
	fd := posix.pollfd{fd = posix.FD(os.fd(read_end)), events = {.IN}}
	printed_idle := false
	for {
		if len(progress.active) > 0 && bufio.reader_buffered(&reader) == 0 {
			if posix.poll(&fd, 1, 1000) == 0 {
				if live || !printed_idle {
					clear_status(&progress)
					show_status(&progress, snapshot = !live)
					printed_idle = true
				}
				continue
			}
		}
		printed_idle = false
		line, read_err := bufio.reader_read_string(&reader, '\n', runtime.heap_allocator())
		if len(line) > 0 {
			report_line(line, &progress)
		}
		delete(line, runtime.heap_allocator())
		if read_err != nil {
			if read_err != .EOF {
				err = read_err
			}
			break
		}
	}
	state, wait_err := os.process_wait(child)
	if wait_err != nil {
		return 1, wait_err
	}
	if report_path != "" && state.success && err == nil {
		// With state logs disabled, Odin still reports its completed count and emits
		// one diagnostic per unmatched selector. Each remaining selector runs once.
		matches: [dynamic]string
		for name in progress.selectors {
			if !progress.missing[name] {
				append(&matches, name)
			}
		}
		if progress.reported_total != len(matches) {
			clear(&matches)
		}
		os.write_entire_file(report_path, strings.join(matches[:], "\n")) or_return
	}
	return state.exit_code, err
}

Progress :: struct {
	live, color, unknown_queue: bool,
	selectors: [dynamic]string,
	missing: map[string]bool,
	reported_total: int,
	visible_rows, finished: int,
	active: [dynamic]Running_Test,
	queued: [dynamic]string,
	upcoming: string,
	later: []string,
}

Running_Test :: struct {
	name: string,
	start: time.Tick,
}

clear_status :: proc(p: ^Progress) {
	if p.visible_rows == 0 {
		return
	}
	if p.visible_rows > 1 {
		fmt.eprintf("\x1b[%dA", p.visible_rows-1)
	}
	fmt.eprint("\r\x1b[J")
	p.visible_rows = 0
}

show_status :: proc(p: ^Progress, snapshot := false) {
	if (!p.live && !snapshot) || len(p.active) == 0 {
		return
	}
	width, height := 80, 24
	when #defined(terminal.get_terminal_size) {
		if w, h, ok := terminal.get_terminal_size(); ok {
			width, height = w, h
		}
	}
	if snapshot {
		width, height = max(int), max(int)
	}
	row :: proc(text: string, width: int, color: string) {
		clipped := text[:min(len(text), max(0, width-1))]
		fmt.eprintf("%s%s%s", color, clipped, "\x1b[0m" if color != "" else "")
	}
	summary := fmt.tprintf("%d done | %d running | %d queued in suite", p.finished, len(p.active), len(p.queued))
	if p.unknown_queue {
		summary = fmt.tprintf("%d done | %d running | queue unknown", p.finished, len(p.active))
	}
	row(summary, width, "\x1b[36m" if p.color else "")
	rows := 1
	if p.upcoming != "" && height > 3 {
		fmt.eprint("\n")
		row(fmt.tprintf("Next: %s", p.upcoming), width, "")
		rows += 1
	}
	current := len(p.active) + len(p.queued)
	total := current + len(p.later)
	available := max(0, height-1-rows)
	for i in 0..<min(total, available) {
		fmt.eprint("\n")
		rows += 1
		if i == available-1 && total > available {
			row(fmt.tprintf("  +%d more", total-i), width, "")
		} else if i < len(p.active) {
			test := p.active[i]
			seconds := int(time.tick_since(test.start)/time.Second)
			row(fmt.tprintf("  RUN   %ds  %s", seconds, test.name), width, "\x1b[36m" if p.color else "")
		} else if i < current {
			row(fmt.tprintf("  WAIT  %s", p.queued[i-len(p.active)]), width, "")
		} else {
			row(fmt.tprintf("  WAIT  %s", p.later[i-current]), width, "")
		}
	}
	if snapshot {
		fmt.eprintln()
	} else {
		p.visible_rows = rows
	}
}

report_line :: proc(line: string, p: ^Progress) {
	if len(p.selectors) > 0 {
		text := strings.trim_right(line, "\r\n")
		if strings.has_prefix(text, "No test found for the name: ") {
			for name in p.selectors {
				if text == fmt.tprintf("No test found for the name: %q", name) {
					p.missing[name] = true
					return
				}
			}
		} else if strings.has_prefix(text, "Finished ") {
			count, _, rest := strings.partition(strings.trim_prefix(text, "Finished "), " ")
			if strings.has_prefix(rest, "test in ") || strings.has_prefix(rest, "tests in ") {
				if n, ok := strconv.parse_int(count); ok {
					p.reported_total = n
				}
			}
		}
	}
	info_prefix :: "[INFO ] --- "
	message := strings.trim_right(strings.trim_prefix(line, info_prefix), "\r\n")
	if strings.has_prefix(line, info_prefix) {
		for prefix in ([]string{"Starting test runner ", "The random seed sent to every test is: ",
		                        "Memory tracking is enabled.", "< Final Mem/ Total Mem>"}) {
			if strings.has_prefix(message, prefix) {
				return
			}
		}
		if strings.has_prefix(message, "Test #") {
			_, _, event := strings.partition(message[len("Test #"):], " ")
			name, _, state := strings.partition(event, " changed state to ")
			switch state {
			case "Running.":
				for pending, i in p.queued {
					if pending == name {
						ordered_remove(&p.queued, i)
						break
					}
				}
				append(&p.active, Running_Test{strings.clone(name), time.tick_now()})
				clear_status(p)
				show_status(p)
				return
			case "Successful.", "Failed.":
				clear_status(p)
				was_running := false
				for active, i in p.active {
					if active.name == name {
						ordered_remove(&p.active, i)
						was_running = true
						break
					}
				}
				if !was_running {
					return
				}
				p.finished += 1
				label := "PASS" if state == "Successful." else "FAIL"
				tint := "\x1b[32m" if state == "Successful." else "\x1b[31m"
				fmt.eprintf("  %s%s%s  %s  (%d done)\n", tint if p.color else "", label,
				            "\x1b[0m" if p.color else "", name, p.finished)
				show_status(p)
				return
			}
		}
	}
	clear_status(p)
	fmt.eprint(line)
	if strings.has_suffix(line, "\n") {
		show_status(p)
	}
}
