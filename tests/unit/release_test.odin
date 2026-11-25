package unit_tests

import "core:testing"
import version "../../tools/version"

@(test)
version_literal_locates_only_the_declaration :: proc(t: ^testing.T) {
	source := "package sqlite\r\n// Previously v0.2.2\r\nVERSION   ::   \"v0.2.2\" // public tag\r\n"
	tag, offset, ok := version.version_literal(source)
	testing.expect(t, ok)
	testing.expect_value(t, tag, "v0.2.2")
	testing.expect_value(t, source[offset:], "v0.2.2\" // public tag\r\n")
}
