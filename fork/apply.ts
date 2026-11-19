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
} as const;

interface Identity {
  readonly domain: string;
  readonly releaseRepository: string;
  readonly telemetryEnabledByDefault: boolean;
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
}

// The desktop app bundles its server, so an environment variable can't be relied on there.
function applyTelemetryDefault() {
  edit(
    "apps/server/src/telemetry/AnalyticsService.ts",
    'enabled: Config.Boolean("T3CODE_TELEMETRY_ENABLED").pipe(Config.withDefault(true)),',
    `enabled: Config.Boolean("T3CODE_TELEMETRY_ENABLED").pipe(Config.withDefault(${identity.telemetryEnabledByDefault})),`,
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

applyAgentRules();
applyDomain();
applyReleaseRepository();
applyRelaySizing();
applyTelemetryDefault();
applyAppIdentity();

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
