#!/usr/bin/env bash
# Tests for fork/patches.sh apply, in a throwaway repo (git only: nothing from upstream runs).
# Usage: bash fork/patches-test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="${KEEP_TMP:-$(mktemp -d)}"; [[ -n "${KEEP_TMP:-}" ]] || trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; shift; printf '  %s\n' "$@"; fail=1; }
export GIT_AUTHOR_NAME=fork GIT_AUTHOR_EMAIL=fork@example.invalid GIT_COMMITTER_NAME=fork GIT_COMMITTER_EMAIL=fork@example.invalid
export GIT_AUTHOR_DATE='2026-11-22T00:00:00Z' GIT_COMMITTER_DATE='2026-11-22T00:00:00Z'
g() { command git -c core.hooksPath=/dev/null -c init.defaultBranch=main -c core.safecrlf=false -c advice.detachedHead=false "$@"; }

# A global config that defines a filter, as a machine might; upstream's .gitattributes asks for it,
# for eol=crlf conversion and for the union merge driver. None of it may touch a patch.
printf '[filter "evil"]\n\tclean = touch %s/evil-ran; cat\n\tsmudge = touch %s/evil-ran; cat\n\trequired = true\n' "$tmp" "$tmp" > "$tmp/global.gitconfig"
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"

# up: the upstream commit. fork/: the overlay commit (fork/patches.sh + fork/patches).
r="$tmp/repo"
g init -q "$r"
seq 1 20 > "$r/a.txt"
printf 'one\ntwo\n' > "$r/b.txt"
printf '* text eol=crlf merge=union filter=evil\n' > "$r/.gitattributes"
GIT_CONFIG_GLOBAL=/dev/null g -C "$r" add -A && GIT_CONFIG_GLOBAL=/dev/null g -C "$r" commit -q -m upstream
up="$(g -C "$r" rev-parse HEAD)"

# Patches are made the way fork/patches.sh export will: a commit, then format-patch --full-index.
mkpatch() { # mkpatch <name> <subject> <edit command...>: writes fork/patches/<name>.patch from an edit on up
  local name=$1 subject=$2; shift 2
  local w="$tmp/w-$name"
  # Written the way a session would: with upstream's conversions off, so the patch holds blobs.
  rm -rf "$w"; GIT_CONFIG_GLOBAL=/dev/null g clone -q --no-checkout "$r" "$w" || exit 1
  mkdir -p "$w/.git/info" && echo '* -text -filter' > "$w/.git/info/attributes"
  GIT_CONFIG_GLOBAL=/dev/null g -C "$w" checkout -q "${BASE:-$up}" && (cd "$w" && "$@") &&
    GIT_CONFIG_GLOBAL=/dev/null g -C "$w" commit -q -a -m "$subject" -m "Intent: test." -m "Kind: temporary (test)" -m "Fork-Patch: $name.patch" ||
    { echo "FAIL fixture: mkpatch $name"; exit 1; }
  mkdir -p "$tmp/patches"
  GIT_CONFIG_GLOBAL=/dev/null g -C "$w" format-patch -q --full-index --zero-commit --no-signature --no-stat --stdout -1 > "$tmp/patches/$name.patch"
}
mkpatch p1 "change line 5" sed -i 's/^5$/five/' a.txt
BASE="" mkpatch p2 "change b" sed -i 's/^two$/TWO/' b.txt

# overlay <patch names...>: a fresh overlay commit on up holding fork/patches.sh and those patches.
overlay() {
  GIT_CONFIG_GLOBAL=/dev/null g -C "$r" checkout -q -f "$up" && GIT_CONFIG_GLOBAL=/dev/null g -C "$r" clean -qfdx
  mkdir -p "$r/fork/patches" && cp "$here/patches.sh" "$r/fork/"
  : > "$r/fork/patches/.patches"
  local p
  for p in "$@"; do cp "$tmp/patches/$p.patch" "$r/fork/patches/" 2> /dev/null; echo "$p.patch" >> "$r/fork/patches/.patches"; done
  GIT_CONFIG_GLOBAL=/dev/null g -C "$r" add -A && GIT_CONFIG_GLOBAL=/dev/null g -C "$r" commit -q -m "fork: overlay files"
  start="$(g -C "$r" rev-parse HEAD)"
}
run() { (cd "$r" && bash "$here/patches.sh" apply) > "$tmp/out" 2>&1; code=$?; head_now="$(GIT_CONFIG_GLOBAL=/dev/null g -C "$r" rev-parse HEAD)"; }
clean_after() { [[ "$head_now" == "$start" && -z "$(GIT_CONFIG_GLOBAL=/dev/null g -C "$r" status --porcelain)" && ! -d "$r/.git/rebase-apply" && ! -e "$r/.git/info/attributes" ]]; }

