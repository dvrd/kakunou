package private_temp

import "core:os"
import "core:strings"
import "core:sys/posix"

// mkdtemp reserves a new directory with mode 0700 before returning its path.
create :: proc(prefix: string) -> (directory: string, err: os.Error) {
	parent := os.temp_directory(context.allocator) or_return
	name := strings.concatenate({prefix, "-XXXXXX"}) or_return
	pattern := os.join_path({parent, name}, context.allocator) or_return
	buffer := strings.clone_to_cstring(pattern) or_return
	if posix.mkdtemp(cast([^]byte)buffer) == nil {
		return "", os.Platform_Error(posix.get_errno())
	}
	return string(buffer), nil
}
