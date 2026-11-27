#!/usr/bin/env bash
# Runs inside the build container, in a disposable worktree. Builds the hosted web app as static
# files, following apps/web/vercel.ts. Usage: web-steps.sh <version or empty> <sha>
set -euo pipefail

git config --global --add safe.directory '*'
vp install --filter=@t3tools/scripts... --filter=@t3tools/web...
source fork/pipeline/version.sh "${1:-}" "$2"
# VITE_HOSTED_APP_CHANNEL stays unset: the track selector needs upstream's Vercel-only router.
APP_VERSION="$version" vp run --filter @t3tools/web build

brand=production
[[ "$version" =~ -nightly\.[0-9]{8}\.[0-9]+$ ]] && brand=nightly
node scripts/apply-web-brand-assets.ts "$brand" apps/web/dist

mkdir -p fork-out
rm -rf fork-out/web
cp -r apps/web/dist fork-out/web
aasa=fork-out/web/.well-known/apple-app-site-association
# Any app ID under upstream's Apple team (ARK85ZXQ4Z) would hand this domain's links to an app
# upstream controls, whatever the bundle ID. Publish no app links until the team is ours.
if grep -q 'ARK85ZXQ4Z' "$aasa.json"; then
  echo "web-steps.sh: an app ID uses upstream's Apple team; publishing no iOS app links." >&2
  echo '{"applinks":{"details":[]}}' > "$aasa.json"
fi
# Apple fetches the association file without an extension. Upstream rewrites that path on Vercel
# (apps/web/vercel.ts); a plain static host would answer it with the app's HTML instead.
cp "$aasa.json" "$aasa"
# The fork ships no Android app. The source file still carries upstream's signing fingerprints, so
# publishing it would let an app signed with upstream's key claim this domain's links.
echo '[]' > fork-out/web/.well-known/assetlinks.json
cp fork/pipeline/web-headers fork-out/web/_headers
cp fork/pipeline/web-wrangler.jsonc fork-out/wrangler.jsonc
