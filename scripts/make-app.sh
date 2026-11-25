#!/bin/sh
# Builds build/Viewer.app, without Xcode, signs it and installs it in ~/Applications.
#   scripts/make-app.sh [--force]
# An installed copy built from another branch (another worktree) is never replaced without --force.
# INSTALL_DIR= (empty) builds only; INSTALL_DIR=<folder> installs there instead of ~/Applications.
set -eu
cd "$(dirname "$0")/.."

APP_NAME="Viewer"
EXECUTABLE="Viewer"
EXTRA_PRODUCTS=""
BUNDLE_ID="local.suite.viewer"
INFO_PLIST="Support/Viewer-Info.plist"
# The viewer stands in for Preview, so it wears Preview's icon, taken from this Mac, never committed.
ICON="/System/Applications/Preview.app/Contents/Resources/AppIcon.icns"

# before_build: what runs before building. add_to_bundle <app>: what this app adds to its bundle
# (resources, embedded helpers) before it is signed. relaunch: how a running copy starts again.
# SwiftPM records the deployment target (macOS 13) as the SDK an executable was built with, and macOS then
# draws its windows as for an app of that time (the old controls). The SDK actually used is recorded instead,
# so the app looks as the latest macOS does.
stamp_sdk() {
    vtool -set-build-version macos 13.0 "$(xcrun --show-sdk-version)" -replace -output "$1" "$1"
}
before_build() { :; }
make_icon() { cp "$ICON" "$1"; }
relaunch() {
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    TRIES=0
    while pgrep -f "^$INSTALLED/Contents/MacOS/" >/dev/null 2>&1 && [ "$TRIES" -lt 50 ]; do
        sleep 0.2; TRIES=$((TRIES + 1))
    done
    open -g "$INSTALLED"
}
IGNORED_CHANGES=""
# ViewerUI's strings (Bundle.module) need its resource bundle in Resources.
add_to_bundle() {
    cp -r "$PRODUCTS_DIR/Viewer_ViewerUI.bundle" "$1/Contents/Resources/"
}


FORCE=0
for ARG in "$@"; do
    case "$ARG" in
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument \"$ARG\"."; exit 1 ;;
    esac
done

# Where this build comes from, recorded in the Info.plist (SuiteBuildBranch, SuiteBuildCommit) so a later
# install from another worktree can tell whose build it would replace.
BRANCH="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -n "$BRANCH" ] || BRANCH="detached at $COMMIT"
git diff --quiet HEAD -- . $IGNORED_CHANGES 2>/dev/null || COMMIT="$COMMIT with uncommitted changes"

INSTALL_DIR="${INSTALL_DIR-$HOME/Applications}"
INSTALLED="$INSTALL_DIR/$APP_NAME.app"

# Checked before building, so a refused install costs nothing.
if [ -n "$INSTALL_DIR" ] && [ "$FORCE" = 0 ] && [ -f "$INSTALLED/Contents/Info.plist" ]; then
    THEIRS="$(/usr/libexec/PlistBuddy -c "Print :SuiteBuildBranch" "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)"
    THEIR_COMMIT="$(/usr/libexec/PlistBuddy -c "Print :SuiteBuildCommit" "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)"
    if [ -z "$THEIRS" ] || [ "$THEIRS" != "$BRANCH" ]; then
        if [ -z "$THEIRS" ]; then
            echo "Refused: $INSTALLED doesn't say which branch built it (a build made with an older make-app.sh);"
        else
            echo "Refused: $INSTALLED was built from branch \"$THEIRS\" ($THEIR_COMMIT);"
        fi
        echo "         this build comes from branch \"$BRANCH\". Another session may be testing it."
        echo "Nothing was built or installed. Pass --force to replace it anyway, or set INSTALL_DIR= to"
        echo "build without installing."
        exit 1
    fi
fi

before_build
for P in $EXECUTABLE $EXTRA_PRODUCTS; do
    swift build -c release --product "$P"
done

