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
	if len(args) == 1 {
		switch args[0] {
		case "current":
			source := read_file(VERSION_PATH) or_return
			tag, _ := version_literal(source) or_return
			fmt.println(tag)
			return true
		case "next", "release":
			return repository_version(args[0] == "release")
		}
	}

	if len(args) == 2 && args[0] == "latest" {
		tags := read_file(args[1]) or_return
		if latest, ok := highest_tag(strings.split_lines(tags)); ok {
			fmt.println(latest)
		}

		return true
	}

	if len(args) != 3 || args[0] != "next" {
		fmt.fprintln(os.stderr, "usage: kakunou-version current | next [<base-tag> <git-log>] | latest <tag-list> | release")
		return false
	}

	messages := read_file(args[2]) or_return
	next := next_tag(args[1], messages) or_return
	if next != "" {
		fmt.println(next)
	}
	return true
}

next_tag :: proc(tag, messages: string) -> (string, bool) {
	base, valid := parse_tag(tag)
	if !valid {
		fmt.fprintln(os.stderr, tag, "must be a vMAJOR.MINOR.PATCH tag")
		return "", false
	}
	impact := release_impact(messages)
	if impact == .None {
		return "", true
	}
	next, ok := version_bump(base, release_bump(base, impact))
	if !ok {
		fmt.fprintln(os.stderr, "cannot increment", tag)
		return "", false
	}
	return fmt.tprintf("v%d.%d.%d", next.major, next.minor, next.patch), true
}

read_file :: proc(path: string) -> (content: string, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.fprintln(os.stderr, "cannot read", path, err)
		return "", false
	}

	return string(data), true
}
