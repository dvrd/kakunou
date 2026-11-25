# Verify pull requests and release main automatically

Requested after the nine audit findings. Baseline `a06dfab`. Execute on the local `develop` integration worktree. The repository has no existing Actions workflow. The current release tag is `v0.2.3`. The release tool computes the next conventional-commit version, runs checks and creates a local annotated tag.

1. Run a read-only pull-request check targeting main and exercise `task check`. Use the supported Odin, SQLite and Task toolchain on a hosted runner. Pin fetched executable artifacts and verify their checksums.
2. On push to main, including a merged PR, run the existing release tool on a local main checkout with full history and tags. Push the release commit and its annotated tag together. Restrict write permission to release and serialize publishers. Handle no-op releases and safe reruns. Keep ordinary CI and untrusted PR code separate from publishing credentials.
3. Verify workflow syntax and run the PR check on GitHub. Do not merge the PR or publish a version during verification. Preserve the current version on develop until the release job runs on main.

Scope is the GitHub Actions configuration and necessary CI documentation. Integration tests for the release tool remain under tests/integration. Stop if repository settings forbid workflow creation or publication. Executor is an isolated Codex agent; fallback is the Codex CLI. Reviewer verifies the workflow diff, `task check`, and the actual PR checks.
