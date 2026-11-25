#!/usr/bin/env bash
# Disposable verification and publication fixture. Git operations are real;
# only the GitHub Release API is stubbed. All transports are restricted to files.
set -euo pipefail
root=$PWD
fixture=$1
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ALLOW_PROTOCOL=file
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
export GITHUB_REPOSITORY=fixture/kakunou GITHUB_SERVER_URL="file://$fixture"
export GITHUB_RUN_ID=3060 TAG=v0.2.5 GH_FIXTURE="$fixture/release"

"${ODIN:-odin}" build tools/version "-out:$fixture/version"
mkdir -p "$fixture/fixture" "$fixture/bin"
git init -q --bare -b main "$fixture/fixture/kakunou.git"
git init -q -b main "$fixture/work"
cd "$fixture/work"
git remote add origin "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY.git"
mkdir src
printf 'package sqlite\nVERSION :: "v0.2.4"\n' > src/version.odin
git add .
git commit -qm 'chore(release): v0.2.4'
git tag -a v0.2.4 -m 'legacy release'
git push -q origin main refs/tags/v0.2.4
base=$(git rev-parse HEAD)

# First transition from the historic bot commit, including an unprepared PR.
git switch -qc develop
git commit --allow-empty -qm 'fix: publish verified merge'
git switch -q main
git merge -q --no-ff develop -m 'Merge pull request'
if "$fixture/version" verify "$base"; then exit 1; fi
git switch -q develop
[[ $("$fixture/version" prepare) == "$TAG" ]]
git commit -qam 'chore(release): prepare literal'
[[ $("$fixture/version" prepare) == "$TAG" ]]
git diff --exit-code
git switch -qC preview "$base"
git merge -q --no-ff develop -m 'Merge pull request'
export GITHUB_SHA=$(git rev-parse HEAD)
[[ $("$fixture/version" verify "$base") == "$TAG" ]]
git push -q origin HEAD:refs/heads/main

# Extract the actual self-contained publisher. It contains no checkout or
# repository script. Each invocation gets a clean runner workspace.
awk '/^  publish:/{job=1} job && /^        run: \|$/{body=1; next} body{sub(/^          /,""); print}' \
  "$root/.github/workflows/check-and-release.yml" > "$fixture/publish.sh"
cat > "$fixture/bin/gh" <<'GH'
#!/bin/sh
set -eu
case "$1 $2" in
  'auth setup-git') ;;
  'release view') cat "$GH_FIXTURE" ;;
  'release create')
    test ! -e "$GH_FIXTURE.block"
    test "$3" = "$TAG"
    test "$7" = --target && test "$8" = "$GITHUB_SHA"
    printf '%s\n' "$TAG" > "$GH_FIXTURE"
    ;;
  *) exit 2 ;;
esac
GH
chmod +x "$fixture/bin/gh"
export PATH="$fixture/bin:$PATH"
publish() {
  RUNNER_TEMP=$(mktemp -d "$fixture/run.XXXXXX") bash "$fixture/publish.sh"
}
ref="refs/tags/$TAG"
remote="$fixture/fixture/kakunou.git"
# A successful tag push followed by interrupted release creation must recover.
touch "$GH_FIXTURE.block"
if publish; then exit 1; fi
original=$(git --git-dir="$remote" rev-parse "$ref")
[[ $(git --git-dir="$remote" rev-parse "$ref^{commit}") == "$GITHUB_SHA" ]]
[[ $(git --git-dir="$remote" cat-file -t "$ref") == tag ]]
rm "$GH_FIXTURE.block"
publish
[[ $(cat "$GH_FIXTURE") == "$TAG" ]]
publish
[[ $(git --git-dir="$remote" rev-parse "$ref") == "$original" ]]
[[ $("$fixture/version" verify "$base") == "$TAG" ]]

# A matching commit with a foreign annotation and a lightweight tag at another
# commit must both fail closed, even when a release already exists.
git --git-dir="$remote" tag -f -a "$TAG" -m 'foreign annotation' "$GITHUB_SHA"
if publish; then exit 1; fi
git --git-dir="$remote" tag -f "$TAG" "$base"
if publish; then exit 1; fi
[[ $(git --git-dir="$remote" rev-parse "$ref") == "$base" ]]
[[ $(git --git-dir="$remote" rev-parse refs/heads/main) == "$GITHUB_SHA" ]]

# A documentation-only PR works while the previous release is pending,
# independently of which tag objects the local checkout happens to have.
git switch -qc docs
git commit --allow-empty -qm 'docs: update guide'
[[ -z $("$fixture/version" prepare) ]]
git switch -q preview
git merge --no-ff -qm 'Merge pull request' docs
[[ -z $("$fixture/version" verify "$GITHUB_SHA") ]]
if "$fixture/version" verify "$base"; then exit 1; fi
