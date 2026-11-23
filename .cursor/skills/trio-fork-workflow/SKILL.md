---
name: trio-fork-workflow
description: Work in the public drewmacneil/Trio fork with no prior chat context. Use when branching, syncing nightscout/Trio, resolving upstream conflicts, running the local test gate, dispatching Build Trio, checking a GitHub Actions run, opening or merging a pull request, or pushing. Covers the dev branch model, conflict handling, the test gate before TestFlight, dispatch usage, and public-repo hygiene.
---

# Trio fork workflow

Use this skill at the start of a session on this fork. Mechanical build, test, screenshot, and signing rules live in `.cursor/skills/trio-build/SKILL.md`. Do not invent `xcodebuild` or workflow-dispatch commands when the shared scripts apply.

## Branch model

`dev` is this fork's default branch (`origin/HEAD` is `origin/dev`). Upstream is `nightscout/Trio`, which also uses `dev`. Do feature work on a branch off `dev`.

`.github/workflows/build_trio.yml` (Build Trio) sets both `TARGET_BRANCH` and `UPSTREAM_BRANCH` to `github.ref_name`. When the repository owner is not `nightscout` and the `SCHEDULED_SYNC` variable is not `false`, the workflow runs `aormsby/Fork-Sync-With-Upstream-action` before certificates and the archive.

- A Build Trio run on `dev` syncs this fork's `dev` with `nightscout/Trio` `dev` first. A clean sync can push new upstream commits to `dev`. A conflict fails the run and does not build or upload to TestFlight. The scheduled run also fires on `dev`.
- A feature-branch build does not sync upstream `dev`. The same step still runs, but it looks for an upstream branch of the same name. Those names are not on `nightscout/Trio`, so the step reports no new commits and the archive is built from the feature-branch tip. Observed on `cursor/health-uploader-ea73` runs: the sync step finished in the same second and "No new commits" succeeded. Do not dispatch a feature branch in order to update `dev`.

## Upstream-sync conflicts

When a `dev` sync conflicts, resolve it in a pull request. Do not retry the failing dispatch and expect the conflict to clear.

1. Fetch `origin` and `upstream` (`nightscout/Trio`).
2. Branch from current `origin/dev` and merge `upstream/dev`.
3. When the resolution is clear, prefer upstream structure and keep fork-only steps and features. A conflict on a value the fork deliberately set is not a clear "take upstream" case. That includes the toolchain or Xcode version, the runner label, and fork-only steps or settings. Keep the fork's value when it is known to work. Adopt upstream's value only when there is a clear reason, such as upstream code that requires it. If unsure, flag it to the repository owner. Do not switch it silently.

   Merge `38d943997` ("Merge upstream nightscout/Trio dev into the fork", November 2026) is the structural precedent and the toolchain counterexample. Keep the fork's pre-archive test step in `build_trio.yml`, and take upstream's synchronized Xcode project so fork sources stay members of the Trio and TrioTests folders. In that sync the Xcode path was switched from the fork's working 27.2 (`/Applications/Xcode_27.2.app`) to upstream's 27.0 (`/Applications/Xcode_27.0.app`). That path should have been kept, or flagged to the owner. The failed sync just before that merge conflicted in `.github/workflows/build_trio.yml` and `Trio.xcodeproj/project.pbxproj`.

   The Build Trio runner split is fork-pinned and must be kept through upstream syncs, the same way as the toolchain and other fork-only settings above. Hosted `xcode-27` runners are scarce. Only the archive job may use that label:

   - In `.github/workflows/build_trio.yml`, `build` (Build) stays on `xcode-27` and keeps its current Xcode selection (`/Applications/Xcode_27.0.app`). Do not change that runner or that selection unless the owner asks.
   - `check_status` (Check status) and `cancel_when_no_build` (Cancel run when there is nothing to build) in `build_trio.yml`, and `validate-access-token` (Access) in `.github/workflows/validate_secrets.yml`, stay on `ubuntu-26.04`. They do not need macOS or Xcode.
   - `validate-fastlane-secrets` (Fastlane) in `validate_secrets.yml`, and `create_certs` (Certificates) and `nuke_certs` (Nuke certificates) in `.github/workflows/create_certs.yml`, stay on `macos-26`. They need macOS for Fastlane Match, the keychain, and `sntp`. They do not select an Xcode. The stock toolchain on `macos-26` is enough.
   - Upstream commit `c4da92f55` moved this whole macOS set onto `xcode-27`. On the next sync, keep this split. Do not put Fastlane validation, certificates, or nuke certificates back on `xcode-27`.
