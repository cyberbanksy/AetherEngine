#!/bin/bash
# Keep the DVD-menu fork current with upstream AetherEngine (docs/dvd-menus.md, "Staying in sync").
#
#   Scripts/sync-upstream.sh                 # rebase onto the newest upstream release tag, as a NEW branch
#   Scripts/sync-upstream.sh 7.9.0           # ... onto a specific tag
#   Scripts/sync-upstream.sh 7.9.0 --in-place --push
#
# What it does:
#   1. fetches `upstream` (github.com/superuser404notfound/AetherEngine) with tags;
#   2. replays the fork's commits (everything on BRANCH since its merge-base with TAG) onto TAG:
#        default     -> new branch `dvd-menus-on-<TAG>` (BRANCH itself untouched, so the version a host pins
#                       keeps building while the rebased one is verified)
#        --in-place  -> rebases BRANCH itself;
#   3. runs `swift build` + the DVD menu tests (or the whole suite with --full-tests) with a separate
#      scratch path, under the Mac's build lock when it exists;
#   4. with --push, pushes the result to `origin` (the fork) using --force-with-lease.
# On a rebase conflict it aborts the rebase, lists the conflicting files and exits 2: resolve by hand
# (`git rebase --onto <TAG> <base> <branch>`), the DVD code lives in its own files so conflicts should
# be limited to Package.swift / .gitignore / docs.
set -euo pipefail
cd "$(dirname "$0")/.."

BRANCH=${BRANCH:-dvd-menus}
UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/superuser404notfound/AetherEngine.git}
SCRATCH=${SCRATCH:-$HOME/Developer/openstream-build/aether-fork-spm}
LOCK=$HOME/Developer/openstream-build/bin/buildlock.sh
TAG="" ; IN_PLACE=0 ; PUSH=0 ; FULL=0
for a in "$@"; do
  case "$a" in
    --in-place) IN_PLACE=1 ;;
    --push) PUSH=1 ;;
    --full-tests) FULL=1 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) TAG=$a ;;
  esac
done

[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "working tree has changes; commit or stash first" >&2; exit 1; }
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
git fetch --quiet upstream --tags
git fetch --quiet origin || true

if [ -z "$TAG" ]; then
  TAG=$(git tag --list '[0-9]*.[0-9]*.[0-9]*' --merged upstream/main | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "unknown tag $TAG" >&2; exit 1; }

BASE=$(git merge-base "$BRANCH" "$TAG")
OLD_TAG=$(git describe --tags --abbrev=0 "$BASE" 2>/dev/null || echo "$BASE")
COUNT=$(git rev-list --count "$BASE..$BRANCH")
echo "replaying $COUNT commit(s) of $BRANCH (based on $OLD_TAG) onto $TAG"

if [ $IN_PLACE = 1 ]; then TARGET=$BRANCH; else TARGET="$BRANCH-on-$TAG"; git branch -f "$TARGET" "$BRANCH"; fi
git checkout --quiet "$TARGET"
if ! git rebase --quiet --onto "$TAG" "$BASE" "$TARGET"; then
  echo "rebase conflict in:" >&2
  git diff --name-only --diff-filter=U >&2
  git rebase --abort
  exit 2
fi

run() { if [ -x "$LOCK" ]; then "$LOCK" "$@"; else "$@"; fi; }
run swift build --scratch-path "$SCRATCH"
if [ $FULL = 1 ]; then
  run swift test --scratch-path "$SCRATCH"
else
  run swift test --scratch-path "$SCRATCH" --filter 'DVDCommandDecodingTests|DVDVirtualMachineTests|DVDNavPackTests|DVDMenuFixtureTests|DVDIFOParserTests|DiscReaderTests'
fi

if [ $PUSH = 1 ]; then
  git push --force-with-lease origin "$TARGET"
fi
echo "ok: $TARGET is $COUNT commit(s) on top of $TAG"
