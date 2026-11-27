# Fork of pingdotgg/t3code

A personal build of T3 Code with T3 Connect (Clerk sign-in, relay, hosted web) on our own domain.
It tracks upstream daily. The default branch is `fork`; there is no `main`. The plan and research
notes are kept outside this repo.

**Upstream's workflows stay in the tree but must never run here.** They are left untouched because
upstream's own tests read some of them (`scripts/notify-discord-release.test.ts`,
`scripts/build-desktop-artifact.test.ts`), and because a diff against them shows what upstream
changed. Most of them expect upstream's Blacksmith runners and secrets. Three of them run on a
schedule with no repository guard. One (`thread-transfer-report.yml`) starts whenever a workflow
named "CI" finishes. Actions is off for this repository. Before it is turned on, every workflow not
added by this fork must be disabled. That covers only the workflows that exist at that moment. A
later sync can bring in a new upstream workflow, which GitHub enables as soon as it is pushed, so
the plan must also hold new arrivals back (not designed yet). The fork's own workflows are named
`fork-*.yml`, and none of them is called "CI".

`fork/sync.sh` lists the upstream workflow files that changed since the previous sync, so CI or
release changes worth copying are not missed. Copy the commands they run, not the YAML.

## How the branch is built

`fork` is never rebased. Each sync rebuilds it from scratch (`fork/sync.sh`):

1. Start from upstream's latest `main`.
2. **Overlay commit:** copy `fork/` from the previous tip. Upstream never has this directory, so
   the commit can't conflict.
3. **Generated commit:** `node fork/apply.ts` writes `fork/identity.json` into upstream's files.

`fork/apply.ts` asserts every upstream string it replaces. It stages all edits in memory and writes
nothing unless every anchor matched. If one is missing, the sync fails and `fork/sync.sh` puts the
branch back on its previous tip. To fix it, update the anchor in `fork/apply.ts` and rerun
`bash fork/sync.sh --force`. Then run `vp run check:changed <upstream sha>` before pushing.

To change fork values, edit `fork/identity.json` (or `fork/apply.ts`) on `fork` and commit. Don't
hand-edit upstream files: the next sync throws those edits away.

## Code changes: patches

Values go in `fork/identity.json` and `fork/apply.ts`. A change to upstream's logic is a patch: one
commit, kept as a file in `fork/patches/` and listed, in order, in `fork/patches/.patches`. Each
sync applies the listed patches between the overlay commit and the generated commit (so
`apply.ts` sees the patched text), strictly: no 3-way merge and no fuzz. A patch whose context
changed upstream stops the sync with `fork/patches.sh: patch <name> no longer applies`, and nothing
is built.

Each patch commit's message has:

- a subject that says what it does;
- `Intent:` what it is for, in a sentence someone can check against a later upstream change;
- `Kind:` `temporary` (with the check that says when it can go), `fork-only`, or
  `incompatible` (upstream would not take it);
- how to check it still works;
- the trailer `Fork-Patch: <name>.patch` (letters, digits, `.`, `_`, `-`).

A patch changes upstream's files only, never `fork/`. Commit it as the fork's identity.

### Writing or changing a patch

`fork/patches.sh` runs git only, so it is safe outside the sandbox.

```bash
# On a clean checkout of fork (or a linked worktree of a branch off it):
bash fork/patches.sh import    # branch fork-patches: upstream + fork/ + the series, one commit each
# Edit upstream files, then one commit per patch:
git commit -a -m "<what it does>" -m "Intent: ..." -m "Kind: fork-only" -m "Check: ..." \
  --trailer "Fork-Patch: <name>.patch"
git switch -                   # back to the branch you started on
bash fork/patches.sh export    # writes fork/patches (uncommitted) and replays it: same trees
git add fork/patches && git commit -m "fork/patches: <name>"
git branch -D fork-patches && git update-ref -d refs/patches/upstream-head
```

To change an existing patch, change its commit on `fork-patches`: `git commit --amend` for the
newest, otherwise `git commit --fixup=<commit>` and
`GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash refs/patches/upstream-head`. To drop one, remove
its commit the same way. `export` writes the whole series again in commit order; a patch that
`export` wrote and whose commit didn't change keeps its exact bytes. Then rebuild with `bash fork/sync.sh --force` and run the checks, as
for any `fork/` change.

### When a sync stops on a patch

Upstream changed the lines the patch touches, or the lines around them.

