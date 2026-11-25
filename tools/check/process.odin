package main

import "base:intrinsics"
import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

exec :: proc(args: []string) {
	argv := make([]cstring, len(args)+1)
	for arg, i in args {
		argv[i] = strings.clone_to_cstring(arg)
	}
	posix.execvp(argv[0], raw_data(argv))
	fmt.eprintln("kakunou: cannot execute", args[0], posix.get_errno())
	os.exit(1)
}

compiler_wrapper :: proc(args: []string) {
	root := env("KAKUNOU_STAGED_ROOT")
	if len(args) == 1 && args[0] == "root" {
		fmt.println(root)
		return
	}
	command: [dynamic]string
	append(&command, env("KAKUNOU_REAL_ODIN"))
	for arg in args {
		if !strings.has_prefix(arg, "-collection:shared=") {
			append(&command, arg)
		}
	}
	if len(args) > 0 && args[0] != "version" {
		append(&command, fmt.tprintf("-collection:shared=%s", path(root, "shared")))
	}
	exec(command[:])
}

// Give the compiler and all processes launched by its tests one process group.
start_suite_child :: proc(args: []string) {
	if len(args) == 0 || posix.setpgid(0, 0) == .FAIL {
		os.exit(1)
	}
	exec(args)
}

interrupted: c.int

interrupt :: proc "c" (signal: c.int) {
	intrinsics.atomic_store(&interrupted, signal)
}

run_suite :: proc(dir: string, args: []string) -> os.Error {
	signals := [?]posix.Signal{.SIGINT, .SIGTERM, .SIGHUP}
	previous: [len(signals)]proc "c" (c.int)
	for signal, i in signals {
		previous[i] = libc.signal(c.int(signal), interrupt)
	}
	defer {
		for signal, i in signals {
			libc.signal(c.int(signal), previous[i])
		}
	}
	child := os.process_start({working_dir = dir, command = args, stdout = os.stdout, stderr = os.stderr}) or_return
	pid := posix.pid_t(child.pid)
	start := time.tick_now()
	status: c.int
	for {
		if intrinsics.atomic_load(&interrupted) != 0 || time.tick_since(start) >= 5*time.Minute {
			fmt.eprintln("kakunou: suite interrupted or timed out", args[4])
			posix.killpg(pid, .SIGTERM)
			// The child may still be starting its process group.
			posix.kill(pid, .SIGTERM)
			time.sleep(5*time.Second)
			posix.killpg(pid, .SIGKILL)
			posix.waitpid(pid, &status, {})
			return .Invalid_Command
		}
		waited := posix.waitpid(pid, &status, {.NOHANG})
		if waited == pid {
			if !posix.WIFEXITED(status) || posix.WEXITSTATUS(status) != 0 {
				return fail("suite failed", args[4])
			}
			return nil
		}
		if waited < 0 && posix.get_errno() != .EINTR {
			return fail("cannot wait for suite", args[4])
		}
		time.sleep(50*time.Millisecond)
	}
}
