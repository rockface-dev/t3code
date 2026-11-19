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

The rules for agents working in this repo live in `fork/agent-rules.md`. `fork/apply.ts` inserts
them right under the title of `AGENTS.md`, which `CLAUDE.md` imports. They go near the top because
Codex stops reading instruction files at 32 KiB, and upstream's file is already 26 KB.

## What the fork changes

| Value                       | Files                                                                                                                                                      |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `domain`                    | Hosted-app default (`connectAuth.ts`), provider-auth return allowlist (`providerAuthReturnUrl.ts`), iOS Clerk relying party (`apps/mobile/app.config.ts`). |
| `releaseRepository`         | Server/CLI release discovery and downloads (`cliRelease.ts`), desktop release links (`desktopUpdate.logic.ts`, `DesktopStartupRecovery.ts`).               |
| `telemetryEnabledByDefault` | The PostHog default (`AnalyticsService.ts`). The desktop app bundles its server, so an environment variable isn't enough.                                  |
| `desktopAppId`              | macOS bundle ID and app user model ID (`build-desktop-artifact.ts`, `DesktopEnvironment.ts`).                                                              |
| `mobile.*`                  | iOS bundle IDs and Apple team (`apps/mobile/app.config.ts`).                                                                                               |
| `relay.*`                   | Relay Postgres size, replica count and Hyperdrive connection limit (`infra/relay/src/db.ts`). Upstream's defaults cost about $150 a month.                 |

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
- **Copyable `npx t3` and `curl https://t3.codes/install.sh` commands** in error and preflight
  messages: these would install upstream if run by hand.
- **Settings QR codes and download links** to upstream's apps, marketing site, privacy policy and
  docs.
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
