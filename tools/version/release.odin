package main

import "core:fmt"
import "core:os"
import "core:odin/tokenizer"
import "core:strings"

VERSION_PATH :: "src/version.odin"

// Locate the declaration so releases replace only the tag, preserving the source around it.
version_literal :: proc(source: string) -> (tag: string, offset: int, ok: bool) {
	lexer: tokenizer.Tokenizer
	tokenizer.init(&lexer, source, VERSION_PATH)
	for token := tokenizer.scan(&lexer); token.kind != .EOF; token = tokenizer.scan(&lexer) {
		if token.kind != .Ident || token.text != "VERSION" {
			continue
		}
		if tokenizer.scan(&lexer).kind != .Colon || tokenizer.scan(&lexer).kind != .Colon {
			continue
		}
		literal := tokenizer.scan(&lexer)
		if literal.kind == .String && len(literal.text) >= 2 {
			value := literal.text[1:len(literal.text)-1]
			if _, valid := parse_tag(value); valid {
				return value, literal.pos.offset + 1, true
			}
		}
		break
	}
	fmt.eprintln("kakunou: expected VERSION to contain a release tag literal in", VERSION_PATH)
	return "", 0, false
}

command_output :: proc(args: ..string) -> (string, bool) {
	state, stdout, stderr, err := os.process_exec({command = args}, context.allocator)
	fmt.eprint(string(stderr))
	if err != nil || state.exit_code != 0 {
		fmt.eprintln("kakunou: command failed", args, err, state.exit_code)
		return "", false
	}
	return strings.trim_right(string(stdout), "\r\n"), true
}

repository_version :: proc(releasing: bool) -> bool {
	head := command_output("git", "rev-parse", "--verify", "HEAD") or_return
	if releasing {
		prefix := command_output("git", "rev-parse", "--show-prefix") or_return
		if prefix != "" {
			fmt.eprintln("kakunou: run release from the repository root")
			return false
		}
		_ = command_output("git", "symbolic-ref", "--quiet", "HEAD") or_return
		status := command_output("git", "status", "--porcelain", "--untracked-files=all") or_return
		if status != "" {
			fmt.eprintln("kakunou: commit your changes before releasing")
			return false
		}
	}

	tags := command_output("git", "tag", "--list", "v*") or_return
	base, found := highest_tag(strings.split_lines(tags))
	if !found {
		fmt.eprintln("kakunou: no release tag")
		return false
	}
	commit := command_output("git", "rev-parse", "--verify", strings.concatenate({"refs/tags/", base, "^{commit}"})) or_return
	if _, ok := command_output("git", "merge-base", "--is-ancestor", commit, head); !ok {
		fmt.eprintln("kakunou: this branch must contain the latest release", base)
		return false
	}
	messages := command_output("git", "log", "-z", "--format=%B", fmt.tprintf("%s..%s", commit, head)) or_return
	next := next_tag(base, messages) or_return
	if !releasing {
		if next != "" {
			fmt.println(next)
		}
		return true
	}
	if next == "" {
		fmt.eprintln("kakunou: no release-worthy commits since", base)
		return true
	}
	return release(head, base, next)
}

release :: proc(head, base, next: string) -> bool {
	source := read_file(VERSION_PATH) or_return
	current, offset := version_literal(source) or_return
	if current != base && current != next {
		fmt.eprintln("kakunou: VERSION must match the latest release", base)
		return false
	}

	bumping := current == base
	restore := bumping
	defer if restore {
		if tip, ok := command_output("git", "rev-parse", "HEAD"); ok && tip == head {
			_, _ = command_output("git", "restore", "--worktree", fmt.tprintf("--source=%s", head), "--", VERSION_PATH)
		}
	}
	updated := strings.concatenate({source[:offset], next, source[offset+len(current):]})
	if bumping {
		if err := os.write_entire_file(VERSION_PATH, updated); err != nil {
			fmt.eprintln("kakunou: cannot write VERSION", err)
			return false
		}
	}
	check, start_err := os.process_start({command = {"task", "check"}, stdout = os.stdout, stderr = os.stderr})
	if start_err != nil {
		fmt.eprintln("kakunou: cannot start task check", start_err)
		return false
	}
	state, wait_err := os.process_wait(check)
	if wait_err != nil || state.exit_code != 0 {
		fmt.eprintln("kakunou: release checks failed")
		return false
	}

	tip := command_output("git", "rev-parse", "HEAD") or_return
	status := command_output("git", "status", "--porcelain", "--untracked-files=all") or_return
	expected_status := fmt.tprintf(" M %s", VERSION_PATH) if bumping else ""
	if tip != head || status != expected_status {
		fmt.eprintln("kakunou: the checkout changed while verifying the release")
		return false
	}

	subject := fmt.tprintf("chore(release): %s", next)
	if bumping {
		contents := read_file(VERSION_PATH) or_return
		if contents != updated {
			fmt.eprintln("kakunou: VERSION changed during verification")
			return false
		}
		_ = command_output("git", "commit", "--only", "-m", subject, "--", VERSION_PATH) or_return
		restore = false
		tip = command_output("git", "rev-parse", "HEAD") or_return
	}

	title := command_output("git", "log", "-1", "--format=%s", tip) or_return
	files := command_output("git", "diff-tree", "--no-commit-id", "--name-only", "-r", tip) or_return
	committed := command_output("git", "show", fmt.tprintf("%s:%s", tip, VERSION_PATH)) or_return
	tag, _ := version_literal(committed) or_return
	if title != subject || files != VERSION_PATH || tag != next {
		fmt.eprintln("kakunou: expected a release commit changing only", VERSION_PATH, "to", next)
		return false
	}
	_ = command_output("git", "tag", "-a", next, "-m", fmt.tprintf("kakunou %s", next), tip) or_return
	fmt.println("kakunou: tagged", next)
	return true
}