1. Read why. Take the Intent from the patch, then
   `git log -p <old upstream>..<new upstream> -- <the patch's files>` (the old one is the
   `Upstream-Commit:` trailer of the generated commit on `fork`). If upstream only moved or
   reworded the code around the patch, refresh it. If upstream changed what the patched code
   means, or now does what the patch did, stop: the patch needs a decision (rework it or drop it).
2. Refresh it on the new upstream:

   ```bash
   git fetch upstream main
   bash fork/patches.sh import --onto FETCH_HEAD   # stops at the patch that no longer applies
   bash fork/patches.sh import --continue --3way   # merges a moved context
   # On a conflict (exit 2, `git am` in progress): fix the files, `git add` them, then
   bash fork/patches.sh import --continue
   ```

3. Check the refreshed commit still does what its Intent says, then `export` and commit, as above.
   The exported patch applies strictly again.

`import` keeps upstream's attribute settings and your git config out of the apply, as the sync
does. A conflict leaves that override in place until `import --continue` finishes.

The rules for agents working in this repo live in `fork/agent-rules.md`. `fork/apply.ts` inserts
them right under the title of `AGENTS.md`, which `CLAUDE.md` imports. They go near the top because
Codex stops reading instruction files at 32 KiB, and upstream's file is already 26 KB.

## What the fork changes

| Value                       | Files                                                                                                                                                      |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `domain`                    | Hosted-app default (`connectAuth.ts`), provider-auth return allowlist (`providerAuthReturnUrl.ts`), iOS Clerk relying party (`apps/mobile/app.config.ts`). |
| `releaseRepository`         | Release lookup, downloads and links (`cliRelease.ts`, `scripts/install.*`, `desktopUpdate.logic.ts`, `DesktopStartupRecovery.ts`, web links, docs clone).  |
| `installScriptBaseUrl`      | Where copyable install commands fetch `install.sh`/`install.ps1` (`install.ts`, `servicePreflight.ts`, `InstallT3Commands.tsx`, SSH tunnel, install docs). |
| `telemetryEnabledByDefault` | Analytics on by default as upstream's (off by default on CI; off with `DO_NOT_TRACK`). `analytics-defaults-test.patch` asserts `true`.                     |
| `telemetry.*`               | Analytics host and app key (`AnalyticsService.ts`), who runs it (`docs/user/telemetry.md`), the Privacy Policy link (`legalLinks.ts`).                     |
| `desktopAppId`              | macOS bundle ID and app user model ID (`build-desktop-artifact.ts`, `DesktopEnvironment.ts`).                                                              |
| `mobile.*`                  | iOS bundle IDs and Apple team (`apps/mobile/app.config.ts`).                                                                                               |
| `relay.*`                   | Relay Postgres size, replica count and Hyperdrive connection limit (`infra/relay/src/db.ts`). Upstream's defaults cost about $150 a month.                 |

Two more edits follow from these values: the server refreshes its model list from
`releaseRepository`'s `fork` branch (`ModelManifest.ts`), not upstream's `main`; and after every
edit `apply.ts` checks that no tracked file under `apps/`, `packages/`, `infra/` or `scripts/`
still holds upstream's analytics host or key as plain text, in any letter case, so a second place
upstream adds stops the sync. That check skips test files (`*.test.*`), binary files (any NUL
byte), symlinks and paths missing from the tree, and it cannot see a value built from parts at
runtime.
Once `domain` is ours, nightly builds also approve agent sign-ins on `app.<domain>`
(`publicConfig.ts`) instead of upstream's nightly app; until then that line is only checked.

Patches (`fork/patches/`, listed in `.patches`):

- `hide-mobile-store-links.patch`: hides the Settings "Mobile app" row (App Store and Google Play
  QR codes), its search entry and the Welcome page's Phone section. Upstream's store apps connect to
  upstream's T3 Connect, and this build has no app of its own yet. One flag:
  `MOBILE_APP_PUBLISHED` in `apps/web/src/branding.ts`.
- `pair-matching-cli.patch`: when `t3 pair` finds a server on another protocol, it names the
  runtime this machine already unpacked for the server's version, or `t3 update <version>` and then
  `t3 pair`, instead of upstream's `npx t3@<version> pair` (this build has no npm package).
- `analytics-defaults-test.patch`: a test only. It starts the analytics service with no settings
  and checks that its one request goes to this build's ingest server with this build's key, and
  that nothing is sent from a CI runner or with `DO_NOT_TRACK`. It asserts three defaults in
  `fork/identity.json`: changing `telemetry.ingestHost`, `telemetry.ingestKey` or
  `telemetryEnabledByDefault` means changing it.

