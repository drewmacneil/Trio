---
name: trio-build
description: Build, test, capture screenshots, and dispatch CI for Trio using the workspace and optional helper scripts. For the fork branch model, upstream sync, the test gate before TestFlight, and public-repo hygiene, use trio-fork-workflow.
---

# Trio build

Branch model, upstream sync, the test gate before a TestFlight build, and public-repo hygiene are in `.cursor/skills/trio-fork-workflow/SKILL.md`.

If the `TRIO_CI_SCRIPTS` environment variable is set, use the scripts in that directory instead of inventing `xcodebuild` or workflow-dispatch commands:

- `build-test.sh` for tests
- `capture.sh` for simulator screenshots
- `dispatch-build.sh` to start a CI build

## Rules

- Always run `xcodebuild -workspace Trio.xcworkspace`. Never use `-project Trio.xcodeproj`.
- Tests use the `Trio Tests` scheme. The app uses the `Trio` scheme.
- Never pipe `xcodebuild` through a truncating filter (for example `head`). Write a full log and keep the real exit code.
- Never search for credentials. If `dispatch-build.sh` cannot read its token file, ask the human. Do not scan process lists, environment variables, or directories for secrets.
- Fresh captures only. Do not overwrite an existing PNG, and do not copy an old screenshot to a new name.
- Keep fixture JSON out of the repository.
- Do not leave `Package.resolved` dirty. The helper scripts restore it after a build or test.
- A fresh git worktree does not check out submodules. Run `git submodule update --init --recursive` in that worktree before `build-test.sh`. The workspace package `RoundWhiteDiscKit` is one of those checkouts.
- If a permission or critical-alert dialog covers the screen in screenshot mode, fix it with a DEBUG-only guard in the app's screenshot host. Do not drive the simulator with HID or other UI automation to dismiss the dialog.
