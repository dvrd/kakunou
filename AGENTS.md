# Development workflow

`develop` and `main` are the two long-lived branches. Integrate work on `develop` and release through a pull request to `main`.

1. Start from an up-to-date `develop`. If you use temporary branches or worktrees, branch from `develop` and merge their completed work back into it. Use Conventional Commits so the release tool can determine the next version.
2. Fetch `origin/main`, merge it into `develop`, and run `task version:prepare` after committing the changes. Commit the updated literal when the task changes it. Run the full `task check` on the integrated `develop` branch. Once it passes, push `develop` and open or update the PR with `develop` as the head and `main` as the base.
3. Wait for the PR checks to pass. When the user approves the merge, merge the verified head with a merge commit to preserve ancestry.
4. Follow the [release workflow](.github/workflows/check-and-release.yml) on `main` through completion. It checks the merged commit again. When `task version:prepare` printed a tag, verify that the workflow published the annotated tag and GitHub release for that merge.
5. Fetch `origin/main` and its tags after the workflow finishes. Merge `origin/main` back into `develop` and push so the next change starts with the published version.
6. Remove the task’s clean temporary worktrees and delete their local and remote branches after verifying each tip is in `origin/develop` with `git merge-base --is-ancestor <tip> origin/develop`. Preserve worktrees with uncommitted work. Finish on `develop`.