# 1. No .patches: nothing happens.
GIT_CONFIG_GLOBAL=/dev/null g -C "$r" checkout -q "$up"; start="$up"
run
[[ $code == 0 && "$head_now" == "$up" ]] && ok "no .patches: nothing to do" || no "no .patches: nothing to do" "code=$code" "$(cat "$tmp/out")"

# 2. Two patches apply, one commit each, with their trailers; text exactly as in the patch.
rm -f "$tmp/evil-ran"
overlay p1 p2
run
if [[ $code == 0 && "$(g -C "$r" rev-list --count "$start..HEAD")" == 2 ]] && grep -q 'applied 2 patch' "$tmp/out" &&
  [[ "$(GIT_CONFIG_GLOBAL=/dev/null g -C "$r" log --format='%(trailers:key=Fork-Patch,valueonly)' "$start..HEAD" | sed '/^$/d' | paste -sd' ')" == "p2.patch p1.patch" ]]; then
  ok "two patches: two commits, in order, with trailers"
else no "two patches: two commits, in order, with trailers" "code=$code" "$(cat "$tmp/out")"; fi
GIT_CONFIG_GLOBAL=/dev/null g -C "$r" show HEAD~0:a.txt | grep -qx five && ! GIT_CONFIG_GLOBAL=/dev/null g -C "$r" show HEAD:a.txt | grep -q $'\r' &&
  ok "blob is the patch's text (no eol=crlf conversion)" || no "blob is the patch's text (no eol=crlf conversion)"
[[ ! -e "$tmp/evil-ran" ]] && ok "a globally defined filter never ran" || no "a globally defined filter never ran"
[[ ! -e "$r/.git/info/attributes" ]] && ok "info/attributes put back (absent before)" || no "info/attributes put back (absent before)"
# The host verifies the sandbox's patch commits by replaying the patches without a working tree
# (bin/fork-sandbox: a bare repo, the overlay tree rebuilt as upstream + fork/, then
# `apply --cached` per patch). That must give exactly the trees patches.sh made here.
# (apply --cached reads .gitattributes from the index, so the override is needed there too.)
b="$tmp/bare"; rm -rf "$b"; GIT_CONFIG_GLOBAL=/dev/null g init -q --bare "$b" && echo "$r/.git/objects" > "$b/objects/info/alternates"
echo '* -text -eol -filter -diff -ident -working-tree-encoding merge=text' > "$b/info/attributes"
hg() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_INDEX_FILE="$tmp/replay.index" g -C "$b" -c apply.whitespace=nowarn "$@"; }
t="$({ hg ls-tree "$up" | grep -v $'\tfork$'; printf '040000 tree %s\tfork\n' "$(g -C "$r" rev-parse "$start:fork")"; } | hg mktree)"
replay_ok=true
[[ "$t" == "$(g -C "$r" rev-parse "$start^{tree}")" ]] || replay_ok=false
hg read-tree "$t" || replay_ok=false
k=0
for p in p1 p2; do
  k=$((k + 1))
  g -C "$r" show "$start:fork/patches/$p.patch" > "$tmp/replay.patch" # the blob, as the host reads it
  hg apply --cached -- "$tmp/replay.patch" && t="$(hg write-tree)" || replay_ok=false
  [[ "$t" == "$(g -C "$r" rev-parse "$(g -C "$r" rev-list --reverse "$start..HEAD" | sed -n "${k}p")^{tree}")" ]] || replay_ok=false
done
[[ "$replay_ok" == true ]] && ok "host-style replay (bare, apply --cached) gives the same trees" || no "host-style replay (bare, apply --cached) gives the same trees"
# Determinism: the same inputs give the same trees.
t1="$(g -C "$r" rev-parse 'HEAD^{tree}')"
overlay p1 p2; run
[[ "$(g -C "$r" rev-parse 'HEAD^{tree}')" == "$t1" ]] && ok "same inputs, same tree" || no "same inputs, same tree"

