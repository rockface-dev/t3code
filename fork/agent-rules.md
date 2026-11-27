## Fork rules (rockface-dev/t3code)

This checkout is rockface-dev's fork of pingdotgg/t3code, not upstream. `fork/sync.sh` rebuilds the
`fork` branch from upstream's `main`, and `fork/apply.ts` inserts this section from
`fork/agent-rules.md`. Where these rules and the rest of this file disagree, these rules win. Below,
"we" and "maintainers" still mean upstream's team. The people you work for here are the fork's
owners.

- **Never hand-edit upstream files on `fork`.** Each sync rebuilds the branch from upstream and
  throws those edits away. Change `fork/identity.json` or `fork/apply.ts` instead. A change to
  upstream's code is a patch in `fork/patches` ("Code changes: patches" in `fork/README.md`); add
  one only when the fork's owners ask for that change.
- **Never edit the generated commit** ("fork: apply fork/identity.json (generated)"). Change the
  `fork/` source and run the sync again.
- **Don't push `fork` yourself.** The owners' sync tooling does it: `bash fork/sync.sh`, `vp i`,
  `vp run check:changed <new upstream SHA>`, a check of everything the push would publish, then a
  push with `--force-with-lease`. Running `bash fork/sync.sh` locally to investigate is fine. Only
  the organization's owners can force-push `fork`.
- **GitHub Actions is off here.** Upstream's workflows stay in `.github/workflows`, because
  upstream tests read them, but they must never run. Don't turn Actions on or add a workflow without
  the owners' approval. The fork's own workflows will be named `fork-*.yml`.
- **No pull requests, issues or comments on pingdotgg/t3code.**
- **Nothing private goes in this repository:** no secrets, tokens, local paths, plans, notes or
  logs. The fork's owners keep those elsewhere.
- Upstream's code conventions below still apply. Its pull request, CI and release process is
  upstream's own and does not run here.
