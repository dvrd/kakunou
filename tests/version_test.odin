package tests

import "core:testing"
import db "shared:kakunou"

@(test)
library_version_is_a_release_tag :: proc(t: ^testing.T) {
	testing.expect(t, release_tag(db.VERSION), db.VERSION)
}

// Accepts exactly vMAJOR.MINOR.PATCH. A zero component is a single 0.
release_tag :: proc(tag: string) -> bool {
	if len(tag) < len("v0.0.0") || tag[0] != 'v' {
		return false
	}

	parts := 0
	digits := 0
	zero := false
	for byte in tag[1:] {
		if byte == '.' {
			if digits == 0 || (zero && digits > 1) {
				return false
			}

			parts += 1
			digits = 0
			zero = false
			continue
		}

		if byte < '0' || byte > '9' {
			return false
		}

		if digits == 0 {
			zero = byte == '0'
		}

		digits += 1
		if zero && digits > 1 {
			return false
		}
	}

	return parts == 2 && digits > 0 && !(zero && digits > 1)
}