# 3. Upstream changed a patch's context: stop, nothing written, branch where it was.
seq 1 20 | sed 's/^6$/six-upstream/' > "$tmp/a2.txt"
GIT_CONFIG_GLOBAL=/dev/null g -C "$r" checkout -q -f "$up" && cp "$tmp/a2.txt" "$r/a.txt" &&
  GIT_CONFIG_GLOBAL=/dev/null g -C "$r" commit -q -a -m "upstream moves on"
up_old="$up"; up="$(g -C "$r" rev-parse HEAD)"
overlay p1 p2
run
[[ $code == 1 ]] && grep -qx 'fork/patches.sh: patch p1.patch no longer applies' "$tmp/out" && clean_after &&
  ok "context changed: stops, names the patch, leaves nothing" || no "context changed: stops, names the patch, leaves nothing" "code=$code" "$(cat "$tmp/out")"
# ... even though a 3-way merge (or the union driver) would have "resolved" it.
up="$up_old"

# 4. A patch that touches fork/ is refused.
BASE="" mkpatch p3 "touch fork" sh -c 'mkdir -p fork && echo x > fork/x && git -c core.hooksPath=/dev/null add fork/x'
overlay p3
run
[[ $code == 1 ]] && grep -q 'patch p3.patch changes fork/' "$tmp/out" && clean_after && ok "a patch to fork/ is refused" || no "a patch to fork/ is refused" "code=$code" "$(cat "$tmp/out")"

# ... also when git would quote the name (non-ASCII), which a line-based check would miss.
BASE="" mkpatch p5 "touch fork, quoted name" sh -c 'mkdir -p fork && echo x > fork/café.txt && git -c core.hooksPath=/dev/null add fork/café.txt'
overlay p5
run
[[ $code == 1 ]] && grep -q 'patch p5.patch changes fork/' "$tmp/out" && clean_after && ok "a patch to fork/ with a quoted name is refused" || no "a patch to fork/ with a quoted name is refused" "code=$code" "$(cat "$tmp/out")"

# 5. Listed but missing; a bad name; a symlink.
overlay p1; echo "gone.patch" >> "$r/fork/patches/.patches"; GIT_CONFIG_GLOBAL=/dev/null g -C "$r" commit -q -a -m x; start="$(g -C "$r" rev-parse HEAD)"
run
[[ $code == 1 ]] && grep -q 'patch gone.patch is listed but missing' "$tmp/out" && clean_after && ok "a listed patch that is missing stops it" || no "a listed patch that is missing stops it" "$(cat "$tmp/out")"
overlay; echo "../a.patch" > "$r/fork/patches/.patches"; GIT_CONFIG_GLOBAL=/dev/null g -C "$r" commit -q -a -m x; start="$(g -C "$r" rev-parse HEAD)"
run
[[ $code == 1 ]] && grep -q 'bad patch name' "$tmp/out" && ok "a path in .patches is refused" || no "a path in .patches is refused" "$(cat "$tmp/out")"
overlay; ln -s "$tmp/patches/p1.patch" "$r/fork/patches/l.patch"; echo "l.patch" > "$r/fork/patches/.patches"
GIT_CONFIG_GLOBAL=/dev/null g -C "$r" add -A && GIT_CONFIG_GLOBAL=/dev/null g -C "$r" commit -q -m x; start="$(g -C "$r" rev-parse HEAD)"
run
[[ $code == 1 ]] && grep -q 'missing (or a symlink)' "$tmp/out" && ok "a symlinked patch is refused" || no "a symlinked patch is refused" "$(cat "$tmp/out")"

# 6. A patch without its Fork-Patch trailer is refused.
sed '/^Fork-Patch:/d' "$tmp/patches/p1.patch" > "$tmp/patches/p4.patch"
overlay p4
run
[[ $code == 1 ]] && grep -q "no 'Fork-Patch: p4.patch' trailer" "$tmp/out" && clean_after && ok "missing trailer is refused" || no "missing trailer is refused" "$(cat "$tmp/out")"

# 7. An existing info/attributes is put back as it was.
overlay p1; printf 'keep me\n' > "$r/.git/info/attributes"
run
[[ $code == 0 && "$(cat "$r/.git/info/attributes")" == "keep me" ]] && ok "an existing info/attributes is put back" || no "an existing info/attributes is put back" "$(cat "$tmp/out")"