# macOS ties folder permissions to the signature. An ad-hoc one changes with every build, so access is
# asked again each time; a certificate keeps it stable. Set SIGN_IDENTITY to use another certificate.
IDENTITY="${SIGN_IDENTITY:-Suite Local Signing}"
if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    # A certificate asked for by name (a release) is never replaced by ad-hoc signing.
    [ -z "${SIGN_IDENTITY:-}" ] || { echo "No \"$IDENTITY\" certificate found."; exit 1; }
    echo "No \"$IDENTITY\" certificate found: ad-hoc signing, so macOS will ask for folder access again."
    IDENTITY=-
fi

VERSION="$(cat VERSION)"
# The build number is the number of commits in this repository, which the updater compares.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
# The version being prepared stays VERSION until it is released: a build of its release tag is VERSION,
# any other a development build of it, VERSION-dev.N, N the commits since VERSION was set (merges
# aside, they bring nothing new), from 1.
if [ "$(git describe --exact-match --tags HEAD 2>/dev/null)" != "v$VERSION" ]; then
    SET="$(git log -1 --format=%H -- VERSION 2>/dev/null)"
    DEV=$(( $(git rev-list --count --no-merges "${SET:-HEAD}..HEAD" 2>/dev/null || echo 0) + 1 ))
    VERSION="$VERSION-dev.$DEV"
fi
UPDATE_KEY="$(cat Support/update-public-key.txt 2>/dev/null || true)"
# Where this app's releases are published: the GitHub repository it is built from (owner/name), so
# moving it or renaming the organization changes nothing here. GitHub's own value in CI, else origin's.
UPDATE_REPO="${GITHUB_REPOSITORY:-$(git config --get remote.origin.url 2>/dev/null \
    | sed -nE 's#^(https://github\.com/|git@github\.com:)([^/]+/[^/]+)$#\2#p' | sed 's/\.git$//')}"
PRODUCTS_DIR=".build/out/Products/Release"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
stamp_sdk "$APP/Contents/MacOS/$EXECUTABLE"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" \
    -c "Add :SuiteBuildBranch string $BRANCH" -c "Add :SuiteBuildCommit string $COMMIT" \
    "$APP/Contents/Info.plist"
if [ -n "$UPDATE_KEY" ]; then
    /usr/libexec/PlistBuddy -c "Add :ExplorerUpdatePublicKey string $UPDATE_KEY" "$APP/Contents/Info.plist"
fi
if [ -n "$UPDATE_REPO" ]; then
    /usr/libexec/PlistBuddy -c "Add :ExplorerUpdateFeed string https://github.com/$UPDATE_REPO/releases/latest/download/update.json" \
        "$APP/Contents/Info.plist"
fi
make_icon "$APP/Contents/Resources/AppIcon.icns"
add_to_bundle "$APP"
# SuiteCore's strings (the updater's dialogs), when the app uses SuiteCore.
[ ! -d "$PRODUCTS_DIR/SuiteCore_SuiteCore.bundle" ] || cp -r "$PRODUCTS_DIR/SuiteCore_SuiteCore.bundle" "$APP/Contents/Resources/"
# The file views' strings, when the app uses suite-files' views.
[ ! -d "$PRODUCTS_DIR/SuiteFiles_SuiteFilesUI.bundle" ] || cp -r "$PRODUCTS_DIR/SuiteFiles_SuiteFilesUI.bundle" "$APP/Contents/Resources/"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"

# One installed copy, always at the same place, whichever worktree built it: the Dock, "Show in Finder"
# and Launch Services then always find the latest build. INSTALL_DIR= (empty) skips this.
[ -n "$INSTALL_DIR" ] || exit 0

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p "$INSTALL_DIR"
RUNNING=0
pgrep -f "^$INSTALLED/Contents/MacOS/" >/dev/null 2>&1 && RUNNING=1
rm -rf "${INSTALLED:?}"
ditto "$APP" "$INSTALLED"
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
"$LSREGISTER" -f "$INSTALLED"
echo "Installed $INSTALLED ($BRANCH, $COMMIT)"

# Running, it starts again from the new copy.
if [ "$RUNNING" = 1 ]; then
    relaunch
    echo "Relaunched $APP_NAME"
fi
