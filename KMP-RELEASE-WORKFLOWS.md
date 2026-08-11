# Shared CI/CD workflows for Kotlin Multiplatform libraries

This repo hosts **reusable GitHub Actions workflows** (`workflow_call`) used by every Infomaniak Kotlin Multiplatform (KMP) library repo (e.g. `multiplatform-calendar`, `multiplatform-authenticator`, `multiplatform-SwissTransfer`, and any future one) to avoid duplicating the same CI/CD logic in each repo.

Each project repo only keeps small **wrapper workflows** that declare the actual triggers (`pull_request`, `workflow_dispatch`, ...) and call the shared workflows below with repo-specific inputs (Gradle module names, task names, Rust targets, etc.).

## Available reusable workflows

| Workflow | Purpose |
|---|---|
| `.github/workflows/kmp-pr-build-check.yml` | On every PR push: builds and runs Android + iOS (simulator only, no macOS/iOS-device build) unit tests. |
| `.github/workflows/kmp-build-xcframework.yml` | Builds, strips and zips a single XCFramework; uploads it as a `xcframework-<name>` artifact. Called once per XCFramework (directly, or via a matrix for repos shipping several). |
| `.github/workflows/kmp-publish-reposilite-snapshot.yml` | Publishes the Android artifact(s) to Reposilite Snapshots. |
| `.github/workflows/kmp-publish-reposilite-release.yml` | Publishes the Android artifact(s) to Reposilite (real release, checked out at the release tag). |
| `.github/workflows/kmp-release-library.yml` | End-to-end release orchestrator: resolves the version, builds every XCFramework, updates `Package.swift`, opens a draft GitHub Release + a `release/<version>` branch/PR, and publishes an Android snapshot for validation. |
| `.github/workflows/kmp-publish-on-release-merge.yml` | Called from the repo's `publish-release-on-merged.yml` wrapper when a `release/<version>` PR is merged: undrafts the GitHub Release, publishes to Reposilite, notifies KChat. |
| `.github/workflows/kmp-publish-ios-snapshot.yml` | Ad-hoc, manually triggered iOS snapshot: builds the XCFramework(s), publishes a prerelease + a `spm-ios-snapshot-*` branch for early SPM testing. |
| `.github/workflows/kmp-cleanup-ios-snapshots.yml` | Scheduled (weekly) purge of iOS (GitHub prereleases/tags/branches) snapshots older than a configurable number of days. |
| `.github/workflows/cleanup-reposilite-snapshots.yml` | Scheduled (weekly) purge of Android/Maven snapshots older than a configurable number of days from a Reposilite `snapshots` repository. Not KMP-specific — also used by Android-only projects (e.g. `android-design-system`). |
| `.github/workflows/resolve-next-library-version.yml` | (Pre-existing) Resolves the version to release, explicit or auto-bumped. |

All of them assume the consuming library: is a Gradle Kotlin Multiplatform project targeting Android + Apple (iOS/macOS); publishes Android artifacts to our self-hosted Reposilite instance via the standard `maven-publish` plugin (a `maven { name = "reposilite" ... }` repository, see `PublishPlugin.kt`) with a `-P<version-property>=<version>` Gradle property (default `core.version`); publishes iOS/macOS binaries as XCFramework(s) referenced from a `Package.swift` (SPM), one `.binaryTarget` per XCFramework, url/checksum kept in sync automatically.

If a future project doesn't fit one of these assumptions (e.g. no SPM distribution), either adapt its wrapper workflow inputs or extend the reusable workflow with a new input — avoid forking it.

## Onboarding a new (4th) project

1. Make sure Gradle publishing is wired: a "publish" convention plugin applying `maven-publish` and declaring the `reposilite` Maven repository, setting `group`/`version` from a Gradle property (see `PublishPlugin.kt` in calendar, authenticator or swisstransfer for a template). Do NOT apply `com.gradleup.nmcp` (Maven Central publishing) — that plugin/dependency has been removed in favor of publishing directly to Reposilite via `./gradlew publishAllPublicationToReposiliteRepository` (only publishes to the `reposilite` Maven repository, unlike the broader `publish` task).
2. Make sure the module(s) building XCFrameworks expose one `.xcframework` per Apple binary you want to ship (`project.XCFramework("<Name>")`), and add a matching `.binaryTarget` entry in `Package.swift` (initial URL/checksum can be dummy values — the first release will overwrite them).
3. Copy the wrapper workflows from `multiplatform-authenticator/.github/workflows/` or `multiplatform-SwissTransfer/.github/workflows/` into the new repo:
   - `pr-build-check.yml` (calls `kmp-pr-build-check.yml`)
   - `release-library.yml` (calls `kmp-release-library.yml`, `workflow_dispatch` trigger)
   - `publish-release-on-merged.yml` (calls `kmp-publish-on-release-merge.yml`, `pull_request: closed` trigger)
   - `publish-to-reposilite-snapshots.yml` (calls `kmp-publish-reposilite-snapshot.yml`, `workflow_dispatch` trigger)
   - `publish-to-reposilite.yml` (calls `kmp-publish-reposilite-release.yml`, `workflow_dispatch` trigger with the release acknowledgement)
   - `publish-ios-snapshot.yml` (calls `kmp-publish-ios-snapshot.yml`, `workflow_dispatch` trigger)
   - `cleanup-snapshots.yml` (calls both `kmp-cleanup-ios-snapshots.yml` and `cleanup-reposilite-snapshots.yml`, weekly `schedule` + `workflow_dispatch` trigger)
4. Adjust the `with:` inputs for each wrapper: the `xcframeworks` JSON array (name / module / Gradle task per XCFramework), `rust-targets` (leave empty if the project has no Rust/UniFFI bridge module), Gradle task names, the KChat message pieces, and `maven-group-path`.
5. Make sure the repo has the required secrets available (organization- or repo-level): `REPOSILITE_USERNAME`, `REPOSILITE_PASSWORD`, `GPG_KEY_ID`, `GPG_PRIVATE_KEY`, `GPG_PRIVATE_PASSWORD`, `BOT_MOBILE_GPG_PRIVATE_KEY`, `BOT_MOBILE_GPG_PASSPHRASE`, and optionally `KCHAT_KMP_WEBHOOK_URL`.