# 7b. In a linked worktree, where info/attributes lives in the common git dir.
G() { GIT_CONFIG_GLOBAL=/dev/null g -C "$r" "$@"; }
rm -f "$r/.git/info/attributes"; overlay p1 p2; wt="$tmp/wt"; rm -rf "$wt"; G worktree add -q --detach "$wt" "$start"
(cd "$wt" && bash "$here/patches.sh" apply) > "$tmp/out" 2>&1; code=$?
[[ $code == 0 && "$(GIT_CONFIG_GLOBAL=/dev/null g -C "$wt" rev-parse 'HEAD^{tree}')" == "$t1" && ! -e "$r/.git/info/attributes" ]] &&
  ok "a linked worktree: same tree, override in the common dir and put back" || no "a linked worktree: same tree, override in the common dir and put back" "code=$code" "$(cat "$tmp/out")"
G worktree remove --force "$wt"

# --- import and export (the session's tools) ---------------------------------------------------
G() { GIT_CONFIG_GLOBAL=/dev/null g -C "$r" "$@"; }
runp() { (cd "$r" && bash "$here/patches.sh" "$@") > "$tmp/out" 2>&1; code=$?; }
reset_work() { G checkout -q -f "$1" && G clean -qfdx && { G branch -D -q fork-patches 2> /dev/null; G update-ref -d refs/patches/upstream-head 2> /dev/null; rm -f "$r/.git/info/attributes"; true; }; }

# 8. Round trip: import the series, export it unchanged: the same bytes.
overlay p1 p2; tip="$start"; reset_work "$tip"
runp import
if [[ $code == 0 && "$(G branch --show-current)" == fork-patches && "$(G rev-parse refs/patches/upstream-head^)" == "$up" &&
  "$(G rev-list --count refs/patches/upstream-head..HEAD)" == 2 && "$(G rev-parse 'HEAD^{tree}')" == "$t1" && ! -e "$r/.git/info/attributes" ]]; then
  ok "import: fork-patches = upstream + overlay + series, same tree as apply"
else no "import: fork-patches = upstream + overlay + series, same tree as apply" "code=$code" "$(cat "$tmp/out")"; fi
runp import
[[ $code == 1 ]] && grep -q 'branch fork-patches exists' "$tmp/out" && ok "import refuses while fork-patches exists" || no "import refuses while fork-patches exists" "$(cat "$tmp/out")"
G checkout -q -f "$tip"
runp export
# (Compared as staged blobs: this repo's eol=crlf makes status flag files whose blob is equal.)
staged() { G add -A && G diff --cached --name-only "$@" | paste -sd' '; }
if [[ $code == 0 && "$(staged)" == "fork/patches/.gitattributes fork/patches/.patches" ]] && G diff --cached -- fork/patches/.patches | grep -q '^+# The order'; then
  ok "export of an unchanged series: same patch files (new: .gitattributes, a header in .patches)"
else no "export of an unchanged series: same patch files (new: .gitattributes, a header in .patches)" "code=$code" "$(cat "$tmp/out")" "$(staged)"; fi
G reset -q --hard

# 9. A new patch: a commit on fork-patches, exported, then applied by a sync.
G checkout -q -f "$tip" && G clean -qfdx
G checkout -q fork-patches
printf 'new\r\nfile\r\n' > "$r/c.cmd" # a CRLF blob (added with conversion off): the patch file must keep it
printf '* -text\n' > "$r/.git/info/attributes" && G add c.cmd && rm "$r/.git/info/attributes" && G commit -q -m "add c.cmd" -m "Intent: test a new patch." -m "Kind: fork-only" -m "Fork-Patch: p6.patch"
G checkout -q -f "$tip"
runp export
G add -A && G commit -q -m "fork: add p6" && tip2="$(G rev-parse HEAD)"
G checkout -q -f "$up" && G checkout "$tip2" -- fork && G commit -q -m "fork: overlay files" && start="$(G rev-parse HEAD)"
run
if [[ $code == 0 && "$(grep -v '^#' "$r/fork/patches/.patches" | paste -sd' ')" == "p1.patch p2.patch p6.patch" ]] &&
  G diff --quiet fork-patches HEAD -- . ':!fork' && [[ "$(G show HEAD:c.cmd)" == $'new\r\nfile\r' ]]; then
  ok "a new patch: exported, listed last, applied by a sync to the same files (CRLF kept)"
else no "a new patch: exported, listed last, applied by a sync to the same files (CRLF kept)" "code=$code" "$(cat "$tmp/out")"; fi

