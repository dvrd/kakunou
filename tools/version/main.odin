package main

import "core:fmt"
import "core:os"
import "core:strings"

main :: proc() {
	context.allocator = context.temp_allocator
	if !run(os.args[1:]) {
		os.exit(1)
	}
}

run :: proc(args: []string) -> bool {
	if len(args) == 2 && args[0] == "latest" {
		tags := read_file(args[1]) or_return
		if latest, ok := highest_tag(strings.split_lines(tags)); ok {
			fmt.println(latest)
		}

		return true
	}

	if len(args) != 3 || args[0] != "next" {
		fmt.fprintln(os.stderr, "usage: version latest <tag-list> or version next <base-tag> <git-log>")
		return false
	}

	base, valid := parse_tag(args[1])
	if !valid {
		fmt.fprintln(os.stderr, args[1], "must be a vMAJOR.MINOR.PATCH tag")
		return false
	}

	messages := read_file(args[2]) or_return
	impact := release_impact(messages)
	if impact == .None {
		return true
	}

	next, ok := version_bump(base, release_bump(base, impact))
	if !ok {
		fmt.fprintln(os.stderr, "cannot increment", args[1])
		return false
	}

	fmt.printf("v%d.%d.%d\n", next.major, next.minor, next.patch)
	return true
}

read_file :: proc(path: string) -> (content: string, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.fprintln(os.stderr, "cannot read", path, err)
		return "", false
	}

	return string(data), true
}
