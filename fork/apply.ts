// Writes fork/identity.json into a fresh upstream checkout: `node fork/apply.ts [--check]`.
// Every edit asserts the upstream text it replaces, so an upstream rename fails the sync instead
// of shipping upstream's value. Edits are staged in memory and written only when every anchor
// matched, so a failed run leaves the tree untouched. `--check` stages everything, writes nothing.
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

const UPSTREAM = {
  domain: "t3.codes",
  repository: "pingdotgg/t3code",
  desktopAppId: "com.t3tools.t3code",
  bundleIdentifier: "com.t3tools.t3code",
  appleTeamId: "ARK85ZXQ4Z",
  telemetryHost: "ingest.t3.codes",
  telemetryKey: "phc_XOWci4oZP4VvLiEyrFqkFjP4CZn55mjYYBMREK5Wd6m",
} as const;

interface Identity {
  readonly domain: string;
  readonly releaseRepository: string;
  readonly installScriptBaseUrl: string;
  readonly telemetryEnabledByDefault: boolean;
  /** Where this build's analytics go: our own ingest server and the public key it accepts. */
  readonly telemetry: {
    readonly ingestHost: string;
    readonly ingestKey: string;
  };
  readonly desktopAppId: string;
  readonly mobile: {
    readonly bundleIdentifier: string;
    readonly appleTeamId: string;
  };
  readonly relay: {
    readonly postgresClusterSize: string;
    readonly postgresReplicas: number;
    readonly hyperdriveOriginConnectionLimit: number;
  };
}

const checkOnly = process.argv.includes("--check");
const root = NodeChildProcess.execFileSync("git", ["rev-parse", "--show-toplevel"], {
  encoding: "utf8",
}).trim();
const identity = JSON.parse(
  NodeFS.readFileSync(
    process.env.FORK_IDENTITY_FILE ?? NodePath.join(root, "fork/identity.json"),
    "utf8",
  ),
) as Identity;
const failures: string[] = [];
const staged = new Map<string, string>();

