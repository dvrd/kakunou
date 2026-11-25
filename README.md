# Kakunou

Kakunou is an Odin library for SQLite. It links against the system SQLite 3 library.

## Build and test

The development tasks use Odin, Task v3, Git, and POSIX process utilities. Install the SQLite development library for your platform so the linker can resolve `sqlite3`.

```sh
task check                 # Type-check, build, and run all suites
task test PACKAGE=unit
task test PACKAGE=integration
task test -- -define:ODIN_TEST_NAMES=unit_tests.library_version_is_a_release_tag
task version
```

The runner maps `shared:kakunou` to this checkout’s `src/` directory. The current library and tests need no external shared collection. For additional `shared:` imports, set `SHARED=/path/to/collection` on the task or set `WEBTOOLS_SHARED` in the environment. Use `ODIN=/path/to/odin` to select a compiler.
