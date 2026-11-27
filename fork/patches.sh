#!/usr/bin/env bash
# The fork's patch lane: real code changes kept as patch files, put back on top of upstream by
# every sync (fork/sync.sh), after the overlay commit and before fork/apply.ts.
#   fork/patches/.patches        the order: one file name per line (# comments, blank lines ok)
#   fork/patches/<name>.patch    one `git format-patch --full-index` commit each; its message says
#                                what the patch is for (Intent), its Kind, and how to verify it
#
# Usage (from the top of a clean checkout):
#   bash fork/patches.sh apply
#     On the overlay commit (fork/sync.sh). Applies each listed patch as one commit, strictly: no
#     3-way merge, no fuzz, so a patch whose context changed upstream stops the run, and the
#     result depends only on the upstream commit and the patch text. Upstream's .gitattributes
#     and any global or system git config are kept out (merge drivers, filters, eol and encoding
#     conversion). Exit 0 applied (or no patches), 1 a patch doesn't apply or is malformed: the
#     branch is left where it was.
#   bash fork/patches.sh import [--onto <upstream commit>]
#     On the fork branch (or a branch off it). Makes the local branch fork-patches: the upstream
#     commit (default: the one HEAD is built on), an overlay commit with HEAD's fork/, and the
#     series applied strictly, one commit each. refs/patches/upstream-head marks the overlay
#     commit. Write a new patch as a commit there. Exit 1 if a patch doesn't apply: the branch
#     keeps the patches before it.
#   bash fork/patches.sh import --continue [--3way]
#     On fork-patches: applies the rest of the series. With --3way a patch whose context moved
#     is merged; on a real conflict it stops (exit 2) with `git am` in progress: fix the files,
#     `git add` them, and run `import --continue` again.
#   bash fork/patches.sh export [<branch>]
#     On the fork branch again. Writes the commits after refs/patches/upstream-head on <branch>
#     (default fork-patches) into fork/patches (files and .patches, replacing what is there) and
#     leaves them uncommitted. Each commit needs Intent: and Kind: lines and a
#     `Fork-Patch: <name>.patch` trailer, and may change upstream files only. The written series
#     is replayed onto the upstream commit and must give exactly the branch's trees.
set -euo pipefail

dir=fork/patches
list="$dir/.patches"
work_branch=fork-patches
base_ref=refs/patches/upstream-head
# Outranks .gitattributes: every attribute that could change what a patch produces (conversion,
# filters, merge driver) is unset for the whole run.
override='* -text -eol -filter -diff -ident -working-tree-encoding merge=text'
# The same for writing patches, except that every file is diffed as text.
export_override='* -text -eol -filter -ident -working-tree-encoding diff merge=text'
# Committed with the patches: upstream's `* text=auto eol=lf` would otherwise turn the CRLF lines
# of a patch to a CRLF file into LF when the patch file itself is committed.
patches_attrs='* -text -eol -filter -ident -working-tree-encoding'
die() { echo "fork/patches.sh: $*" >&2; exit 1; }
# Every git call: hooks, fsmonitor and global/system config off (a filter or merge driver defined
# there could run, or change a result, because of upstream's .gitattributes).
pgit() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 command git -c core.hooksPath=/dev/null \
    -c core.fsmonitor=false -c core.autocrlf=false -c core.safecrlf=false -c apply.whitespace=nowarn \
    -c am.threeWay=false -c am.keepcr=true "$@"
}

# --- the attribute override -------------------------------------------------------------------
# The files were checked out under upstream's attributes (eol=crlf turns LF blobs into CRLF
# files, for one), so they are checked out again under ours, and again under upstream's at the
# end: the working tree always matches the attributes in force. An import stopped by a conflict
# keeps the override in place until it is continued; what was there before is kept in $state.
attrs_active=false
recheckout() { rm -f "$gitdir/index" && pgit reset -q --hard; } # reset alone skips "clean" entries
attrs_on() { # attrs_on [<attribute line>]: put the override in place (no checkout)
  if [[ "$attrs_active" == false ]]; then
    if [[ -e "$state" ]]; then
      had_attrs="$(head -1 "$state")"; saved="$(tail -n +2 "$state")"
    elif [[ -e "$attrs" ]]; then
      had_attrs=true; saved="$(cat "$attrs")"
    else
      had_attrs=false; saved=""
    fi
  fi
  mkdir -p "$commondir/info"
  printf '%s\n' "${1:-$override}" > "$attrs"
  attrs_active=true
}
attrs_back() { # attrs_back [--no-checkout]: put back what was there before, check out again
  attrs_active=false
  if [[ "$had_attrs" == true ]]; then printf '%s\n' "$saved" > "$attrs"; else rm -f "$attrs"; fi
  rm -f "$state"
  [[ "${1:-}" == --no-checkout ]] || recheckout
}
attrs_keep() { # leave the override in place for `import --continue`
  printf '%s\n%s\n' "$had_attrs" "$saved" > "$state"
  attrs_active=false
}
on_exit() { [[ "$attrs_active" == false ]] || attrs_back "${exit_checkout:-}" || true; }
trap on_exit EXIT

