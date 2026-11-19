# shellcheck shell=bash
# Sourced by the steps scripts after `vp install`. Sets $version from "$1", or resolves upstream's
# nightly format from the commit being built ("$2"). Run number 900000+HHMM UTC sorts above
# upstream's nightly of the same day.
version="${1:-}"
if [[ -z "$version" ]]; then
  run_number=$((900000 + 10#$(date -u +%H%M)))
  version="$(node scripts/resolve-nightly-release.ts --date "$(date -u +%Y%m%d)" \
    --run-number "$run_number" --sha "$2" | sed -n 's/^version=//p')"
fi
[[ -n "$version" ]] || { echo "could not resolve a version." >&2; exit 1; }
mkdir -p fork-out
echo "$version" > fork-out/VERSION
