package main

import "core:strings"

Version :: struct {
	major, minor, patch: int,
}

Bump :: enum {
	Major,
	Minor,
	Patch,
}

Impact :: enum {
	None,
	Fix,
	Feature,
	Breaking,
}

COMPONENT_MAX :: 999_999_999

// fix bumps the patch. feat bumps the minor from v1 onward and the patch on
// v0. A breaking mark bumps the major from v1 onward and the minor on v0.
release_bump :: proc(base: Version, impact: Impact) -> Bump {
	switch impact {
	case .Breaking:
		return .Minor if base.major == 0 else .Major
	case .Feature:
		return .Patch if base.major == 0 else .Minor
	case .Fix:
		return .Patch
	case .None:
		unreachable()
	}

	unreachable()
}

version_bump :: proc(version: Version, part: Bump) -> (next: Version, ok: bool) {
	switch part {
	case .Major:
		if version.major < COMPONENT_MAX {
			return {version.major + 1, 0, 0}, true
		}
	case .Minor:
		if version.minor < COMPONENT_MAX {
			return {version.major, version.minor + 1, 0}, true
		}
	case .Patch:
		if version.patch < COMPONENT_MAX {
			return {version.major, version.minor, version.patch + 1}, true
		}
	}

	return {}, false
}

parse_tag :: proc(tag: string) -> (version: Version, ok: bool) {
	if len(tag) < len("v0.0.0") || tag[0] != 'v' {
		return {}, false
	}

	rest := tag[1:]
	version.major, rest = parse_component(rest) or_return
	if len(rest) == 0 || rest[0] != '.' {
		return {}, false
	}

	version.minor, rest = parse_component(rest[1:]) or_return
	if len(rest) == 0 || rest[0] != '.' {
		return {}, false
	}

	version.patch, rest = parse_component(rest[1:]) or_return
	if len(rest) != 0 {
		return {}, false
	}

	return version, true
}

// Reads one component and returns the unparsed tail, including a following dot.
parse_component :: proc(text: string) -> (value: int, rest: string, ok: bool) {
	if text == "" || text[0] < '0' || text[0] > '9' {
		return 0, text, false
	}

	if text[0] == '0' && len(text) > 1 && text[1] >= '0' && text[1] <= '9' {
		return 0, text, false
	}

	digits := 0
	for digits < len(text) && text[digits] >= '0' && text[digits] <= '9' {
		if digits == 9 {
			return 0, text, false
		}

		value = value * 10 + int(text[digits] - '0')
		digits += 1
	}

	return value, text[digits:], digits > 0
}

Version_Order :: enum {
	Lower,
	Equal,
	Higher,
}

version_compare :: proc(a, b: Version) -> Version_Order {
	if a.major != b.major {
		return .Lower if a.major < b.major else .Higher
	}

	if a.minor != b.minor {
		return .Lower if a.minor < b.minor else .Higher
	}

	if a.patch != b.patch {
		return .Lower if a.patch < b.patch else .Higher
	}

	return .Equal
}

highest_tag :: proc(tags: []string) -> (highest: string, ok: bool) {
	best: Version
	for tag in tags {
		version := parse_tag(tag) or_continue
		if !ok || version_compare(version, best) == .Higher {
			best = version
			highest = tag
			ok = true
		}
	}

	return highest, ok
}

// Git log -z separates complete commit messages with NUL bytes.
release_impact :: proc(messages: string) -> Impact {
	remaining := messages
	highest := Impact.None
	for message in strings.split_iterator(&remaining, "\x00") {
		highest = max(highest, commit_impact(message))
		if highest == .Breaking {
			break
		}
	}

	return highest
}

commit_impact :: proc(message: string) -> Impact {
	body := message
	subject, found := strings.split_lines_iterator(&body)
	if !found {
		return .None
	}

	separator := strings.index(subject, ": ")
	if separator < 1 || strings.trim_space(subject[separator + 2:]) == "" {
		return .None
	}

	prefix := subject[:separator]
	breaking := strings.has_suffix(prefix, "!")
	name := strings.trim_suffix(prefix, "!")
	if scope_start := strings.index(name, "("); scope_start >= 0 {
		if !strings.has_suffix(name, ")") || scope_start + 2 >= len(name) {
			return .None
		}

		scope := name[scope_start + 1:len(name) - 1]
		if strings.contains(scope, "(") || strings.contains(scope, ")") {
			return .None
		}

		name = name[:scope_start]
	}

	if !commit_token(name) {
		return .None
	}

	if breaking || breaking_footer(body) {
		return .Breaking
	}

	if strings.equal_fold(name, "feat") {
		return .Feature
	}

	if strings.equal_fold(name, "fix") {
		return .Fix
	}

	return .None
}

breaking_footer :: proc(body: string) -> bool {
	remaining := body
	first := strings.split_lines_iterator(&remaining) or_return
	if strings.trim_space(first) != "" {
		return false
	}

	paragraph_start, footers := true, false
	for line in strings.split_lines_iterator(&remaining) {
		if strings.trim_space(line) == "" {
			paragraph_start = true
			continue
		}

		trailer, breaking := footer_kind(line)
		if breaking && (paragraph_start || footers) {
			return true
		}

		if paragraph_start {
			paragraph_start, footers = false, trailer
		}
	}

	return false
}

footer_kind :: proc(line: string) -> (trailer, breaking: bool) {
	for separator in ([]string{": ", " #"}) {
		index := strings.index(line, separator)
		if index < 1 || strings.trim_space(line[index + len(separator):]) == "" {
			continue
		}

		key := line[:index]
		if separator == ": " && (key == "BREAKING CHANGE" || key == "BREAKING-CHANGE") {
			return true, true
		}

		if commit_token(key) {
			return true, false
		}
	}

	return false, false
}

commit_token :: proc(text: string) -> bool {
	for byte in text {
		letter := (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z')
		if !letter && (byte < '0' || byte > '9') && byte != '-' {
			return false
		}
	}

	return text != ""
}