# --- the series ---------------------------------------------------------------------------------
valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.patch$ ]]; }
read_list() { # read_list [lax]: fills names[] from fork/patches/.patches in the working tree;
  # dies on a bad entry unless lax (apply checks each entry when it reaches it)
  names=()
  [[ -f "$list" && ! -L "$list" ]] || return 0
  local line name
  while IFS= read -r line || [[ -n "$line" ]]; do
    name="${line%%#*}"
    name="${name//[[:space:]]/}"
    [[ -n "$name" ]] || continue
    [[ "${1:-}" == lax ]] || valid_name "$name" || { fail_hook; die "bad patch name in .patches: $name"; }
    names+=("$name")
  done < "$list"
}
fail_hook() { :; } # what to undo before dying; set by each command

trailer_of() { pgit log -1 --format='%(trailers:key=Fork-Patch,valueonly)' "$1" | head -1; }
# A patch changes upstream's files only, never our own fork/ (that is the overlay commit's).
# Asked of git by pathspec, so git's quoting of unusual names ("fork/caf\303\251") can't hide a
# path, and no pipeline: `git diff | grep -q` under pipefail read "no" when grep stopped early
# and git died of SIGPIPE (measured: 20,000 paths after fork/x, exit 141 every time).
touches_fork() { [[ -n "$(pgit diff --name-only -z --no-renames "$1" "$2" -- ':(literal)fork')" ]]; }

am_one() { # am_one <name> <strict|3way>: one `git am`; output in $am_out
  local file="$dir/$1" mode=--no-3way
  [[ -f "$file" && ! -L "$file" ]] || { am_out="patch $1 is listed but missing (or a symlink)"; return 3; }
  [[ "$2" == 3way ]] && mode=--3way
  am_out="$(pgit am --quiet "$mode" --keep-cr --whitespace=nowarn --committer-date-is-author-date -- "$file" 2>&1)"
}
check_commit() { # check_commit <before> <name>: the commit am just made is one patch commit
  [[ "$(pgit rev-list --count "$1..HEAD")" == 1 ]] || { echo "patch $2 made more than one commit"; return 1; }
  [[ "$(trailer_of HEAD)" == "$2" ]] || { echo "patch $2 has no 'Fork-Patch: $2' trailer"; return 1; }
  ! touches_fork "$1" HEAD || { echo "patch $2 changes fork/; it may only change upstream files"; return 1; }
}

setup() {
  cd "$(pgit rev-parse --show-toplevel)"
  gitdir="$(pgit rev-parse --absolute-git-dir)"
  # info/attributes is read from the common git dir, also in a linked worktree (the index and
  # rebase-apply/ are the worktree's own).
  commondir="$(cd "$(pgit rev-parse --git-common-dir)" && pwd)"
  attrs="$commondir/info/attributes"
  state="$gitdir/fork-patches-attributes"
}
# pgit hides the global config, which is where a session's identity usually is; commits made here
# (the overlay commit, the patch commits' committer) use it, as plain git would.
use_identity() {
  local v
  for v in name email; do
    local val; val="$(command git config "user.$v" || true)"
    [[ -n "$val" ]] || continue
    [[ $v == name ]] && export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$val}" GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$val}"
    [[ $v == email ]] && export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$val}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$val}"
  done
  return 0
}
require_clean() { [[ -z "$(pgit status --porcelain)" ]] || die "the working tree has changes"; }
am_in_progress() { [[ -d "$gitdir/rebase-apply" ]]; }

