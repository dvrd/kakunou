package main

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:slice"
import "core:strings"

// Read test declarations from the staged sources. Execution and results still
// come from Odin's runner, including the actual order of parallel starts.
suite_test_names :: proc(repo, dir: string, files, flags: []string) -> (names: []string, err: os.Error) {
	filter := ""
	for flag in flags {
		if strings.has_prefix(flag, "-define:ODIN_TEST_NAMES=") {
			filter = strings.trim_prefix(flag, "-define:ODIN_TEST_NAMES=")
		}
	}
	found: [dynamic]string
	for file in files {
		if path(os.dir(file)) != dir || !strings.has_suffix(file, ".odin") {
			continue
		}
		source := os.read_entire_file(path(repo, file), context.allocator) or_return
		tree := ast.File{fullpath = file, src = string(source)}
		reader := parser.default_parser()
		if !parser.parse_file(&reader, &tree) {
			continue
		}
		for stmt in tree.decls {
			decl := stmt.derived_stmt.(^ast.Value_Decl) or_continue
			for attr in decl.attributes {
				for elem in attr.elems {
					ident := elem.derived_expr.(^ast.Ident) or_continue
					if ident.name != "test" {
						continue
					}
					test := decl.names[0].derived_expr.(^ast.Ident) or_continue
					qualified := fmt.tprintf("%s.%s", tree.pkg_name, test.name)
					if filter == "" {
						append(&found, qualified)
					} else {
						selectors := filter
						for selector in strings.split_iterator(&selectors, ",") {
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
	return found[:], nil
}
