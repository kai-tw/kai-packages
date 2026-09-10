# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What this repo is

`kai-packages` — Dart and Flutter code shared across Kai's apps (NovelGlide,
CherishCRM, …), as a [pub workspace](https://dart.dev/tools/pub/workspaces):
one lockfile, one CI run, so two packages here can never disagree about a
dependency version. Renamed from `dart-packages` once it stopped being
exclusively pure-Dart packages — `connectivity_status` is a real federated
Flutter plugin with native iOS/Android code, not just Dart.

## This repo is PUBLIC; the apps that consume it are not

`kai-packages` and `claude-plugins` are public. Every consuming app is private.
So everything written here is written for strangers — and the surfaces that are
hardest to take back are the ones that feel like conversation: **commit
messages, PR titles and PR bodies**, alongside `CHANGELOG.md`, `README.md`, doc
comments, and the example code inside them.

The app names themselves are not the problem — this file names both of them
above, deliberately, because the org-identifier history cannot be told without
them. What must not cross over is what is *inside* those repos:

- class, widget and file names lifted from an app (a README example reading
  `SyncStatusSection(state: SyncStatusFailed())` is that app's private API);
- UI copy, screen structure, feature names, internal ruling numbers;
- links to private-repo issues or PRs, which a public reader cannot open anyway
  and which only advertise what exists.

Write "a consuming app" or "two apps in this house", and invent neutral names
for examples.

**The trap is extraction.** When a package is pulled OUT of an app, the honest
motivation *is* that app — which is precisely when a commit message reaches for
its name, its widgets and its copy. Pause at that sentence and generalise it.

**Retracting is worse than it looks**, which is why the pause is worth more than
the cleanup. A `--force-with-lease` rewrite leaves the old commit object
reachable by SHA until GitHub garbage-collects it, on no guaranteed schedule;
the PR timeline keeps a force-push event naming that SHA; GitHub retains an edit
history for a PR body; and notification emails already went out with the
original text. Closing the PR and pushing a fresh branch is the only cheap move
that removes the ref, and even that does not remove the object.

## Org identifier: `net.kaiwu`, not `com.kai_wu`

**`net.kaiwu` is the current org identifier for anything with an Android
namespace/applicationId or an iOS bundle identifier in this repo — a
package's native code, and any app consuming one.** This is a standing rule,
confirmed against CherishCRM-Flutter's own `net.kaiwu.cherishcrm` (both its
Android `namespace`/`applicationId` and its iOS `PRODUCT_BUNDLE_IDENTIFIER`).

`com.kai_wu` is legacy — NovelGlide's own naming (`com.kai_wu.novelglide`),
never a house standard. It should not be copied into new native code just
because it is what an extraction's source app happened to use.

This has no Dart-side equivalent to enforce automatically (Dart package
names and pub.dev don't have an org-identifier concept), so it is a
convention to apply by hand whenever a package in this repo grows Android or
iOS native code — `connectivity_status` is the only one that has, so far.