# --- apply (fork/sync.sh) -------------------------------------------------------------------------
cmd_apply() {
  [[ -f "$list" && ! -L "$list" ]] || exit 0 # no patch lane in use yet
  require_clean
  start="$(pgit rev-parse HEAD)"
  fail() {
    pgit am --abort > /dev/null 2>&1 || true
    pgit reset -q --hard "$start" || true
    die "$1" # on_exit puts the attributes back and checks out again
  }
  attrs_on
  recheckout
  fail_hook() { pgit reset -q --hard "$start" || true; }
  read_list lax
  local name before n=0 why
  for name in "${names[@]}"; do
    valid_name "$name" || fail "bad patch name in .patches: $name"
    before="$(pgit rev-parse HEAD)"
    am_one "$name" strict || { [[ $? == 3 ]] && fail "$am_out"; fail "patch $name no longer applies"; }
    why="$(check_commit "$before" "$name")" || fail "$why"
    n=$((n + 1))
  done
  attrs_back
  echo "fork/patches.sh: applied $n patch(es)"
}

# --- import -------------------------------------------------------------------------------------
series() { # series <strict|3way>: apply the listed patches that fork-patches doesn't have yet
  local mode=$1 applied=() name before why k total
  read_list
  total=${#names[@]}
  mapfile -t applied < <(pgit log --reverse --format='%(trailers:key=Fork-Patch,valueonly)' "$base_ref..HEAD" | sed '/^$/d')
  [[ ${#applied[@]} == "$(pgit rev-list --count "$base_ref..HEAD")" ]] ||
    die "a commit on $work_branch has no Fork-Patch trailer; give it one, or start again"
  for ((k = 0; k < ${#applied[@]}; k++)); do
    [[ $k -lt $total && "${applied[k]}" == "${names[k]}" ]] ||
      die "$work_branch doesn't follow fork/patches/.patches (commit $((k + 1)) is ${applied[k]}); export it, or start again"
  done
  attrs_on
  recheckout
  for ((; k < total; k++)); do
    name="${names[k]}"
    before="$(pgit rev-parse HEAD)"
    if ! am_one "$name" "$mode"; then
      if [[ "$mode" == 3way ]] && am_in_progress; then
        attrs_keep
        printf '%s\n' "$am_out" >&2
        echo "fork/patches.sh: patch $name conflicts ($k of $total applied); \`git am\` is in progress." >&2
        echo "  Fix the files, \`git add\` them, then: bash fork/patches.sh import --continue" >&2
        exit 2
      fi
      pgit am --abort > /dev/null 2>&1 || true
      pgit reset -q --hard "$before"
      attrs_back
      [[ -z "$am_out" ]] || printf '%s\n' "$am_out" >&2
      echo "fork/patches.sh: patch $name no longer applies ($k of $total applied on $work_branch)." >&2
      echo "  To refresh it: bash fork/patches.sh import --continue --3way" >&2
      exit 1
    fi
    why="$(check_commit "$before" "$name")" || { pgit reset -q --hard "$before"; die "$why"; }
  done
  attrs_back
  echo "fork/patches.sh: $work_branch has $total patch(es) on upstream $(pgit rev-parse --short=10 "$base_ref^")."
  echo "  Make changes as commits there, then on the fork branch: bash fork/patches.sh export"
}

cmd_import() {
  local onto="" cont=false mode=strict
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --onto) [[ $# -ge 2 ]] || die "--onto needs a commit"; onto="$2"; shift 2 ;;
      --continue) cont=true; shift ;;
      --3way) mode=3way; shift ;;
      *) die "usage: fork/patches.sh import [--onto <upstream commit>] | import --continue [--3way]" ;;
    esac
  done
  if [[ "$cont" == true ]]; then
    [[ -z "$onto" ]] || die "--onto starts an import; --continue carries one on"
    [[ "$(pgit branch --show-current)" == "$work_branch" ]] || die "not on $work_branch"
    pgit rev-parse -q --verify "$base_ref" > /dev/null && pgit merge-base --is-ancestor "$base_ref" HEAD ||
      die "$base_ref is missing or not under $work_branch; start again with import"
    if am_in_progress; then
      [[ -e "$state" && "$(cat "$gitdir/rebase-apply/last" 2> /dev/null)" == 1 && "$(cat "$gitdir/rebase-apply/next" 2> /dev/null)" == 1 ]] ||
        die "the \`git am\` in progress wasn't started by import; finish or abort it yourself"
      [[ -z "$(pgit diff --name-only --diff-filter=U)" ]] || die "fix the conflicts and \`git add\` the files first"
      # The checkout after the series would discard anything not staged.
      pgit diff --quiet || die "unstaged changes: \`git add\` the resolution (nothing else) first"
      attrs_on # the stopped import's override, with what was there before it (from $state)
      local before name why
      before="$(pgit rev-parse HEAD)"
      pgit am --continue > /dev/null 2>&1 || { attrs_keep; die "\`git am --continue\` failed; see \`git status\`"; }
      name="$(trailer_of HEAD)"
      why="$(check_commit "$before" "$name")" || { pgit reset -q --hard "$before"; die "$why"; }
    else
      require_clean
    fi
    series "$mode"
    return
  fi
  [[ "$mode" == strict ]] || die "--3way goes with --continue"
  require_clean
  ! am_in_progress || die "\`git am\` is in progress here"
  pgit rev-parse -q --verify "HEAD:fork" > /dev/null || die "HEAD has no fork/; run this on the fork branch"
  ! pgit show-ref -q --verify "refs/heads/$work_branch" ||
    die "branch $work_branch exists; export it first, or delete it (git branch -D $work_branch)"
  local src base overlay tree
  src="$(pgit rev-parse HEAD)"
  if [[ -n "$onto" ]]; then
    base="$(pgit rev-parse -q --verify "$onto^{commit}")" || die "not a commit: $onto"
  else
    overlay="$(pgit log --first-parent --format=%H -n 1 --grep='^fork: overlay files$' HEAD)"
    [[ -n "$overlay" ]] || die "no overlay commit under HEAD; give the upstream commit with --onto"
    base="$(pgit rev-parse "$overlay^1")"
  fi
  ! pgit rev-parse -q --verify "$base:fork" > /dev/null || die "${base:0:10} has fork/; --onto takes an upstream commit"
  # The overlay commit as fork/sync.sh makes it: upstream's tree with HEAD's fork/ (built without
  # a checkout, so fork/, this script included, never leaves the working tree).
  tree="$({ pgit ls-tree -z "$base" | grep -zv $'\tfork$' || true; printf '040000 tree %s\tfork\0' "$(pgit rev-parse "$src:fork")"; } | pgit mktree -z)"
  overlay="$(pgit commit-tree "$tree" -p "$base" -m "fork: overlay files" -m "Fork-owned files carried from ${src}.")"
  pgit checkout -q -b "$work_branch" "$overlay"
  pgit update-ref "$base_ref" "$overlay"
  series strict
}

# --- export -------------------------------------------------------------------------------------
cmd_export() {
  [[ $# -le 1 ]] || die "usage: fork/patches.sh export [<branch>]"
  local ref="${1:-$work_branch}" tip base c name msg kind n=0 k
  tip="$(pgit rev-parse -q --verify "$ref^{commit}")" || die "not a commit: $ref"
  base="$(pgit rev-parse -q --verify "$base_ref")" || die "$base_ref is missing; run import first"
  pgit merge-base --is-ancestor "$base" "$tip" || die "$ref doesn't start at $base_ref"
  [[ "$(pgit branch --show-current)" != "$work_branch" ]] || die "switch to the fork branch first"
  pgit rev-parse -q --verify "HEAD:fork" > /dev/null || die "HEAD has no fork/; run this on the fork branch"
  require_clean
  [[ -z "$(pgit rev-list --min-parents=2 "$base..$tip")" ]] || die "$ref has a merge after $base_ref"
  local commits=() seen=" " tmp x
  mapfile -t commits < <(pgit rev-list --reverse "$base..$tip")
  # Everything export will write must be a plain file or absent, so nothing is half-replaced.
  [[ ! -L "$dir" && ( ! -e "$dir" || -d "$dir" ) ]] || die "$dir is not a directory"
  for x in .patches .gitattributes $(for c in "${commits[@]}"; do trailer_of "$c"; done); do
    [[ ! -e "$dir/$x" && ! -L "$dir/$x" ]] || [[ -f "$dir/$x" && ! -L "$dir/$x" ]] ||
      die "$dir/$x is not a plain file; nothing was written"
  done
  tmp="$(mktemp -d)"
  fail_hook() { rm -rf "$tmp"; }
  for c in "${commits[@]}"; do
    name="$(trailer_of "$c")"
    local what="commit ${c:0:10} ($(pgit log -1 --format=%s "$c"))"
    [[ -n "$name" ]] || { fail_hook; die "$what has no 'Fork-Patch: <name>.patch' trailer"; }
    valid_name "$name" || { fail_hook; die "$what: bad patch name $name"; }
    [[ "$seen" != *" $name "* ]] || { fail_hook; die "$what: $name is used twice"; }
    seen+="$name "
    msg="$(pgit log -1 --format=%B "$c")"
    grep -q '^Intent: .' <<< "$msg" || { fail_hook; die "$what has no 'Intent:' line"; }
    kind="$(sed -n 's/^Kind: *\([A-Za-z-]*\).*/\1/p' <<< "$msg" | head -1)"
    [[ "$kind" =~ ^(temporary|fork-only|incompatible)$ ]] ||
      { fail_hook; die "$what needs 'Kind: temporary', 'Kind: fork-only' or 'Kind: incompatible'"; }
    ! touches_fork "$c^" "$c" || { fail_hook; die "$what changes fork/; a patch may only change upstream files"; }
  done
  # Write the patches. Explicit options, so this repo's own config can't change the text.
  attrs_on "$export_override"
  exit_checkout=--no-checkout # nothing here is checked out under the override
  k=0
  for c in "${commits[@]}"; do
    k=$((k + 1))
    pgit format-patch --stdout -1 --full-index --zero-commit --no-signature --no-stat --no-renames \
      --no-numbered --no-thread --no-attach --no-to --no-cc --no-add-header --no-color --no-relative \
      --encode-email-headers --src-prefix=a/ --dst-prefix=b/ --subject-prefix=PATCH --no-signoff \
      --no-notes --no-base --diff-algorithm=myers -U3 --inter-hunk-context=0 --indent-heuristic \
      -O/dev/null "$c" > "$tmp/$(trailer_of "$c")" ||
      { fail_hook; die "format-patch failed for ${c:0:10}"; }
  done
  # Read each mailbox back the way `git am` splits it (a "---" line in a message ends the message
  # there): the message it gives must still carry the trailer, Intent and Kind.
  local subject
  for c in "${commits[@]}"; do
    name="$(trailer_of "$c")"
    pgit mailinfo --no-scissors --quoted-cr=nowarn "$tmp/$name.msg" "$tmp/$name.diff" < "$tmp/$name" > "$tmp/$name.info" ||
      { fail_hook; die "patch $name can't be read back as a mail"; }
    subject="$(sed -n 's/^Subject: //p' "$tmp/$name.info")"
    [[ "$({ printf '%s\n\n' "$subject"; cat "$tmp/$name.msg"; } | pgit interpret-trailers --parse | sed -n 's/^Fork-Patch: //p' | head -1)" == "$name" ]] &&
      grep -q '^Intent: .' "$tmp/$name.msg" && grep -q '^Kind: ' "$tmp/$name.msg" ||
      { fail_hook; die "patch $name loses its Fork-Patch, Intent or Kind line when git am reads it (a '---' line in the message?)"; }
  done
  # Replay them the way the sandbox's host check does (bin/fork-sandbox): on the overlay tree, in
  # a separate index, with the override (apply --cached reads .gitattributes from the index).
  attrs_on
  local t
  GIT_INDEX_FILE="$tmp/index" pgit read-tree "$base" || { fail_hook; die "read-tree failed"; }
  for c in "${commits[@]}"; do
    name="$(trailer_of "$c")"
    GIT_INDEX_FILE="$tmp/index" pgit apply --cached -- "$tmp/$name" > /dev/null 2>&1 &&
      t="$(GIT_INDEX_FILE="$tmp/index" pgit write-tree)" && [[ "$t" == "$(pgit rev-parse "$c^{tree}")" ]] ||
      { fail_hook; die "patch $name doesn't replay to ${c:0:10}'s tree; nothing was written"; }
  done
  attrs_back --no-checkout
  # Replace fork/patches with the series (the working tree only; review and commit it).
  mkdir -p "$dir"
  find "$dir" -maxdepth 1 \( -name '*.patch' -o -name .patches -o -name .gitattributes \) \( -type f -o -type l \) -delete
  if [[ ${#commits[@]} -gt 0 ]]; then
    printf '%s\n' "$patches_attrs" > "$dir/.gitattributes"
    { echo "# The order fork/sync.sh applies these in. Written by fork/patches.sh export."
      for c in "${commits[@]}"; do name="$(trailer_of "$c")"; cp -- "$tmp/$name" "$dir/$name"; echo "$name"; n=$((n + 1)); done
    } > "$list"
  fi
  rmdir "$dir" 2> /dev/null || true
  rm -rf "$tmp"
  echo "fork/patches.sh: exported $n patch(es) to $dir; replayed onto upstream $(pgit rev-parse --short=10 "$base^"): same trees."
  pgit status --short -- "$dir" fork
}

setup
cmd="${1:-}"
[[ $# -gt 0 ]] && shift
case "$cmd" in
  apply) [[ $# == 0 ]] || die "usage: fork/patches.sh apply"; cmd_apply ;;
  import) use_identity; cmd_import "$@" ;;
  export) cmd_export "$@" ;;
  *) die "usage: fork/patches.sh apply | import [--onto <commit>] | import --continue [--3way] | export [<branch>]" ;;
esac
exit 0
