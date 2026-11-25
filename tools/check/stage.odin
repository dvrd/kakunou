package main

import "core:fmt"
import "core:os"
import "core:odin/tokenizer"
import "core:slice"
import "core:strings"

ensure_dir :: proc(dir: string) -> os.Error {
	err := os.make_directory_all(dir)
	if err == .Exist && os.is_dir(dir) {
		return nil
	}
	return err
}

// Copy from Git's working-tree inventory so uncommitted edits participate,
// while ignored build products and deleted tracked files stay out of the stage.
copy_tree :: proc(source, target: string) -> (names: []string, err: os.Error) {
	list: string
	if os.exists(path(source, ".git")) {
		list = output(source, "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard") or_return
	} else {
		list = output(source, "find", ".", "-mindepth", "1", "(", "-name", ".*", "-o", "-name", "__pycache__", ")",
		              "-prune", "-o", "-type", "f", "-print0") or_return
	}
	ensure_dir(target) or_return
	files: [dynamic]string
	for entry in strings.split_iterator(&list, "\x00") {
		name := strings.trim_prefix(entry, "./")
		from := path(source, name)
		if name == "" || !os.is_file(from) {
			continue
		}
		to := path(target, name)
		ensure_dir(os.dir(to)) or_return
		os.copy_file(to, from) or_return
		append(&files, name)
	}
	return files[:], nil
}

under :: proc(file, dir: string) -> bool {
	return file == dir || strings.has_prefix(file, fmt.tprintf("%s/", dir))
}

// Imports are tokenized so comments, strings, and aliases are handled like Odin source.
collect_imports :: proc(file, boundary, shared: string, pending: ^[dynamic]string) -> os.Error {
	data := os.read_entire_file(file, context.allocator) or_return
	lexer: tokenizer.Tokenizer
	tokenizer.init(&lexer, string(data), file)
	importing := false
	for {
		token := tokenizer.scan(&lexer)
		#partial switch token.kind {
		case .EOF: return nil
		case .Import: importing = true
		case .Comment, .Ident: continue
		case .String:
			if importing {
				spec := token.text[1:len(token.text)-1]
				if strings.has_prefix(spec, "shared:") {
					name, _, _ := strings.partition(strings.trim_prefix(spec, "shared:"), "/")
					if name == "" || name == ".." || name == "." {
						return fail("invalid shared import in", file)
					}
					append(pending, name)
				} else if strings.has_prefix(spec, "./") || strings.has_prefix(spec, "../") {
					resolved := path(os.dir(file), spec)
					if !under(resolved, boundary) {
						if shared == "" || !under(resolved, shared) || resolved == shared {
							return fail("relative import escapes its package", fmt.tprintf("%s in %s", spec, file))
						}
						tail := resolved[len(shared)+1:]
						name, _, _ := strings.partition(tail, "/")
						append(pending, name)
					}
				}
			}
			importing = false
		case: importing = false
		}
	}
}

