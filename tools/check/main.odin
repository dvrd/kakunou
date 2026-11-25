package main

import "core:fmt"
import "core:os"
import "core:strings"

Config :: struct {
	mode, compiler, shared, owner, out: string,
	internal: bool,
	flags: [dynamic]string,
}

env :: proc(key: string, fallback := "") -> string {
	value := os.get_env(key, context.allocator)
	return value if value != "" else fallback
}

path :: proc(parts: ..string) -> string {
	return os.join_path(parts, context.allocator) or_else panic("cannot join paths")
}

fail :: proc(message: string, detail := "") -> os.Error {
	fmt.eprintln("kakunou:", message, detail)
	return .Invalid_Command
}

output :: proc(dir: string, args: ..string) -> (string, os.Error) {
	state, data, errors, err := os.process_exec({working_dir = dir, command = args}, context.allocator)
	fmt.eprint(string(errors))
	if err != nil {
		return "", err
	}
	if state.exit_code != 0 {
		return "", fail("command failed", strings.join(args, " "))
	}
	return strings.trim_right(string(data), "\r\n"), nil
}

run :: proc(args: ..string) -> os.Error {
	child := os.process_start({command = args, stdout = os.stdout, stderr = os.stderr}) or_return
	state := os.process_wait(child) or_return
	if state.exit_code != 0 {
		return fail("command failed", strings.join(args, " "))
	}
	return nil
}

main :: proc() {
	context.allocator = context.temp_allocator
	args := os.args[1:]
	if os.base(os.args[0]) == "odin" && env("KAKUNOU_REAL_ODIN") != "" {
		compiler_wrapper(args)
		return
	}
	if len(args) > 0 && args[0] == "--suite-child" {
		start_suite_child(args[1:])
		return
	}
	if err := check(args); err != nil {
		fmt.eprintln("kakunou:", os.error_string(err))
		os.exit(1)
	}
}

check :: proc(args: []string) -> os.Error {
	if len(args) == 0 || (args[0] != "build" && args[0] != "test") {
		return fail("expected build or test")
	}
	internal := env("KAKUNOU_INTERNAL")
	cfg := Config{
		mode = args[0],
		compiler = env("KAKUNOU_COMPILER", env("ODIN", "odin")),
		shared = env("KAKUNOU_SHARED", env("WEBTOOLS_SHARED", path(env("HOME"), "dev/oss/Odin/shared"))),
		owner = env("KAKUNOU_PACKAGE", "all"),
		internal = internal == "1" || internal == "true",
		out = env("KAKUNOU_OUT", env("KAKUNOU_CHECK_DIR", path(env("TMPDIR", "/tmp"), "kakunou-check"))),
	}
	rest := args[1:]
	options: for len(rest) > 0 {
		option := rest[0]
		switch option {
		case "--help", "-h":
			fmt.println("Usage: task build|test [PACKAGE=owner] [INTERNAL=1] [ODIN=path] [SHARED=dir] -- [odin flags]")
			return nil
		case "--internal-only":
			cfg.internal = true
		case "--odin", "--shared", "--package":
			if len(rest) < 2 {
				return fail("missing value for", option)
			}
			switch option {
			case "--odin": cfg.compiler = rest[1]
			case "--shared": cfg.shared = rest[1]
			case "--package": cfg.owner = rest[1]
			}
			rest = rest[1:]
		case "--":
			rest = rest[1:]
			break options
		case:
			break options
		}
		rest = rest[1:]
	}
	for flag in rest {
		if strings.has_prefix(flag, "-collection:shared=") {
			cfg.shared = strings.trim_prefix(flag, "-collection:shared=")
		} else {
			append(&cfg.flags, flag)
		}
	}

	root := os.get_working_directory(context.allocator) or_return
	if !os.is_absolute_path(cfg.out) {
		cfg.out = path(root, cfg.out)
	}
	compiler := output(root, "which", cfg.compiler) or_return
	cfg.compiler = os.get_absolute_path(compiler, context.allocator) or_return
	ensure_dir(cfg.out) or_return
	if cfg.mode == "build" {
		run(cfg.compiler, "build", "tools/version", "-vet", "-warnings-as-errors", "-o:none",
		    fmt.tprintf("-out:%s", path(cfg.out, "kakunou-version"))) or_return
	}

	return suites(root, &cfg)
}
