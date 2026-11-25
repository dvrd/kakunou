package main

import "core:encoding/json"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:slice"
import "core:strings"

JSON_REPORT_PREFIX :: "-define:ODIN_TEST_JSON_REPORT="

Test_Selection :: struct {
	names:   [dynamic]string,
	matched: map[string]bool,
	report:  string,
}

test_selection :: proc(flags: []string) -> (selection: Test_Selection) {
	for flag in flags {
		if strings.has_prefix(flag, "-define:ODIN_TEST_NAMES=") {
			names := strings.trim_prefix(flag, "-define:ODIN_TEST_NAMES=")
			for selector in strings.split_iterator(&names, ",") {
				append(&selection.names, selector)
			}
		} else if strings.has_prefix(flag, JSON_REPORT_PREFIX) {
			selection.report = strings.trim_prefix(flag, JSON_REPORT_PREFIX)
		}
	}
	return
}

record_matches :: proc(selection: ^Test_Selection, report_path: string) -> os.Error {
	data := os.read_entire_file(report_path, context.allocator) or_return
	report: struct { packages: map[string][]struct { name: string } }
	if err := json.unmarshal(data, &report); err != nil {
		return fail("could not read the test runner's JSON results", report_path)
	}
	for pkg, tests in report.packages {
		for test in tests {
			selection.matched[test.name] = true
			selection.matched[fmt.tprintf("%s.%s", pkg, test.name)] = true
		}
	}
	return nil
}

Suite_Inventory :: struct {
	names: []string,
	known: bool,
}

// The preview is only exact for unconditional packages. Let Odin select all
// other tests, then use its completed-run report to validate named filters.
suite_test_names :: proc(repo, dir: string, files, flags, selectors: []string) -> (plan: Suite_Inventory, err: os.Error) {
	for flag in flags {
		if flag == "-all-packages" || strings.has_prefix(flag, "-overlay:") {
			return {}, nil
		}
	}
	if os.base(dir) == "internal" {
		return {}, nil
	}
	found: [dynamic]string
	for file in files {
		if path(os.dir(file)) != dir || !strings.has_suffix(file, ".odin") {
			continue
		}
		base := os.base(file)
		if strings.has_prefix(base, ".") {
			continue
		}
		stem := strings.trim_suffix(base, ".odin")
		if separator := strings.last_index_byte(stem, '_'); separator >= 0 {
			suffix := stem[separator+1:]
			os_type, _ := parser.get_build_os_from_string(suffix)
			if os_type != .Unknown || parser.get_build_arch_from_string(suffix) != .Unknown {
				return {}, nil
			}
		}
		source := os.read_entire_file(path(repo, file), context.allocator) or_return
		tree := ast.File{fullpath = file, src = string(source)}
		reader := parser.default_parser()
		if !parser.parse_file(&reader, &tree) {
			return {}, nil
		}
		tags := parser.parse_file_tags(tree)
		if tags.ignore || len(tags.build) > 0 || len(tags.build_project_name) > 0 {
			return {}, nil
		}
		for stmt in tree.decls {
			if _, conditional := stmt.derived_stmt.(^ast.When_Stmt); conditional {
				return {}, nil
			}
			decl := stmt.derived_stmt.(^ast.Value_Decl) or_continue
			for attr in decl.attributes {
				for elem in attr.elems {
					ident := elem.derived_expr.(^ast.Ident) or_continue
					if ident.name != "test" {
						continue
					}
					test := decl.names[0].derived_expr.(^ast.Ident) or_continue
					qualified := fmt.tprintf("%s.%s", tree.pkg_name, test.name)
					if len(selectors) == 0 {
						append(&found, qualified)
					} else {
						for selector in selectors {
							if selector == test.name || selector == qualified {
								append(&found, qualified)
							}
						}
					}
				}
			}
		}
	}
	slice.sort(found[:])
	return {found[:], true}, nil
}
