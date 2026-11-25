package integration_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
runner_validates_selectors_across_suites_in_a_renamed_checkout :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	tmp, dir_err := os.make_directory_temp("", "kakunou-check-fixture-*", context.allocator)
	if !testing.expect_value(t, dir_err, nil) {
		return
	}
	defer os.remove_all(tmp)
	root := fmt.tprintf("%s/renamed-checkout", tmp)
	for subdir in ([]string{"src", "tests/alpha", "tests/beta", "tests/gamma"}) {
		if !testing.expect_value(t, os.make_directory_all(fmt.tprintf("%s/%s", root, subdir)), nil) {
			return
		}
	}
	write :: proc(t: ^testing.T, root, name, source: string) -> bool {
		return testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), source), nil)
	}
	if !write(t, root, "src/library.odin", "package sample\nTOKEN :: 42\n") ||
	   !write(t, root, "tests/alpha/alpha_test.odin", `package alpha
import "core:testing"
import "core:time"
import "core:os"
import db "shared:kakunou"
@(test)
local_alias :: proc(t: ^testing.T) {
	stage := os.get_env("KAKUNOU_STAGED_ROOT", context.temp_allocator)
	info, err := os.stat(stage, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, info.mode & os.Permissions_All, os.Permissions{.Read_User, .Write_User, .Execute_User})
	time.sleep(1300 * time.Millisecond)
	testing.expect_value(t, db.TOKEN, 42)
}
`) ||
	   !write(t, root, "tests/beta/beta_test.odin", `package beta
import "core:testing"
when #config(ENABLE_TEST, true) {
	@(test)
	conditional :: proc(t: ^testing.T) { testing.expect(t, true) }
}
`) ||
	   !write(t, root, "tests/alpha/inactive_windows.odin", `package alpha
import "core:testing"
@(test)
excluded :: proc(t: ^testing.T) { testing.expect(t, false) }
`) ||
	   !write(t, root, "tests/gamma/gamma_test.odin", `package gamma
import "core:testing"
@(test)
unconditional :: proc(t: ^testing.T) { testing.expect(t, true) }
`) ||
	   !write(t, root, "tests/gamma/gated.odin", `#+build windows
package gamma
import "core:testing"
@(test)
tag_excluded :: proc(t: ^testing.T) { testing.expect(t, false) }
`) {
		return
	}

	compiler := os.get_env("KAKUNOU_REAL_ODIN", context.allocator)
	if compiler == "" {
		compiler = "odin"
	}
	runner := fmt.tprintf("%s/check", tmp)
	checker_source := "tools/check"
	if !os.is_dir(checker_source) {
		checker_source = #directory + "/../../tools/check"
	}
	state, _, build_log, build_err := os.process_exec({
		command = {compiler, "build", checker_source, fmt.tprintf("-out:%s", runner)},
	}, context.allocator)
	if !testing.expect_value(t, build_err, nil) || !testing.expect(t, state.success, string(build_log)) {
		return
	}

	execute :: proc(t: ^testing.T, root, runner, compiler, selector: string, success: bool, quiet := false) -> string {
		command: [dynamic]string
		append(&command, runner, "test", "--package", "all", "--odin", compiler, "--shared", "../external",
		                           fmt.tprintf("-define:ODIN_TEST_NAMES=%s", selector))
		if quiet {
			append(&command, "-define:ODIN_TEST_LOG_STATE_CHANGES=false")
		}
		run, out, logs, err := os.process_exec({
			working_dir = root,
			command = command[:],
		}, context.allocator)
		testing.expect_value(t, err, nil)
		testing.expect(t, run.success == success, string(logs))
		return strings.concatenate({string(out), string(logs)})
	}

	log := execute(t, root, runner, compiler, "local_alias,beta.conditional,gamma.unconditional,", true)
	testing.expect(t, strings.contains(log, "PASS  alpha.local_alias"), log)
	testing.expect(t, strings.contains(log, "PASS  beta.conditional"), log)
	testing.expect(t, strings.contains(log, "PASS  gamma.unconditional"), log)
	testing.expect(t, strings.contains(log, "queue unknown"), log)
	testing.expect(t, strings.contains(log, "tests/beta (count unknown)"), log)
	testing.expect(t, strings.contains(log, "tests/gamma (count unknown)"), log)
	testing.expect(t, !strings.contains(log, "WAIT  alpha.excluded"), log)

	for selector in ([]string{"alpha.excluded,gamma.tag_excluded", "beta.conditional,does_not_exist"}) {
		miss := execute(t, root, runner, compiler, selector, false)
		testing.expect(t, strings.contains(miss, "no selected test matched"), miss)
	}
	if !write(t, root, "tests/beta/dependency.odin", "package beta\nimport \"shared:additional\"\nVALUE :: additional.VALUE\n") {
		return
	}
	missing := execute(t, root, runner, compiler, "beta.conditional", false)
	testing.expect(t, strings.contains(missing, "missing shared dependency"), missing)
	if !testing.expect_value(t, os.make_directory_all(fmt.tprintf("%s/external/additional", tmp)), nil) ||
	   !write(t, tmp, "external/additional/dependency.odin", "package additional\nVALUE :: true\n") {
		return
	}
	resolved := execute(t, root, runner, compiler, "beta.conditional", true, quiet = true)
	testing.expect(t, !strings.contains(resolved, "PASS  beta.conditional"), resolved)
}

