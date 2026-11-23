#!/usr/bin/env bash
# Runs inside the build container, in a disposable worktree. Follows the CLI steps of upstream's
# .github/workflows/release-desktop.yml for linux x64. Usage: cli-steps.sh <version or empty> <sha>
set -euo pipefail
target=x86_64-unknown-linux-gnu

git config --global --add safe.directory '*'
vp install --filter=t3... --filter=@t3tools/web... --filter=@t3tools/scripts...
source fork/pipeline/version.sh "${1:-}" "$2"
# The CLI reports apps/server/package.json's version, and `t3 update` checks it against the target.
node scripts/update-release-package-versions.ts "$version"
vp run --filter t3 build

cargo build --locked --release --manifest-path native/resource-monitor/Cargo.toml --target "$target"
monitor_dir="$(mktemp -d)"
mkdir -p "$monitor_dir/linux-x64"
cp "native/resource-monitor/target/$target/release/t3-resource-monitor" "$monitor_dir/linux-x64/"

brand=production
[[ "$version" =~ -nightly\.[0-9]{8}\.[0-9]+$ ]] && brand=nightly
node scripts/apply-web-brand-assets.ts "$brand" apps/server/dist/client

T3CODE_TELEMETRY_CHANNEL=dev node apps/server/scripts/cli.ts build-exe --verbose
node scripts/build-cli-archive.ts --platform linux --arch x64 --version "$version" \
  --resource-monitor-dir "$monitor_dir" --output-dir release-cli
node scripts/smoke-cli-archive.ts --archive release-cli/*.tar.gz --expect-version "$version"
(cd release-cli && sha256sum t3-*.tar.gz > SHA256SUMS)
mkdir -p fork-out
cp release-cli/t3-*.tar.gz release-cli/SHA256SUMS fork-out/