4. Stop and ask when the choice is genuinely ambiguous: two fork-only behaviors collide, a deliberate fork value (toolchain, runner label, or fork-only setting) is in conflict and it is unclear whether to keep it, or it is unclear which fork behavior must survive. Do not guess.
5. Run the full local test gate below.
6. Scan the diff (see hygiene), push, and open a pull request into `dev`.
7. Merge that pull request with a merge commit so both parents stay and upstream history is kept. Do not squash and do not rebase the sync.

## Test gate

Run the full local gate before any CI TestFlight build, and before merging an upstream-sync pull request:

```sh
"$TRIO_CI_SCRIPTS/build-test.sh"
```

On this worker `TRIO_CI_SCRIPTS` is `/Users/Shared/trio-ci-scripts`. Run it from a checkout of this repo (the script walks up to `Trio.xcworkspace`). No `-only-testing` argument: that is the full `Trio Tests` scheme. A simulator UDID may be passed as the first argument; anything after that is forwarded to `xcodebuild`.

Plan on about 25–30 minutes. One full run on this machine, with no filter, finished in about 27 minutes (1172 tests, `TEST SUCCEEDED`). The script prints a short summary and the log path, restores every tracked `Package.resolved`, and does not need its output piped through `head` or `tail`.

This machine's selected Xcode is 26.3 (`/Applications/Xcode-26.3.0.app`). Build Trio's archive job on CI runs on the `xcode-27` runner and selects `/Applications/Xcode_27.0.app`. The other jobs in that workflow, and in the reusable workflows it calls, use `ubuntu-26.04` or `macos-26` and do not select an Xcode. That runner split is fork-pinned; see Upstream-sync conflicts. A green local run does not prove the CI compile. The workflow's own pre-archive step tests only `TrioTests/HealthIngestTests` and `TrioTests/LiveActivityChartTests`. That step does not replace the local full gate.

## Pull requests

Feature-branch pull requests are not merged to `dev` without the repository owner's explicit approval in the current session. Upstream-sync pull requests are the exception in the section above: merge those with a merge commit once the resolution is clear and the full test gate has passed.

A docs-only change does not need `build-test.sh`. Do not dispatch a TestFlight build for a docs-only change.

## Dispatching builds

Dispatch only after the commit is on `origin` and the full local test gate for that commit has passed:

```sh
"$TRIO_CI_SCRIPTS/dispatch-build.sh" <branch>
```

Run it from this checkout. It refuses to start unless `git rev-parse HEAD` equals `git ls-remote` for `origin/<branch>`. On success it prints `run_id` and `html_url` for the new `workflow_dispatch` of `build_trio.yml`.

The script reads its own credential from outside the repo and outside `/Users/Shared/trio-ci-scripts`. Do not read, print, or quote that credential or the contents of its file. Do not search the process list, environment, shell history, keychain, or home directory for it. If the script cannot read its credential, ask the human.

Check run status with the public API and no credentials. Unauthenticated `GET` returns 200 for this public repository:

```sh
curl -sS -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/drewmacneil/Trio/actions/runs/<run_id>"

curl -sS -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/drewmacneil/Trio/actions/workflows/build_trio.yml/runs?per_page=10"
```

Do not send an `Authorization` header for these reads. Useful fields are `status`, `conclusion`, `head_branch`, `head_sha`, `html_url`, and `event`.

## Public-repo hygiene

This fork is public. Never commit personal details:

- street or mailing addresses
- tailnet hostnames
- tokens, keys, passwords, or credential file paths
- email addresses
- health-server URLs
- home-directory paths or other machine-personal paths

Use generic wording in commits, pull requests, and skills. Keep fixture JSON and personal screenshots out of the repository (`trio-build`).

Before every push, read the full diff being pushed (`git diff`, `git diff --cached`, and `git log`/`git show` for the new commits). Confirm none of the items above appear, including in skill text and commit messages.

## Health ingest

The upload JSON contract is `HealthIngestWire` in `Trio/Sources/HealthIngest/HealthIngestWireFormat.swift`.

HealthKit samples may send optional fields beside `payload`: `sourceName`, `sourceBundleIdentifier`, `deviceName`, `deviceModel`, and `deviceManufacturer`. They come from `HKSample.sourceRevision.source` and `HKSample.device`. Omit a missing device and omit any value that is empty, longer than 256 UTF-16 code units, or contains a Unicode control character. Do not trim or truncate. `payload.source` stays `healthkit`. Trio's own records, including Trio glucose, insulin, carbs, and loop cycles, do not send these fields. The uploader does not read HealthKit glucose.

`HealthIngestWire.mappingVersion` is the switch that re-reads stored HealthKit history through the existing paged backfill (same page size, batch limits, and backlog pause). The local receipt hash includes the source fields, so an unchanged payload is still sent again with the same `(type, id)`.

## Sessions

Start a new agent session for each piece of work. Do not carry assumptions from an earlier chat. If something required to work in this repo is missing here, verify it and update this skill in that same change.