@(test)
task_build_cleans_default_outputs_and_keeps_explicit_outputs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	tmp, dir_err := os.make_directory_temp("", "kakunou build fixture-*", context.allocator)
	if !testing.expect_value(t, dir_err, nil) {
		return
	}
	defer os.remove_all(tmp)

	compiler := os.get_env("KAKUNOU_REAL_ODIN", context.allocator)
	parent_env, env_err := os.environ(context.allocator)
	if !testing.expect_value(t, env_err, nil) {
		return
	}
	env: [dynamic]string
	for entry in parent_env {
		key, _, _ := strings.partition(entry, "=")
		switch key {
		case "TMPDIR", "CHECK_DIR", "KAKUNOU_CHECK_DIR", "KAKUNOU_OUT", "ODIN", "CLI_ARGS":
			continue
		}
		append(&env, entry)
	}
	sentinel := fmt.tprintf("%s/sentinel", tmp)
	if !testing.expect_value(t, os.make_directory(sentinel), nil) ||
	   !testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/keep", sentinel), "fixture"), nil) {
		return
	}
	append(&env, fmt.tprintf("TMPDIR=%s", tmp), fmt.tprintf("KAKUNOU_RUNNER_DIR=%s", sentinel))
	if compiler != "" {
		append(&env, fmt.tprintf("ODIN=%s", compiler))
	}

	for keep in ([]bool{false, true}) {
		command: [dynamic]string
		append(&command, "task", "build", "PACKAGE=unit", fmt.tprintf("RUNNER_DIR=%s", sentinel))
		if keep {
			append(&command, fmt.tprintf("CHECK_DIR=%s/artifacts", tmp))
		}
		state, _, logs, err := os.process_exec({env = env[:], command = command[:]}, context.allocator)
		if !testing.expect_value(t, err, nil) || !testing.expect(t, state.success, string(logs)) {
			return
		}
		files, read_err := os.read_all_directory_by_path(tmp, context.allocator)
		testing.expect_value(t, read_err, nil)
		for file in files {
			testing.expect(t, !strings.has_prefix(file.name, "kakunou-task-"), file.name)
			testing.expect(t, !strings.has_prefix(file.name, "odin-library-tests-"), file.name)
		}
		testing.expect(t, os.is_file(fmt.tprintf("%s/keep", sentinel)))
		testing.expect(t, !os.exists(fmt.tprintf("%s/kakunou-check", tmp)))
		testing.expect_value(t, os.is_file(fmt.tprintf("%s/artifacts/kakunou-version", tmp)), keep)
		testing.expect_value(t, os.is_file(fmt.tprintf("%s/artifacts/tests/unit/kakunou-tests", tmp)), keep)
	}
}