function read(file: string): string {
  return staged.get(file) ?? NodeFS.readFileSync(NodePath.join(root, file), "utf8");
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Replace `find` in `file`, failing unless it matches exactly `count` times (or at least once for "some"). */
function edit(
  file: string,
  find: string | RegExp,
  replace: string | ((match: string, ...groups: string[]) => string),
  count: number | "some" = 1,
) {
  if (!staged.has(file) && !NodeFS.existsSync(NodePath.join(root, file))) {
    failures.push(`${file}: file is gone`);
    return;
  }
  const pattern =
    typeof find === "string"
      ? new RegExp(escapeRegExp(find), "g")
      : new RegExp(find.source, find.flags.includes("g") ? find.flags : `${find.flags}g`);
  const content = read(file);
  const matches = content.match(pattern)?.length ?? 0;
  if (count === "some" ? matches === 0 : matches !== count) {
    failures.push(
      `${file}: expected ${count === "some" ? "at least one match" : `${count} match(es)`} for ${pattern}, found ${matches}`,
    );
    return;
  }
  const next = content.replace(
    pattern,
    replace as (substring: string, ...args: unknown[]) => string,
  );
  if (next !== content) staged.set(file, next);
}

/** Swap `from` for `to` inside each anchor, so a value equal to upstream's still checks the anchor. */
function swapIn(
  file: string,
  anchor: string,
  from: string,
  to: string,
  count: number | "some" = 1,
) {
  edit(file, anchor, anchor.split(from).join(to), count);
}

/**
 * `if (<test>) <rest>` at `indent`, as upstream's formatter prints it (100 columns): one line when
 * it fits; otherwise a block's test goes on its own line, and a single statement moves down. A
 * test too long even for that comes out unformatted, and the sandbox's byte check stops the sync.
 */
function formattedIf(indent: string, test: string, rest: string): string {
  const flat = `${indent}if (${test}) ${rest}`;
  if (flat.length <= 100) return flat;
  return rest === "{"
    ? `${indent}if (\n${indent}  ${test}\n${indent}) {`
    : `${indent}if (${test})\n${indent}  ${rest}`;
}

/**
 * `  <name>: Config.String("<env>").pipe(Config.withDefault("<value>")),` as upstream's formatter
 * prints it (100 columns): one line when it fits, otherwise the default on a line of its own.
 */
function formattedDefault(name: string, env: string, value: string): string {
  const flat = `  ${name}: Config.String("${env}").pipe(Config.withDefault("${value}")),`;
  return flat.length <= 100
    ? flat
    : `  ${name}: Config.String("${env}").pipe(\n    Config.withDefault("${value}"),\n  ),`;
}

// Only the hosts the product needs at runtime. Upstream's docs, tests, marketing and help links
// keep naming t3.codes: rewriting them all made every sync churn files upstream edits daily.
function applyDomain() {
  const swap = (file: string, anchor: string, count?: number | "some") =>
    swapIn(file, anchor, UPSTREAM.domain, identity.domain, count);
  swap("packages/shared/src/connectAuth.ts", 'DEFAULT_HOSTED_APP_URL = "https://app.t3.codes"');
  swap("packages/shared/src/providerAuthReturnUrl.ts", 'url.origin === "https://app.t3.codes"');
  // The iOS associated domains (passkeys, Sign in with Apple) derive from these.
  swap("apps/mobile/app.config.ts", 'relyingParty: "clerk.t3.codes"', 3);
  // Universal links for copied thread links; the hosted app's .well-known files must list the app.
  swap("apps/mobile/app.config.ts", 'const HOSTED_APP_HOST = "app.t3.codes";');
  // The relay dashboard's "Connecting: where the time goes" chart matches the relay's own URL.
  swap("infra/relay/src/monitoring.ts", 'url startswith "https://relay.t3.codes/v1/environments/"');
  // Nightly builds approve agent sign-ins on upstream's nightly app; ours serves one hosted app.
  // Until our domain is set, the anchor is only checked, so nightly keeps upstream's nightly host.
  const nightly = 'const NIGHTLY_HOSTED_APP_URL = "https://nightly.app.t3.codes";';
  const ours = `const NIGHTLY_HOSTED_APP_URL = "https://app.${identity.domain}";`;
  const formatted = ours.length <= 100 ? ours : ours.replace(" = ", " =\n  ");
  edit(
    "apps/server/src/cloud/publicConfig.ts",
    nightly,
    identity.domain === UPSTREAM.domain ? nightly : formatted,
  );
}

// Where installed clients look for server archives and desktop release pages.
function applyReleaseRepository() {
  const swap = (file: string, anchor: string, count?: number | "some") =>
    swapIn(file, anchor, UPSTREAM.repository, identity.releaseRepository, count);
  swap(
    "packages/shared/src/cliRelease.ts",
    `const CLI_RELEASE_REPOSITORY = "${UPSTREAM.repository}";`,
  );
  swap(
    "apps/web/src/components/desktopUpdate.logic.ts",
    `const DEFAULT_DESKTOP_RELEASE_REPOSITORY = "${UPSTREAM.repository}";`,
  );
  swap(
    "apps/web/src/components/desktopUpdate.logic.test.ts",
    `https://github.com/${UPSTREAM.repository}/releases`,
    "some",
  );
  swap(
    "apps/desktop/src/app/DesktopStartupRecovery.ts",
    `const RELEASES_URL = "https://github.com/${UPSTREAM.repository}/releases";`,
  );
  // Tests that pin the release lookup to the repository above. check:changed runs a test only when
  // it or the file beside it changes, so these failed unseen until the files beside them changed.
  swap(
    "packages/ssh/src/tunnel.test.ts",
    `"https://github.com/${UPSTREAM.repository}/releases/download"`,
  );
  swap("apps/server/src/cli/update.test.ts", `"/repos/${UPSTREAM.repository}/releases"`);
  // The server refreshes its model list from this file at run time. Read from our pushed branch,
  // so an upstream edit reaches our users only after a sync passed its checks.
  swapIn(
    "apps/server/src/provider/ModelManifest.ts",
    `"https://raw.githubusercontent.com/${UPSTREAM.repository}/main/apps/server/src/provider/model-manifest.json"`,
    `${UPSTREAM.repository}/main/`,
    `${identity.releaseRepository}/fork/`,
  );
  swap("scripts/install.test.ts", `"/${UPSTREAM.repository}/releases/latest"`);
  swap("scripts/install.test.ts", `"/repos/${UPSTREAM.repository}/releases"`);
  // The mobile app's release checks read CLI_RELEASE_REPOSITORY too (found by a full test run,
  // BACKLOG M1-08). A longer name pushes three `if` lines past the formatter's 100 columns, so
  // they are written already wrapped: the sandbox compares this script's output byte for byte.
  const mobileTest = "apps/mobile/src/features/settings/environment-maintenance.test.ts";
  swap(mobileTest, `tag:github.com,2008:https://github.com/${UPSTREAM.repository}/releases</id>`);
  swap(mobileTest, `        url === "https://github.com/${UPSTREAM.repository}/releases.atom"\n`);
  const atom = (repository: string) => `url === "https://github.com/${repository}/releases.atom"`;
  edit(
    mobileTest,
    formattedIf("        ", atom(UPSTREAM.repository), "return feed(...nightlies);"),
    formattedIf("        ", atom(identity.releaseRepository), "return feed(...nightlies);"),
  );
  for (const page of [1, 2]) {
    const api = (repository: string) =>
      `url === "https://api.github.com/repos/${repository}/releases?per_page=100&page=${page}"`;
    edit(
      mobileTest,
      formattedIf("        ", api(UPSTREAM.repository), "{"),
      formattedIf("        ", api(identity.releaseRepository), "{"),
    );
  }
  // The CLI installers look up releases in this repository (T3CODE_RELEASE_BASE_URL moves only
  // the downloads), so without this our tree's installer installs upstream's builds.
  swap("scripts/install.sh", `repo="${UPSTREAM.repository}"`);
  swap("scripts/install.ps1", `$repo = "${UPSTREAM.repository}"`);
  // Upstream's download page offers upstream's builds; ours are this repository's releases.
  const releases = `https://github.com/${identity.releaseRepository}/releases`;
  const download = `https://${UPSTREAM.domain}/download`;
  edit(
    "apps/web/src/branding.ts",
    `export const DESKTOP_DOWNLOAD_URL = "${download}";`,
    `export const DESKTOP_DOWNLOAD_URL = "${releases}";`,
  );
  edit(
    "apps/web/src/lib/bootError.ts",
    `const DOWNLOAD_URL = "${download}";`,
    `const DOWNLOAD_URL = "${releases}";`,
  );
  // The Intel-Mac section builds a server from source. A clone checks out our default branch.
  swap("docs/user/install.md", `git clone https://github.com/${UPSTREAM.repository}\n`);
  // ${repo} is the line above's value, and this repository has no main branch.
  edit(
    "scripts/install.sh",
    `Install the desktop app from ${download}, or run a server from source: https://github.com/\${repo}/blob/main/docs/user/install.md#intel-macs`,
    `Install the desktop app from https://github.com/\${repo}/releases, or run a server from source: https://github.com/\${repo}/blob/fork/docs/user/install.md#intel-macs`,
  );
  // Upstream's npm package `t3` installs upstream's builds, and none of ours are on npm: every
  // release of this repository is a self-contained archive, so a missing one points at our releases.
  edit(
    "scripts/install.sh",
    '; releases before the self-contained CLI can only be installed with \\`npm install -g t3@${version}\\`"',
    '; see https://github.com/${repo}/releases"',
  );
  edit(
    "scripts/install.ps1",
    "; releases before the self-contained CLI can only be installed with 'npm install -g t3@$version'\"",
    '; see https://github.com/$repo/releases"',
  );
  edit(
    "scripts/install.sh",
    'fail "unsupported operating system $(uname -s); use the desktop app or npm" ;;',
    'fail "unsupported operating system $(uname -s); use the desktop app" ;;',
  );
  // `npx t3` runs upstream's npm package; the executable this check names is already standalone.
  edit(
    "apps/server/src/cli/install.ts",
    "because the path has % or non-ASCII characters. Keep using npx t3.`,",
    "because the path has % or non-ASCII characters. Run it by its full path instead.`,",
  );
}

// The copyable install commands, `<base>/install.sh` and `<base>/install.ps1`. Upstream's host
// serves upstream's installers. Until our domain serves ours, the base is the raw scripts on this
// repository's branch, which stop with "could not find a stable release" while nothing is released.
function applyInstallScriptBaseUrl() {
  const base = `https://${UPSTREAM.domain}`;
  const swap = (file: string, anchor: string, count?: number | "some") =>
    swapIn(file, anchor, base, identity.installScriptBaseUrl, count);
  const sh = `curl -fsSL ${base}/install.sh | sh`;
  const ps1 = `irm ${base}/install.ps1 | iex`;
  swap("apps/server/src/cli/install.ts", `? "${ps1}"`);
  swap("apps/server/src/cli/install.ts", `: "${sh}";`);
  swap(
    "apps/server/src/cloud/servicePreflight.ts",
    `curl -fsSL ${base}/install.sh | T3CODE_VERSION=\${version} sh`,
  );
  // The formatter wraps a call whose line passes 100 columns, and the sync checks formatting.
  const expectInstall = (host: string) => {
    const argument = `"curl -fsSL ${host}/install.sh | T3CODE_VERSION=9.8.7 sh"`;
    const line = `  expect(reason).toContain(${argument});`;
    return line.length <= 100
      ? `${line}\n`
      : `  expect(reason).toContain(\n    ${argument},\n  );\n`;
  };
  edit(
    "apps/server/src/cloud/servicePreflight.test.ts",
    expectInstall(base),
    expectInstall(identity.installScriptBaseUrl),
  );
  swap("apps/web/src/components/InstallT3Commands.tsx", `<CommandBlock command="${sh}" />`);
  swap("apps/web/src/components/InstallT3Commands.tsx", `<CommandBlock command="${ps1}" />`);
  // The SSH tunnel's remote script, when the remote host can't download the archive.
  swap("packages/ssh/src/tunnel.ts", `install t3 %s on it with ${base}/install.sh (`);
  swap("scripts/install.sh", `#   ${sh}\n`);
  swap("scripts/install.ps1", `#   ${ps1}\n`);
  // The page the installer's Intel-Mac message links to.
  swap("docs/user/install.md", `\n${sh}\n`);
  swap("docs/user/install.md", `\n${ps1}\n`);
}

// The desktop app bundles its server, so an environment variable can't be relied on there.
function applyTelemetryDefault() {
  const file = "apps/server/src/telemetry/AnalyticsService.ts";
  // Upstream: on unless the host is a CI runner. With telemetryEnabledByDefault false it is off
  // unless T3CODE_TELEMETRY_ENABLED says otherwise, and the CI helper's import goes with its only
  // use (an unused import fails upstream's lint).
  const ciDefault = "const enabledByDefault = !isCiEnvironment(hostEnvironment);";
  const ciImport =
    'import { isCiEnvironment, isDoNotTrackSet } from "@t3tools/shared/otelEnvironment";';
  edit(
    file,
    ciDefault,
    identity.telemetryEnabledByDefault ? ciDefault : "const enabledByDefault = false;",
  );
  edit(
    file,
    ciImport,
    identity.telemetryEnabledByDefault
      ? ciImport
      : 'import { isDoNotTrackSet } from "@t3tools/shared/otelEnvironment";',
  );
  // This build's own destination, never upstream's: our ingest server and the public key it
  // accepts (fork/identity.json "telemetry"). Both anchors are exact, so a rotated upstream key or
  // a moved host stops the sync instead of shipping upstream's value.
  const { ingestHost, ingestKey } = identity.telemetry;
  if (!/^https:\/\/[a-z0-9.-]+$/.test(ingestHost)) {
    failures.push("fork/identity.json: telemetry.ingestHost must be https://<host>, no path");
  }
  if (!/^[A-Za-z0-9_-]+$/.test(ingestKey)) {
    failures.push("fork/identity.json: telemetry.ingestKey must be letters, digits, - or _");
  }
  edit(
    file,
    '\n  ingestKey: Config.String("T3CODE_TELEMETRY_KEY").pipe(\n    Config.withDefault("phc_XOWci4oZP4VvLiEyrFqkFjP4CZn55mjYYBMREK5Wd6m"),\n  ),\n',
    `\n${formattedDefault("ingestKey", "T3CODE_TELEMETRY_KEY", ingestKey)}\n`,
  );
  edit(
    file,
    '\n  ingestHost: Config.String("T3CODE_TELEMETRY_HOST").pipe(\n    Config.withDefault("https://ingest.t3.codes"),\n  ),\n',
    `\n${formattedDefault("ingestHost", "T3CODE_TELEMETRY_HOST", ingestHost)}\n`,
  );
  // The user-facing page says where usage events go, so it must name this build's server.
  edit(
    "docs/user/telemetry.md",
    "The server sends usage events to `ingest.t3.codes` under",
    `The server sends usage events to \`${ingestHost.slice("https://".length)}\` under`,
  );
}

function applyAppIdentity() {
  const { mobile } = identity;
  swapIn(
    "scripts/build-desktop-artifact.ts",
    `const DESKTOP_APP_ID = "${UPSTREAM.desktopAppId}";`,
    UPSTREAM.desktopAppId,
    identity.desktopAppId,
  );
  edit(
    "scripts/build-desktop-artifact.test.ts",
    new RegExp(`(?<=[".])${escapeRegExp(UPSTREAM.desktopAppId)}(?=["<.])`),
    identity.desktopAppId,
    "some",
  );
  // The same IDs written as regular expressions, with escaped dots.
  edit(
    "scripts/build-desktop-artifact.test.ts",
    escapeRegExp(UPSTREAM.desktopAppId),
    escapeRegExp(identity.desktopAppId),
    "some",
  );
  swapIn(
    "apps/desktop/src/app/DesktopEnvironment.ts",
    `isDevelopment ? "${UPSTREAM.desktopAppId}.dev" : "${UPSTREAM.desktopAppId}"`,
    UPSTREAM.desktopAppId,
    identity.desktopAppId,
  );
  const config = "apps/mobile/app.config.ts";
  edit(
    config,
    new RegExp(`(iosBundleIdentifier|androidPackage): "${escapeRegExp(UPSTREAM.bundleIdentifier)}`),
    (_, key: string) => `${key}: "${mobile.bundleIdentifier}`,
    6,
  );
  swapIn(
    config,
    `appleTeamId: "${UPSTREAM.appleTeamId}"`,
    UPSTREAM.appleTeamId,
    mobile.appleTeamId,
  );
  // The hosted web app serves these; iOS and Android open thread links in the app only when the
  // files name it. An upstream test (app.config.test.ts) checks them against app.config.ts.
  edit(
    "apps/web/public/.well-known/apple-app-site-association.json",
    `"${UPSTREAM.appleTeamId}.${UPSTREAM.bundleIdentifier}`,
    `"${mobile.appleTeamId}.${mobile.bundleIdentifier}`,
    3,
  );
  edit(
    "apps/web/public/.well-known/assetlinks.json",
    `"package_name": "${UPSTREAM.bundleIdentifier}`,
    `"package_name": "${mobile.bundleIdentifier}`,
    3,
  );
  edit(
    "apps/mobile/app.config.test.ts",
    new RegExp(`(?<=")${escapeRegExp(UPSTREAM.bundleIdentifier)}(?=[".])`),
    mobile.bundleIdentifier,
    "some",
  );
}

// Upstream sizes the relay for its own traffic (three nodes, 40 origin connections, which is over
// the Workers Free cap of about 20). The patterns accept any upstream value, because upstream
// resizes it (PS_80 to PS_160 in November 2026); each must still match exactly once.
function applyRelaySizing() {
  const { relay } = identity;
  const db = "infra/relay/src/db.ts";
  edit(db, /clusterSize: "PS_\d+",/, `clusterSize: "${relay.postgresClusterSize}",`);
  edit(db, /replicas: \d+,/, `replicas: ${relay.postgresReplicas},`);
  edit(
    db,
    /originConnectionLimit: \d+,/,
    `originConnectionLimit: ${relay.hyperdriveOriginConnectionLimit},`,
  );
}

// Codex stops reading instruction files at 32 KiB, so the rules go right under the title. No `m`
// flag: only the file's first line may match, never a `# T3 Code` line in an example further down.
function applyAgentRules() {
  const rules = NodeFS.readFileSync(NodePath.join(root, "fork/agent-rules.md"), "utf8").trim();
  edit("AGENTS.md", /^# T3 Code\n/, (title) => `${title}\n${rules}\n`);
}

/**
 * Checks the result, not the anchors: after every edit, no shipped source may still name upstream's
 * analytics host or key. The edits above replace the one place they are today; this stops the sync
 * if upstream ever adds a second.
 */
function checkNoUpstreamTelemetry() {
  const tracked = NodeChildProcess.execFileSync(
    "git",
    ["ls-files", "-z", "--", "apps", "packages", "infra", "scripts"],
    { cwd: root, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  ).split("\0");
  for (const file of tracked) {
    if (!/\.(ts|tsx|js|mjs|cjs|json|html)$/.test(file) || /\.test\.tsx?$/.test(file)) continue;
    if (!staged.has(file) && !NodeFS.existsSync(NodePath.join(root, file))) continue;
    const content = read(file);
    for (const value of [UPSTREAM.telemetryHost, UPSTREAM.telemetryKey]) {
      if (content.includes(value)) {
        failures.push(`${file}: still names upstream's analytics ${value} after the edits`);
      }
    }
  }
}

applyAgentRules();
applyDomain();
applyReleaseRepository();
applyInstallScriptBaseUrl();
applyRelaySizing();
applyTelemetryDefault();
applyAppIdentity();
checkNoUpstreamTelemetry();

if (failures.length > 0) {
  console.error(
    `fork/apply.ts: ${failures.length} upstream anchor(s) changed; nothing was written:\n- ${failures.join("\n- ")}`,
  );
  process.exit(1);
}
if (checkOnly) {
  console.log("fork/apply.ts: every upstream anchor is present.");
} else {
  for (const [file, content] of staged) NodeFS.writeFileSync(NodePath.join(root, file), content);
  console.log(`fork/apply.ts: updated ${staged.size} file(s).`);
}
