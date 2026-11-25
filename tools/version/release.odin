package version_tool

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

command_output :: proc(args: ..string) -> (output: string, ok: bool) {
	raw := command_bytes(..args) or_return
	return strings.trim_right(raw, "\r\n"), true
}

command_bytes :: proc(args: ..string) -> (string, bool) {
	state, stdout, stderr, err := os.process_exec({command = args}, context.allocator)
	fmt.eprint(string(stderr))
	if err != nil || state.exit_code != 0 {
		fmt.eprintln("kakunou: command failed", args, err, state.exit_code)
		return "", false
	}
	return string(stdout), true
}

repository_version :: proc(releasing: bool) -> bool {
	head := command_output("git", "rev-parse", "--verify", "HEAD") or_return
	branch: string
	if releasing {
		prefix := command_output("git", "rev-parse", "--show-prefix") or_return
		if prefix != "" {
			fmt.eprintln("kakunou: run release from the repository root")
			return false
		}
		branch = command_output("git", "symbolic-ref", "--quiet", "HEAD") or_return
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
	return release(branch, head, base, next)
}

// Compare with the protected main commit, even when its tag has not been
// published yet. Merge subjects vary between GitHub's preview and final merge.
prepared_version :: proc(base_ref: string, prepare: bool) -> bool {
	base := command_output("git", "rev-parse", "--verify", strings.concatenate({base_ref, "^{commit}"})) or_return
	_ = command_output("git", "merge-base", "--is-ancestor", base, "HEAD") or_return
	if !prepare {
		parent := command_output("git", "rev-parse", "HEAD^1") or_return
		if parent != base {
			fmt.eprintln("kakunou: expected the event base to be the first parent of the checked commit")
			return false
		}
	}
	prior_source := command_bytes("git", "cat-file", "blob", fmt.tprintf("%s:%s", base, VERSION_PATH)) or_return
	prior, _ := version_literal(prior_source) or_return
	messages := command_bytes("git", "log", "--no-merges", "-z", "--format=%B", fmt.tprintf("%s..HEAD", base)) or_return
	next := next_tag(prior, messages) or_return
	expected := next if next != "" else prior
	source := read_file(VERSION_PATH) or_return
	current, offset := version_literal(source) or_return
	if current != expected {
		if !prepare {
			fmt.eprintln("kakunou: expected VERSION", expected, "in", VERSION_PATH, "— run task version:prepare on develop")
			return false
		}
		updated := strings.concatenate({source[:offset], expected, source[offset+len(current):]})
		if err := os.write_entire_file(VERSION_PATH, updated); err != nil {
			fmt.eprintln("kakunou: cannot prepare VERSION", err)
			return false
		}
	}
	if next != "" {
		fmt.println(next)
	}
	return true
}

release_check :: proc(dir: string) -> bool {
	environment, env_err := os.environ(context.allocator)
	if env_err != nil {
		fmt.eprintln("kakunou: cannot read release check environment", env_err)
		return false
	}
	child_env: [dynamic]string
	for entry in environment {
		key, _, _ := strings.partition(entry, "=")
		switch key {
		case "PACKAGE", "INTERNAL", "KAKUNOU_PACKAGE", "KAKUNOU_INTERNAL", "CLI_ARGS", "CLI_ARGS_LIST":
			continue
		}
		append(&child_env, entry)
	}
	append(&child_env, "PACKAGE=all", "INTERNAL=0", "KAKUNOU_PACKAGE=all", "KAKUNOU_INTERNAL=0")
	check, start_err := os.process_start({
		command = {"task", "check", "PACKAGE=all", "INTERNAL=0"},
		working_dir = dir, env = child_env[:], stdout = os.stdout, stderr = os.stderr,
	})
	if start_err != nil {
		fmt.eprintln("kakunou: cannot start task check", start_err)
		return false
	}
	state, wait_err := os.process_wait(check)
	if wait_err != nil || state.exit_code != 0 {
		fmt.eprintln("kakunou: release checks failed")
		return false
	}
	return true
}

checkout_matches :: proc(branch, head: string) -> bool {
	ref := command_output("git", "symbolic-ref", "--quiet", "HEAD") or_return
	tip := command_output("git", "rev-parse", "--verify", "HEAD") or_return
	status := command_output("git", "status", "--porcelain", "--untracked-files=all") or_return
	if ref != branch || tip != head || status != "" {
		fmt.eprintln("kakunou: the checkout changed while verifying the release")
		return false
	}
	return true
}

release :: proc(branch, head, base, next: string) -> bool {
	root := command_output("git", "rev-parse", "--show-toplevel") or_return
	stage, err := os.make_directory_temp("", "kakunou-release-*", context.allocator)
	if err != nil {
		fmt.eprintln("kakunou: cannot create release worktree directory", err)
		return false
	}
	if _, ok := command_output("git", "worktree", "add", "--quiet", "--detach", stage, head); !ok {
		os.remove_all(stage)
		return false
	}
	defer {
		_, _ = command_output("git", "worktree", "remove", "--force", stage)
	}

	file := fmt.tprintf("%s/%s", stage, VERSION_PATH)
	source := read_file(file) or_return
	current, offset := version_literal(source) or_return
	if current != base && current != next {
		fmt.eprintln("kakunou: VERSION must match the latest release", base)
		return false
	}

	subject := fmt.tprintf("chore(release): %s", next)
	tip := head
	updated := source
	if current == base {
		updated = strings.concatenate({source[:offset], next, source[offset+len(current):]})
		if write_err := os.write_entire_file(file, updated); write_err != nil {
			fmt.eprintln("kakunou: cannot write VERSION", write_err)
			return false
		}
		_ = command_output("git", "-C", stage, "commit", "--only", "-m", subject, "--", VERSION_PATH) or_return
		tip = command_output("git", "-C", stage, "rev-parse", "--verify", "HEAD") or_return
		parent := command_output("git", "rev-parse", fmt.tprintf("%s^", tip)) or_return
		if parent != head {
			fmt.eprintln("kakunou: release commit has an unexpected parent")
			return false
		}
	}
	// A tag retry must verify the committed bytes too: a matching subject
	// and path alone cannot establish that only the version literal changed.
	parent_source := command_bytes("git", "cat-file", "blob", fmt.tprintf("%s^:%s", tip, VERSION_PATH)) or_return
	previous, position := version_literal(parent_source) or_return
	expected := strings.concatenate({parent_source[:position], next, parent_source[position+len(previous):]})
	committed := command_bytes("git", "cat-file", "blob", fmt.tprintf("%s:%s", tip, VERSION_PATH)) or_return
	title := command_output("git", "log", "-1", "--format=%s", tip) or_return
	files := command_output("git", "diff-tree", "--no-commit-id", "--name-only", "-r", tip) or_return
	if title != subject || files != VERSION_PATH || previous != base || committed != expected {
		fmt.eprintln("kakunou: expected a release commit changing only", VERSION_PATH, "to", next)
		return false
	}

	release_check(stage) or_return
	tested := command_output("git", "-C", stage, "rev-parse", "--verify", "HEAD") or_return
	status := command_output("git", "-C", stage, "status", "--porcelain", "--untracked-files=all") or_return
	contents := read_file(file) or_return
	if tested != tip || status != "" || contents != updated {
		fmt.eprintln("kakunou: the release worktree changed during verification")
		return false
	}
	checkout_matches(branch, head) or_return
	if tip != head {
		// Git installs the verified commit in the explicitly named local branch,
		// checks its old tip, and updates its clean checked-out files together.
		_ = command_output(
			"env", "GIT_ALLOW_PROTOCOL=file", "git", "-C", stage, "push", "--quiet", "--no-follow-tags", "--recurse-submodules=no",
			"--receive-pack=git -c receive.denyCurrentBranch=updateInstead receive-pack",
			fmt.tprintf("--force-with-lease=%s:%s", branch, head),
			root, fmt.tprintf("%s:%s", tip, branch),
		) or_return
	}
	checkout_matches(branch, tip) or_return
	_ = command_output("git", "tag", "-a", next, "-m", fmt.tprintf("kakunou %s", next), tip) or_return
	fmt.println("kakunou: tagged", next)
	return true
}
