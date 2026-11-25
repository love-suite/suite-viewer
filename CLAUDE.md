# Viewer: project brief

Viewer (`local.suite.viewer`) is the picture and PDF viewer of Love Suite, an app of its own.
Explorer and Desktop hand it pictures and PDFs (`SuiteFilesUI`'s `ViewerHandoff`; pictures unless turned
off in Explorer's settings; without Viewer they open in the system's app).

## Architecture

```
ViewerCore (library, no UI, unit-tested) the pictures of a folder in Explorer's order (SuiteFilesCore's
           FolderViewStore and FileSorter), the sequence the arrows go through
ViewerUI   (library, AppKit) the picture and PDF viewer windows and Viewer's menu
Viewer     (Viewer.app)
```

`SuiteCore` (repository `suite-core`) brings what Viewer shares with every app: `ViewerApp` (its
bundle id and which files it shows, as Explorer sees it) and the updater (`SuiteUpdater`). `suite-files`
brings how folders are sorted, `SuiteTrash` (moving to the Trash with the record Explorer's Undo and
Restore read) and Finder's sounds.

## What Viewer does today

- **Viewer** (`Sources/Viewer`, bundle id `local.suite.viewer`): the picture viewer as an
  app of its own; Explorer and Desktop hand pictures to it (can be turned off): opens fitted to the window, arrows
  through the folder, zoom, full screen, Trash (Explorer's Undo puts it back), Open in Preview for the rest.

## Work to do

- `feat/viewer-edit` (moved here with its history, written before the viewer left `ExplorerUI`, so its
  files are still under `Sources/ExplorerUI` and it doesn't build here as it is): text recognition, editing
  that stays editable (history, shapes moved again, simple layers, kept apart from the picture, which stays
  a plain file), rotate and fit below the toolbar. Merging it is real work. Then slideshow, information,
  videos; PDFs are partly done.

## Building and running

- `swift build` and `swift test` for development.
- `scripts/make-app.sh` builds `build/Viewer.app` (release), signs it with the "Suite Local Signing"
  certificate from the login keychain, so macOS permissions survive rebuilds (ad-hoc signing, the
  fallback, re-asks every build), and installs it as `~/Applications/Viewer.app`, the only copy Launch
  Services knows. It records the branch and commit in the Info.plist (`SuiteBuildBranch`,
  `SuiteBuildCommit`) and refuses to replace an installed copy built from another branch, or from an unknown
  one, unless `--force`: another session may be testing it. `INSTALL_DIR=` builds without installing. A
  running copy is relaunched from the new one.
- Never ask the user to open `build/Viewer.app` from a worktree.
- UI can't be checked by unit tests and screenshots of the user's screen are not available: check UI by
  rendering views offscreen (`cacheDisplay`) from a scratch package that compiles the sources.
- Releases: change `VERSION` (only `Z` is this repository's own), commit, push, then `scripts/publish.sh`
  pushes the tag; `.github/workflows/release.yml` builds, signs the app with "Suite Release Signing",
  signs `update.json` with the update key (both from the repository's `release` environment secrets),
  publishes the release and updates the cask in `love-suite/homebrew-tap`. The feed is
  `https://github.com/love-suite/suite-viewer/releases/latest/download/update.json`
  (the GitHub repository it is built from). A change of `AA.Y` comes from the suite repository through
  `.github/workflows/sync-version.yml`. Until `Support/release-certificate.cer` and
  `Support/update-public-key.txt` exist, nothing can be released.

## The suite

This repository is part of Love Suite, one repository per app under `github.com/love-suite`:
`suite-core` (the shared library), `suite-files` (the file layer of the apps handling files),
`suite-guard`, `suite-desktop` (the desktop), `suite-explorer`, `suite-bar` (the Dock), `suite-viewer`,
`suite-clipboard`, `suite-settings` (the settings), `suite-awake` (keeping the Mac awake), `suite-launcher`, `suite-bindings`,
`suite-ai-organizer`; `homebrew-tap` (the tap `love-suite/tap`, one cask per app) and `suite` (the
front page, the suite's version, the scripts that act on every repository). Locally they sit side by side
in `~/GitHub/paul-amour/suite/`.

## Conventions (the same in every repository of the suite)

- The user writes in French and expects answers in French; everything in the code stays in English: code,
  comments, tests, docs, commit messages. Do not add co-author trailers.
- No "…" in menu items, buttons or messages: the user wants none, anywhere.
- Behaviour follows Windows unless Apple's design is asked for.
- Swift Package Manager, `swift-tools-version:5.9`, macOS 13+. Tests use Swift Testing (`import Testing`).
- Toolchain: swiftly, Swift 6.4.2 (`.swift-version`, git-ignored). If `swift test` complains about a
  missing toolchain: `swiftly use 6.4.2`.
- AppKit for windows that need fine control; SwiftUI is allowed for small panels (settings, pickers).
- No private APIs and no system modifications (SIP stays on).
- Git: one worktree per feature under `.worktrees/` (git-ignored), one branch per change
  (`feat/<feature>`, `fix/<area>/<what>`), merged into `main` one by one; `main` stays stable.
- Versions are `AA.Y`, then `AA.Y.Z` for a fix (`VERSION`, tag `vVERSION`: 27.1, then 27.1.1; SwiftPM reads
  `v27.1` as 27.1.0): `AA` is the latest macOS in production (27), `AA.Y` is the same in every repository of
  the suite so the apps work together, `Z` is this repository's own. A change of `AA.Y` is made in `suite`
  and reaches every repository. While a version is being prepared, `VERSION` doesn't move (27.1 now):
  development builds are `VERSION-dev.N`, N the commits since `VERSION` was set, merges aside, from 1 (`make-app.sh`),
  and a change another repository needs gets a development tag, `vVERSION-dev.N`, which releases nothing.
  Dependencies on other repositories of the suite (`suite-core`, `suite-files`, `suite-guard`, settings
  libraries) use
  `.upToNextMinor(from: "27.1.0-dev.1")` (the latest development tag, then the release);
  `Package.resolved` is committed. Tags are never moved once pushed. The build number (`CFBundleVersion`,
  which the updater compares) stays the number of commits.
- Changing two repositories at once: `swift package edit <Package> --path ../<repository>` points at the
  neighbour's working copy until its tag exists, `swift package unedit` goes back. Never committed.
- What two apps need lives in `suite-core` (file code in `suite-files`); an app's own code never goes into another app's repository, and
  an app exposes only its settings, as `<App>Settings`, for Suite Settings.
- Do not run commands that delete user data. Trash instead of delete.
- No code converting saved settings at launch. Before the first release nothing needs converting (the
  developer's own settings don't count): rename freely. Between released versions, a change to saved
  settings is a `SettingsMigration` (suite-core) for the version that brought it, given to the app's
  `SuiteUpdater`, which runs it once after the update.