Everything else is configured at build or run time, without changing code:

- **Clerk and relay:** `T3CODE_CLERK_*`, `T3CODE_RELAY_URL` and `T3CODE_HOSTED_APP_URL` (see
  `docs/operations/connect-setup.md`).
- **Desktop update feed:** `T3CODE_DESKTOP_UPDATE_REPOSITORY`, set to `releaseRepository`.
- **iOS over-the-air updates:** off, with `T3CODE_MOBILE_UPDATES_ENABLED=0`.
- **Relay zones:** `RELAY_API_ZONE_NAME` and `RELAY_TUNNEL_ZONE_NAME`.

## Upstream paths deliberately left alone

These still point at upstream. None of them install an upstream build on their own. Revisit them if
one starts to matter.

- **Server npm version lookup** (`apps/server/src/cloud/npmRelease.ts`): offers upstream's npm
  versions when you switch update tracks. The download itself comes from `releaseRepository`, so a
  version we never released fails rather than installing upstream.
- **Copyable `npx t3` commands** in the desktop app's data-directory messages (`npx t3@latest`, a
  string every locale catalog translates): these run upstream's npm package. The installers' errors and `t3 install` no longer mention npm. The
  `curl | sh` commands use `installScriptBaseUrl`, which is the raw scripts on `fork` until our
  domain serves them.
- **Install commands in upstream's README and docs** other than `docs/user/install.md`, and that
  page's package-manager and release links.
- **Settings links** to upstream's marketing site, privacy policy and docs. (The mobile store
  links are hidden by a patch; see above.)
- **In-app triage:** it prepares issues against upstream.
- **EAS project, owner and App Store Connect IDs** (`app.config.ts`, `eas.json`): we don't use EAS.
  Don't run `eas` commands until these are ours.
- **Relay Axiom monitoring queries** naming `relay.t3.codes` (`infra/relay/src/monitoring.ts`): fix
  this when the relay is deployed.
- **Internal names** (`@t3tools/*`, native module namespaces, Linux desktop IDs) and the
  `t3.json` schema URL.

## Builds

`fork/pipeline/build.sh <cli|web>` builds a commit in a disposable worktree inside Docker and leaves
the result in `../artifacts/<version>/`. It publishes nothing and needs nothing installed on the
host: the image carries the pinned Node, Rust and patchelf.

- `cli`: the Linux x64 server/CLI archive and `SHA256SUMS`, following the CLI steps of upstream's
  `release-desktop.yml`, including its smoke test.
- `web`: the hosted web app as static files, for `app.<domain>`.

Pass the public client config with `--env-file` (`T3CODE_CLERK_*`, `T3CODE_RELAY_URL`,
`VITE_HOSTED_APP_URL`). Without it the build has T3 Connect disabled.

Versions use upstream's nightly format with run number `900000 + HHMM` (UTC), so a fork build sorts
above upstream's nightly of the same day. Don't add `+fork`: upstream's version comparisons ignore
it and its channel checks reject it.

## Releases

Releases are published in this repository (`releaseRepository` is `rockface-dev/t3code`), so
installed builds find updates the same way upstream's do. Nothing is released yet.

### Alternative: a private mirror

For machines that should not depend on GitHub, upstream's managed policy points updates at an HTTPS
mirror instead (`docs/user/managed-policy.md`, "Updates"). `/etc/t3code/policy.json` on each
machine:

```json
{
  "schemaVersion": 1,
  "organization": "T3 Fork",
  "limits": { "updates": { "mode": "auto", "feedUrl": "https://releases.<domain>/" } }
}
```

`fork/pipeline/mirror.sh <artifacts/<version>> <mirror dir>` lays a `build.sh cli` result out the
way that feed expects; upload the directory to the mirror. `t3 update` then finds and installs it.
`mirror.sh --upstream <version>` copies one of upstream's releases in, so a machine can go back:
`t3 update <version> --allow-downgrade`. Without that copy, a machine with the policy cannot
install an upstream version.

With no policy, a fork build looks for updates only in `releaseRepository`. It installs an
upstream release only if someone copies one into a mirror on purpose, as above.

The web artifact (`build.sh web`) deploys to Cloudflare static assets with the `wrangler.jsonc`
beside it. It carries Apple's association file at the extensionless path Apple fetches, and an
empty Android links file, because the fork ships no Android app.

The mirror route was rehearsed end to end in a VM on 2026-11-08.