# 10. export refuses a commit without Kind, one that changes fork/, and a merge; nothing written.
G checkout -q -f -B bad1 fork-patches && echo x > "$r/d.txt" && G add d.txt && G commit -q -m "no kind" -m "Intent: x." -m "Fork-Patch: p7.patch"
G checkout -q -f -B bad2 fork-patches && echo x >> "$r/fork/patches.sh" && G commit -q -a -m "touch fork" -m "Intent: x." -m "Kind: temporary" -m "Fork-Patch: p8.patch"
G checkout -q -f -B bad3 fork-patches && G merge -q --no-ff -m merge bad1 > /dev/null 2>&1
G checkout -q -f "$tip"
runp export bad1; m1="$(cat "$tmp/out")"; c1=$code
runp export bad2; m2="$(cat "$tmp/out")"; c2=$code
runp export bad3; m3="$(cat "$tmp/out")"; c3=$code
if [[ $c1 == 1 && $c2 == 1 && $c3 == 1 && "$m1" == *"needs 'Kind:"* && "$m2" == *"changes fork/"* && "$m3" == *"has a merge"* && -z "$(G status --porcelain)" && ! -e "$r/.git/info/attributes" ]]; then
  ok "export refuses no Kind, a fork/ change and a merge; writes nothing"
else no "export refuses no Kind, a fork/ change and a merge; writes nothing" "$m1" "$m2" "$m3"; fi

# 11. Refresh after upstream moved a patch's context: the strict import stops, --3way merges it,
#     and the exported patch applies strictly again.
G checkout -q -f "$up" && seq 1 20 | sed 's/^8$/eight-upstream/' > "$r/a.txt" && G commit -q -a -m "upstream moves line 8" && up2="$(G rev-parse HEAD)"
reset_work "$tip"
runp import --onto "$up2"
if [[ $code == 1 ]] && grep -q 'patch p1.patch no longer applies (0 of 2 applied' "$tmp/out" && [[ ! -d "$r/.git/rebase-apply" && ! -e "$r/.git/info/attributes" ]]; then
  ok "import onto a moved upstream: stops at the patch, nothing in progress"
else no "import onto a moved upstream: stops at the patch, nothing in progress" "code=$code" "$(cat "$tmp/out")"; fi
runp import --continue --3way
if [[ $code == 0 && "$(G rev-list --count refs/patches/upstream-head..HEAD)" == 2 ]] && G show HEAD:a.txt | grep -qx five && G show HEAD:a.txt | grep -qx eight-upstream; then
  ok "import --continue --3way: the moved context merges"
else no "import --continue --3way: the moved context merges" "code=$code" "$(cat "$tmp/out")"; fi
G checkout -q -f "$tip"
runp export
G add -A && G commit -q -m "fork: refresh p1" && tip3="$(G rev-parse HEAD)"
G checkout -q -f "$up2" && G checkout "$tip3" -- fork && G commit -q -m "fork: overlay files" && start="$(G rev-parse HEAD)"
run
[[ $code == 0 && "$(G diff --name-only "$tip" "$tip3" -- fork | paste -sd' ')" == "fork/patches/.gitattributes fork/patches/.patches fork/patches/p1.patch" ]] &&
  ok "refreshed series applies strictly on the new upstream; only p1.patch changed" ||
  no "refreshed series applies strictly on the new upstream; only p1.patch changed" "code=$code" "$(cat "$tmp/out")" "$(G diff --name-only "$tip" "$tip3" -- fork)"

# 12. A real conflict: --3way stops with git am in progress and the override kept; resolved by
#     hand, --continue finishes and puts the attributes back as they were.
G checkout -q -f "$up" && seq 1 20 | sed 's/^5$/five-upstream/' > "$r/a.txt" && G commit -q -a -m "upstream changes line 5" && up3="$(G rev-parse HEAD)"
reset_work "$tip"; printf 'keep me\n' > "$r/.git/info/attributes"
runp import --onto "$up3"; c0=$code
runp import --continue --3way
if [[ $c0 == 1 && $code == 2 && -d "$r/.git/rebase-apply" ]] && grep -q 'patch p1.patch conflicts' "$tmp/out" && [[ "$(cat "$r/.git/info/attributes")" == "* -text -eol -filter -diff -ident -working-tree-encoding merge=text" ]]; then
  ok "a real conflict: stops with git am in progress, override kept"
