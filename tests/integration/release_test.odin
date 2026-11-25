package integration_tests

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

release_cli :: proc(
	t: ^testing.T,
	dir: string,
	env: []string,
	command: []string,
	success := true,
	loc := #caller_location,
) -> string {
	state, stdout, stderr, err := os.process_exec({working_dir = dir, env = env, command = command}, context.allocator)
	if err != nil || (state.exit_code == 0) != success {
		testing.fail_now(t, fmt.tprintf("%s returned %d (%v)\n%s%s", command[0], state.exit_code, err, stdout, stderr), loc)
	}
	return strings.trim_right(string(stdout), "\r\n")
}

@(test)
release_verifies_every_suite_and_preserves_checkout_on_failure_or_retry :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	tmp, dir_err := os.make_directory_temp("", "kakunou release test-*", context.allocator)
	if !testing.expect_value(t, dir_err, nil) {
		return
	}
	defer os.remove_all(tmp)

	// The release starts in a linked worktree, with no origin remote.
	primary := fmt.tprintf("%s/primary", tmp)
	repo := fmt.tprintf("%s/linked checkout", tmp)
	tool := fmt.tprintf("%s/kakunou-version", tmp)
	mode := fmt.tprintf("%s/check-mode", tmp)
	compiler := os.get_env("ODIN", context.allocator)
	release_cli(t, ".", nil, {compiler if compiler != "" else "odin", "build", "tools/version", fmt.tprintf("-out:%s", tool)})

	parent_env, err := os.environ(context.allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	env: [dynamic]string
	for entry in parent_env {
		key, _, _ := strings.partition(entry, "=")
		switch key {
		case "PACKAGE", "INTERNAL", "KAKUNOU_PACKAGE", "KAKUNOU_INTERNAL", "CLI_ARGS", "TMPDIR":
			continue
		}
		if !strings.has_prefix(key, "GIT_") {
			append(&env, entry)
		}
	}
	append(&env, "PACKAGE=unit", "INTERNAL=1", "KAKUNOU_PACKAGE=unit", "KAKUNOU_INTERNAL=1",
	       "CLI_ARGS=-define:ODIN_TEST_NAMES=one_test", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
	       fmt.tprintf("TMPDIR=%s", tmp), fmt.tprintf("FIXTURE_CHECKOUT=%s", repo), fmt.tprintf("FIXTURE_MODE=%s", mode))
	release_cli(t, tmp, env[:], {"git", "init", "-q", "-b", "main", primary})
	git :: proc(t: ^testing.T, dir: string, env: []string, args: ..string) -> string {
		command: [dynamic]string
		append(&command, "git")
		append(&command, ..args)
		return release_cli(t, dir, env, command[:])
	}
	git(t, primary, env[:], "config", "user.name", "Release fixture")
	git(t, primary, env[:], "config", "user.email", "release@example.invalid")
	version_file := "src/version.odin"
	initial :: "package sqlite\nVERSION :: \"v0.2.0\"\n"
	if !testing.expect_value(t, os.make_directory(fmt.tprintf("%s/src", primary)), nil) ||
	   !testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/%s", primary, version_file), initial), nil) {
		return
	}
	// A tiny real Taskfile exercises Task's variable precedence and the check
	// environment. Its check manipulates only this fixture and never runs tests.
	taskfile :: `version: '3'
env:
  KAKUNOU_PACKAGE: '{{.PACKAGE | default "all"}}'
  KAKUNOU_INTERNAL: '{{.INTERNAL | default "0"}}'
tasks:
  check:
    cmds:
      - |
        set -eu
        test "{{.PACKAGE}}" = all
        test "{{.INTERNAL}}" = 0
        test "$KAKUNOU_PACKAGE" = all
        test "$KAKUNOU_INTERNAL" = 0
        test -z "{{.CLI_ARGS}}"
        case "$(cat "$FIXTURE_MODE")" in
          interrupt)
            pwd > "$FIXTURE_MODE.ready"
            while test -e "$FIXTURE_MODE.block"; do sleep 0.05; done
            touch "$FIXTURE_MODE.done"
            exit 1 ;;
          fail) exit 1 ;;
          edit-caller) echo '// concurrent edit' >> "$FIXTURE_CHECKOUT/src/version.odin" ;;
          edit-candidate) echo '// changed during check' >> src/version.odin ;;
          switch) git -C "$FIXTURE_CHECKOUT" switch -q alternate ;;
          pass) ;;
          *) exit 2 ;;
        esac
`
	if !testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/Taskfile.yml", primary), taskfile), nil) {
		return
	}
	git(t, primary, env[:], "add", ".")
	git(t, primary, env[:], "commit", "-qm", "initial")
	git(t, primary, env[:], "tag", "v0.2.0")
	git(t, primary, env[:], "worktree", "add", "-qb", "release-branch", repo, "HEAD")
	git(t, repo, env[:], "commit", "--allow-empty", "-qm", "fix: validate release fixture")
	head := git(t, repo, env[:], "rev-parse", "HEAD")
	git(t, repo, env[:], "branch", "alternate", head)
	filename := fmt.tprintf("%s/%s", repo, version_file)

	for scenario in ([]string{"fail", "edit-candidate", "edit-caller", "switch"}) {
		if !testing.expect_value(t, os.write_entire_file(mode, scenario), nil) {
			return
		}
		release_cli(t, repo, env[:], {tool, "release"}, success = false)
		testing.expect_value(t, git(t, repo, env[:], "rev-parse", "release-branch"), head)
		testing.expect_value(t, git(t, repo, env[:], "tag", "--list", "v0.2.1"), "")
		contents, read_err := os.read_entire_file(filename, context.allocator)
		testing.expect_value(t, read_err, nil)
		if scenario == "edit-caller" {
			testing.expect_value(t, string(contents), initial+"// concurrent edit\n")
			git(t, repo, env[:], "restore", "--", version_file)
		} else {
			testing.expect_value(t, string(contents), initial)
		}
		if scenario == "switch" {
			testing.expect_value(t, git(t, repo, env[:], "branch", "--show-current"), "alternate")
			git(t, repo, env[:], "switch", "-q", "release-branch")
		}
		testing.expect_value(t, git(t, repo, env[:], "status", "--porcelain"), "")
	}

	// An uncatchable interruption can leave a disposable worktree behind, but
	// leaves the user's branch and version bytes ready for a normal retry.
	if !testing.expect_value(t, os.write_entire_file(mode, "interrupt"), nil) {
		return
	}
	block := fmt.tprintf("%s.block", mode)
	if !testing.expect_value(t, os.write_entire_file(block, ""), nil) {
		return
	}
	defer os.remove(block)
	child, start_err := os.process_start({command = {tool, "release"}, working_dir = repo, env = env[:]})
	if !testing.expect_value(t, start_err, nil) {
		return
	}
	wait_for_file :: proc(path: string) -> bool {
		start := time.tick_now()
		for !os.exists(path) && time.tick_since(start) < 10*time.Second {
			time.sleep(20*time.Millisecond)
		}
		return os.exists(path)
	}
	ready := wait_for_file(fmt.tprintf("%s.ready", mode))
	kill_err := os.process_kill(child)
	_, wait_err := os.process_wait(child)
	os.remove(block)
	if !testing.expect(t, ready) || !testing.expect_value(t, kill_err, nil) || !testing.expect_value(t, wait_err, nil) {
		return
	}
	testing.expect(t, wait_for_file(fmt.tprintf("%s.done", mode)))
	testing.expect_value(t, git(t, repo, env[:], "status", "--porcelain"), "")
	testing.expect_value(t, git(t, repo, env[:], "rev-parse", "HEAD"), head)
	testing.expect_value(t, git(t, repo, env[:], "tag", "--list", "v0.2.1"), "")

	// A matching subject and filename alone do not make a valid tag retry.
	if !testing.expect_value(t, os.write_entire_file(mode, "pass"), nil) {
		return
	}
	git(t, repo, env[:], "switch", "-qc", "lookalike")
	lookalike :: "package sqlite\nVERSION :: \"v0.2.1\"\nEXTRA :: 1\n"
	if !testing.expect_value(t, os.write_entire_file(filename, lookalike), nil) {
		return
	}
	git(t, repo, env[:], "commit", "-qam", "chore(release): v0.2.1")
	release_cli(t, repo, env[:], {tool, "release"}, success = false)
	testing.expect_value(t, git(t, repo, env[:], "tag", "--list", "v0.2.1"), "")
	git(t, repo, env[:], "switch", "-q", "release-branch")

	// Force tag creation to fail after the branch advances, then retry.
	git(t, repo, env[:], "config", "gpg.program", "false")
	git(t, repo, env[:], "config", "tag.gpgSign", "true")
	release_cli(t, repo, env[:], {tool, "release"}, success = false)
	release_head := git(t, repo, env[:], "rev-parse", "HEAD")
	testing.expect_value(t, git(t, repo, env[:], "rev-parse", "HEAD^"), head)
	testing.expect_value(t, git(t, repo, env[:], "log", "-1", "--format=%s"), "chore(release): v0.2.1")
	testing.expect_value(t, git(t, repo, env[:], "diff", "--name-only", "HEAD^", "HEAD"), version_file)
	testing.expect_value(t, git(t, repo, env[:], "tag", "--list", "v0.2.1"), "")
	git(t, repo, env[:], "config", "tag.gpgSign", "false")
	git(t, repo, env[:], "branch", "-f", "alternate", release_head)
	if !testing.expect_value(t, os.write_entire_file(mode, "switch"), nil) {
		return
	}
	release_cli(t, repo, env[:], {tool, "release"}, success = false)
	testing.expect_value(t, git(t, repo, env[:], "tag", "--list", "v0.2.1"), "")
	testing.expect_value(t, git(t, repo, env[:], "branch", "--show-current"), "alternate")
	git(t, repo, env[:], "switch", "-q", "release-branch")
	if !testing.expect_value(t, os.write_entire_file(mode, "pass"), nil) {
		return
	}
	release_cli(t, repo, env[:], {tool, "release"})
	testing.expect_value(t, git(t, repo, env[:], "rev-parse", "HEAD"), release_head)
	testing.expect_value(t, git(t, repo, env[:], "rev-parse", "v0.2.1^{commit}"), release_head)
	testing.expect_value(t, git(t, repo, env[:], "cat-file", "-t", "v0.2.1"), "tag")
	testing.expect_value(t, git(t, repo, env[:], "status", "--porcelain"), "")
	testing.expect_value(t, release_cli(t, repo, env[:], {tool, "current"}), "v0.2.1")
}

@(test)
release_workflow_verifies_prepared_merges_and_resumes_only_its_own_tag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir, err := os.make_directory_temp("", "kakunou-publish-*", context.allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	defer os.remove_all(dir)
	release_cli(t, ".", nil, {"bash", "tests/integration/fixtures/release_workflow.sh", dir})
}
