#!/bin/sh
# Publishes a release of this app: checks that main is clean and pushed, then pushes the tag v<VERSION>.
# GitHub does the rest (.github/workflows/release.yml): it builds the app, signs it with the release
# certificate, signs update.json with the update key, publishes the release and updates the app's cask.
# One release per version: change VERSION first. Only Z (AA.Y.Z) is this repository's own; a change of
# AA.Y is made in the suite repository, which brings every app to it (sync-version.yml).
set -eu
cd "$(dirname "$0")/.."
REPO="$(git config --get remote.origin.url 2>/dev/null \
    | sed -nE 's#^(https://github\.com/|git@github\.com:)([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')"
[ -n "$REPO" ] || { echo "No repository: origin isn't a GitHub repository."; exit 1; }
[ -s Support/update-public-key.txt ] || { echo "No update key yet: see the suite repository's scripts/update-key.sh"; exit 1; }
[ -s Support/release-certificate.cer ] || { echo "No release certificate yet: see the suite repository's scripts/release-certificate.sh"; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "Publish from main."; exit 1; }
git diff --quiet HEAD || { echo "Commit your changes first: a release must match a commit."; exit 1; }
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse '@{upstream}' 2>/dev/null)" ] \
    || { echo "Push this commit first: GitHub builds what it has."; exit 1; }
TAG="v$(cat VERSION)"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "$TAG already exists: change VERSION first."; exit 1
fi
git tag "$TAG"
git push -q origin "refs/tags/$TAG"
echo "Pushed $TAG: GitHub builds and publishes it. Follow it with: gh run list --repo $REPO --workflow release.yml"