else no "a real conflict: stops with git am in progress, override kept" "c0=$c0 code=$code" "$(cat "$tmp/out")"; fi
runp import --continue
[[ $code == 1 ]] && grep -q 'fix the conflicts' "$tmp/out" && ok "--continue refuses while files are unmerged" || no "--continue refuses while files are unmerged" "$(cat "$tmp/out")"
seq 1 20 | sed 's/^5$/five/' > "$r/a.txt" && G add a.txt
echo "unstaged work" >> "$r/b.txt"
runp import --continue
[[ $code == 1 ]] && grep -q 'unstaged changes' "$tmp/out" && grep -q 'unstaged work' "$r/b.txt" && [[ -d "$r/.git/rebase-apply" ]] &&
  ok "--continue refuses unstaged changes and keeps them" || no "--continue refuses unstaged changes and keeps them" "code=$code" "$(cat "$tmp/out")"
G checkout -q -- b.txt
runp import --continue
if [[ $code == 0 && ! -d "$r/.git/rebase-apply" && "$(cat "$r/.git/info/attributes")" == "keep me" && "$(G rev-list --count refs/patches/upstream-head..HEAD)" == 2 ]] && G show HEAD:a.txt | grep -qx five; then
  ok "resolved by hand: --continue applies the rest, attributes put back"
else no "resolved by hand: --continue applies the rest, attributes put back" "code=$code" "$(cat "$tmp/out")"; fi
rm -f "$r/.git/info/attributes"

# 13. Review findings (M2-03): one case each.
# A "---" line in a message: git am would end the message there and lose the trailer.
reset_work "$tip"; runp import
printf 'x\n' > "$r/e.txt" && G add e.txt && G commit -q -m "dashes" -m $'Why:\n---\nmore' -m "Intent: x." -m "Kind: fork-only" -m "Fork-Patch: p9.patch"
G checkout -q -f "$tip"
runp export
[[ $code == 1 ]] && grep -q 'loses its Fork-Patch' "$tmp/out" && [[ -z "$(G status --porcelain)" ]] &&
  ok "export refuses a message git am would cut at '---'" || no "export refuses a message git am would cut at '---'" "code=$code" "$(cat "$tmp/out")"
# A git am that import didn't start: --continue leaves it alone.
G checkout -q fork-patches && G reset -q --hard HEAD~1
G am --no-3way "$r/fork/patches/p1.patch" > /dev/null 2>&1 # p1 is applied already: am stops
runp import --continue
[[ $code == 1 ]] && grep -q "wasn't started by import" "$tmp/out" && [[ -d "$r/.git/rebase-apply" ]] &&
  ok "--continue refuses a git am it didn't start" || no "--continue refuses a git am it didn't start" "code=$code" "$(cat "$tmp/out")"
G am --abort
# A directory where a patch file goes: refused before anything is deleted.
G checkout -q -f "$tip" && rm -f "$r/fork/patches/p1.patch" && mkdir "$r/fork/patches/p1.patch" && echo k > "$r/fork/patches/p1.patch/keep" &&
  G add -A && G commit -q -m "dir in the way" && tipd="$(G rev-parse HEAD)"
runp export
[[ $code == 1 ]] && grep -q 'p1.patch is not a plain file' "$tmp/out" && [[ -z "$(G status --porcelain)" && -f "$r/fork/patches/p2.patch" ]] &&
  ok "export refuses a directory in place of a patch file, writes nothing" || no "export refuses a directory in place of a patch file, writes nothing" "code=$code" "$(cat "$tmp/out")"
# apply reports entries in order, as the published version did.
overlay; printf 'missing.patch\n../bad.patch\n' > "$r/fork/patches/.patches"; G commit -q -a -m x; start="$(G rev-parse HEAD)"
run
[[ $code == 1 ]] && grep -q 'patch missing.patch is listed but missing' "$tmp/out" && ok "apply: the first bad entry is the one reported" || no "apply: the first bad entry is the one reported" "$(cat "$tmp/out")"
# A patch to fork/ among many paths: the check must not depend on a pipe (grep -q + SIGPIPE).
reset_work "$tip"; runp import
mkdir -p "$r/many" && (cd "$r/many" && seq -f 'zz-%06g' 1 12000 | xargs touch) && echo x > "$r/fork/x" &&
  G add -A && G commit -q -m "many" -m "Intent: x." -m "Kind: fork-only" -m "Fork-Patch: p10.patch"
G checkout -q -f "$tip" && G clean -qfdx
runp export
[[ $code == 1 ]] && grep -q 'changes fork/' "$tmp/out" && ok "a fork/ change among 12,000 paths is refused" || no "a fork/ change among 12,000 paths is refused" "code=$code" "$(cat "$tmp/out")"
reset_work "$tip"

((fail == 0)) && echo "all passed" || echo "SOME FAILED"
exit $fail
