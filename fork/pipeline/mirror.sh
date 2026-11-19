#!/usr/bin/env bash
# Adds a `build.sh cli` result to an update mirror directory, laid out the way upstream's managed
# policy `limits.updates.feedUrl` expects (docs/user/managed-policy.md, "Updates"): the archive and
# SHA256SUMS under v<version>/, and the channel's feed file at the root. Serve the directory over
# HTTPS and point a machine's policy at it; `t3 update` then installs from it.
#
# Usage: fork/pipeline/mirror.sh <artifacts/<version> dir> <mirror dir>
#        fork/pipeline/mirror.sh --upstream <version> <mirror dir>
# --upstream copies one of upstream's own releases into the mirror without touching the feed, so a
# machine whose policy points here can go back to it: `t3 update <version> --allow-downgrade`.
set -euo pipefail

version_pattern='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$'
if [[ "${1:-}" == "--upstream" ]]; then
  version="$2"
  mirror="$(realpath -m "$3")"
  [[ "$version" =~ $version_pattern ]] || { echo "mirror.sh: refusing version '$version'." >&2; exit 1; }
  archive="t3-$version-linux-x64.tar.gz"
  base="https://github.com/pingdotgg/t3code/releases/download/v$version"
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' EXIT
  curl -fsSL --retry 3 -o "$staging/$archive" "$base/$archive"
  curl -fsSL --retry 3 -o "$staging/SHA256SUMS" "$base/SHA256SUMS"
  (cd "$staging" && sha256sum --check --quiet --ignore-missing SHA256SUMS)
  mkdir -p "$mirror/v$version"
  cp "$staging/$archive" "$staging/SHA256SUMS" "$mirror/v$version/"
  echo "mirrored upstream $version to $mirror (feed unchanged)"
  exit 0
fi

src="$(realpath "$1")"
mirror="$(realpath -m "$2")"
version="$(cat "$src/VERSION")"
[[ "$version" =~ $version_pattern ]] || {
  echo "mirror.sh: refusing version '$version'." >&2
  exit 1
}
archive="t3-$version-linux-x64.tar.gz"
(cd "$src" && sha256sum --check --quiet --ignore-missing SHA256SUMS && [[ -f "$archive" ]])

channel=latest
[[ "$version" =~ -nightly\.[0-9]{8}\.[0-9]+$ ]] && channel=nightly

mkdir -p "$mirror/v$version"
cp "$src/$archive" "$src/SHA256SUMS" "$mirror/v$version/"
# Written last and renamed into place: a client that reads the feed must find the archive.
feed="$mirror/$channel-linux.yml"
printf 'version: %s\nreleaseDate: %s\n' "$version" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > "$feed.tmp"
mv "$feed.tmp" "$feed"
echo "mirrored $version to $mirror ($channel-linux.yml)"