suites :: proc(root: string, cfg: ^Config) -> os.Error {
	work := os.make_directory_temp("", "odin-library-tests-*", context.allocator) or_return
	defer os.remove_all(work)
	repo := path(work, "repository")
	shared := path(work, "shared")
	files := copy_tree(root, repo) or_return
	ensure_dir(shared) or_return
	os.symlink(path(repo, "src"), path(shared, "kakunou")) or_return

	directories: map[string]bool
	pending: [dynamic]string
	for name in files {
		if !strings.has_suffix(name, ".odin") {
			continue
		}
		file := path(repo, name)
		if under(name, "src") {
			collect_imports(file, path(repo, "src"), "", &pending) or_return
		} else if under(name, "tests") {
			collect_imports(file, repo, "", &pending) or_return
			dir := path(os.dir(name))
			if os.base(dir) == "internal" {
				target := path(repo, "src", suite_owner(dir))
				if !os.is_dir(target) {
					return fail("private suite has no source package", dir)
				}
				os.copy_file(path(target, os.base(file)), file) or_return
			}
			if strings.has_suffix(name, "_test.odin") {
				directories[dir] = true
			}
		}
	}
	seen: map[string]bool
	seen["kakunou"] = true
	for i := 0; i < len(pending); i += 1 {
		name := pending[i]
		if seen[name] {
			continue
		}
		seen[name] = true
		source := path(cfg.shared, name)
		if !os.is_dir(source) {
			return fail("missing shared dependency", source)
		}
		target := path(shared, name)
		deps := copy_tree(source, target) or_return
		for dep in deps {
			if strings.has_suffix(dep, ".odin") {
				collect_imports(path(target, dep), target, shared, &pending) or_return
			}
		}
	}

	selected: [dynamic]string
	for dir in directories {
		if cfg.owner != "all" && cfg.owner != suite_owner(dir) {
			continue
		}
		if !cfg.internal || os.base(dir) == "internal" {
			append(&selected, dir)
		}
	}
	if len(selected) == 0 {
		return fail("No matching test suites")
	}
	slice.sort(selected[:])
	sdk := output(root, cfg.compiler, "root") or_return
	for collection in ([]string{"base", "core", "vendor"}) {
		os.symlink(path(sdk, collection), path(work, collection)) or_return
	}
	self := os.get_executable_path(context.allocator) or_return
	wrapper := path(work, "odin")
	os.symlink(self, wrapper) or_return
	os.set_env("ODIN", wrapper) or_return
	defer os.unset_env("ODIN")
	os.set_env("KAKUNOU_REAL_ODIN", cfg.compiler) or_return
	os.set_env("KAKUNOU_STAGED_ROOT", work) or_return

	selection := test_selection(cfg.flags[:])
	shared_flag := fmt.tprintf("-collection:shared=%s", shared)
	if cfg.mode == "build" {
		run(cfg.compiler, "check", path(repo, "src"), shared_flag, "-no-entry-point", "-vet", "-warnings-as-errors") or_return
	}
	plans: map[string]Suite_Inventory
	if cfg.mode == "test" {
		os.set_env("KAKUNOU_VALIDATE_SELECTORS", "1" if len(selection.names) > 0 else "0") or_return
		for dir in selected {
			plans[dir] = suite_test_names(repo, dir, files, cfg.flags[:], selection.names[:]) or_return
		}
	}
	for dir, index in selected {
		target := path(repo, dir)
		if os.base(dir) == "internal" {
			target = path(repo, "src", suite_owner(dir))
		}
		if cfg.mode == "test" {
			upcoming: [dynamic]string
			later_tests: [dynamic]string
			for later in selected[index+1:] {
				plan := plans[later]
				if plan.known {
					append(&later_tests, ..plan.names)
					append(&upcoming, fmt.tprintf("%s (%d)", later, len(plan.names)))
				} else {
					append(&upcoming, fmt.tprintf("%s (count unknown)", later))
				}
			}
			os.set_env("KAKUNOU_LATER_TESTS", strings.join(later_tests[:], "\n")) or_return
			os.set_env("KAKUNOU_UPCOMING_SUITES", strings.join(upcoming[:], ", ")) or_return
			os.set_env("KAKUNOU_SUITE_TESTS", strings.join(plans[dir].names, "\n")) or_return
			os.set_env("KAKUNOU_QUEUE_UNKNOWN", "0" if plans[dir].known else "1") or_return
			fmt.println(dir)
		} else {
			fmt.println(cfg.mode, dir)
		}
		args: [dynamic]string
		append(&args, self, "--suite-child", cfg.compiler, cfg.mode, target)
		if cfg.mode == "build" {
			append(&args, "-build-mode:test")
		}
		append(&args, shared_flag, "-vet", "-warnings-as-errors")
		// A suite with zero matches returns success without creating a JSON report.
		// Give each suite a fresh report path so a previous run cannot supply matches.
		verify_selection := cfg.mode == "test" && len(selection.names) > 0
		report_path := path(work, fmt.tprintf("results-%d.json", index))
		has_out := false
		for flag in cfg.flags {
			if verify_selection && strings.has_prefix(flag, JSON_REPORT_PREFIX) {
				continue
			}
			append(&args, flag)
			has_out = has_out || strings.has_prefix(flag, "-out:")
		}
		if !has_out {
			out := path(cfg.out, dir, "kakunou-tests") if cfg.mode == "build" else path(work, "tests")
			ensure_dir(os.dir(out)) or_return
			append(&args, fmt.tprintf("-out:%s", out))
		}
		if verify_selection {
			append(&args, fmt.tprintf("%s%s", JSON_REPORT_PREFIX, report_path))
		}
		suite_error := run_suite(repo, args[:])
		if verify_selection && os.exists(report_path) {
			if selection.report != "" {
				dest := selection.report
				if !os.is_absolute_path(dest) {
					dest = path(repo, dest)
				}
				os.copy_file(dest, report_path) or_return
			}
			record_matches(&selection, report_path) or_return
		}
		if suite_error != nil {
			return suite_error
		}
	}
	if cfg.mode == "test" {
		missing: [dynamic]string
		for selector in selection.names {
			if !selection.matched[selector] {
				append(&missing, selector)
			}
		}
		if len(missing) > 0 {
			return fail("no selected test matched", strings.join(missing[:], ", "))
		}
	}
	return nil
}

suite_owner :: proc(dir: string) -> string {
	owner := strings.trim_prefix(strings.trim_suffix(dir, "/internal"), "tests")
	return strings.trim_prefix(owner, "/") if owner != "" else "."
}
