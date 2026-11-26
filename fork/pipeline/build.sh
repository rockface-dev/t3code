#!/usr/bin/env bash
# Builds one artifact from a commit of this repo, in Docker, and leaves it in <out>/<version>/.
# Publishes nothing.
#   cli  the Linux x64 server/CLI archive (t3-<version>-linux-x64.tar.gz and SHA256SUMS)
#   web  the hosted web app as static files (web/, for app.<domain>)
#
# Usage: fork/pipeline/build.sh <cli|web> [--sha <commit>] [--version <V>] [--env-file <file>]
#   --sha       commit to build (default: HEAD)
#   --version   release version (default: upstream's nightly format with run number 900000+HHMM
#               UTC, which sorts above upstream's nightly of the same day)
#   --env-file  public client config (T3CODE_CLERK_*, T3CODE_RELAY_URL, VITE_HOSTED_APP_URL)
# Environment: T3FORK_WORK_DIR (default <repo>/../build), T3FORK_OUT_DIR (default <repo>/../artifacts).
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
target="${1:-}"
case "$target" in
  cli | web) shift ;;
  *) echo "usage: build.sh <cli|web> [--sha <commit>] [--version <V>] [--env-file <file>]" >&2; exit 2 ;;
esac
sha=HEAD version="" env_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha) sha="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --env-file) env_file="$(realpath "$2")"; shift 2 ;;
    *) echo "build.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
sha="$(git -C "$repo" rev-parse --verify "${sha}^{commit}")"

work_root="$(realpath -m "${T3FORK_WORK_DIR:-$repo/../build}")"
out_root="$(realpath -m "${T3FORK_OUT_DIR:-$repo/../artifacts}")"
work="$work_root/$target-${sha:0:12}-$$"
mkdir -p "$work_root"
git -C "$repo" worktree add --quiet --detach "$work" "$sha"
cleanup() { git -C "$repo" worktree remove --force "$work" || true; }
trap cleanup EXIT

node_version="$(node -p 'require(process.argv[1]).engines.node' "$work/package.json")"
vp_version="$(sed -nE 's/^  vite-plus: ([0-9][^ ]*)$/\1/p' "$work/pnpm-workspace.yaml")"
# package.json's "packageManager" must be exactly "pnpm@<x.y.z>", checked in Node before anything is
# printed: a bare version, a hash suffix or another package manager stops here rather than
# installing a guess.
pnpm_version="$(node -p 'const v = require(process.argv[1]).packageManager; const m = /^pnpm@(\d+\.\d+\.\d+)$/.exec(typeof v === "string" ? v : ""); m ? m[1] : ""' "$work/package.json")"
[[ "$pnpm_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  { echo "build.sh: package.json's packageManager is not pnpm@<x.y.z>" >&2; exit 1; }
# Named by the Dockerfile's own content too, so a changed Dockerfile is never served by an old image.
dockerfile_id="$(sha256sum "$work/fork/pipeline/linux.Dockerfile" | cut -c1-12)"
[[ "$dockerfile_id" =~ ^[0-9a-f]{12}$ ]] || { echo "build.sh: could not hash the Dockerfile" >&2; exit 1; }
image="t3fork-linux-build:node${node_version}-vp${vp_version}-pnpm${pnpm_version}-$dockerfile_id"
docker build --quiet -t "$image" --build-arg "NODE_VERSION=$node_version" \
  --build-arg "VP_VERSION=$vp_version" --build-arg "PNPM_VERSION=$pnpm_version" \
  -f "$work/fork/pipeline/linux.Dockerfile" "$work/fork/pipeline"

# The worktree and the repo's .git keep their host paths so the worktree's gitdir pointer resolves.
# .git is read-only, so VP_GIT_HOOKS=0 stops `vp install` from writing core.hooksPath into it.
env_args=()
[[ -z "$env_file" ]] || env_args=(--env-file "$env_file")
docker run --rm "${env_args[@]}" -e VP_GIT_HOOKS=0 \
  -v "$work:$work" -v "$repo/.git:$repo/.git:ro" \
  -v t3fork-pnpm-store:/root/.local/share/pnpm -v t3fork-cargo-registry:/opt/cargo/registry \
  -v t3fork-vite-plus:/root/.vite-plus \
  -w "$work" "$image" bash "fork/pipeline/$target-steps.sh" "$version" "$sha" \
  < /dev/null

version="$(cat "$work/fork-out/VERSION")"
# The value comes back from the container and becomes a host path.
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]] || {
  echo "build.sh: refusing version '$version'." >&2
  exit 1
}
out_dir="$out_root/$version"
mkdir -p "$out_dir"
cp -r --no-dereference "$work"/fork-out/. "$out_dir/"
echo "built $target $version from $sha"
ls -l "$out_dir"
