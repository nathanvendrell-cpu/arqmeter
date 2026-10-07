// Public API: https://code.claude.com/docs/en/plugins/mods/reference
// No polling, model calls, auth reads, transcript access or workflow changes.
export function quotaInput(event, now) {
  if (!event?.changed?.includes("rateLimits") || !Array.isArray(event.rateLimits) ||
      !Number.isFinite(now)) return null;
  const limits = {};
  for (const kind of ["five_hour", "seven_day"]) {
    const matches = event.rateLimits.filter(value => value?.kind === kind);
    if (matches.length !== 1) continue; // Never guess between conflicting readings.
    const value = matches[0];
    const reset = typeof value.resetsAt === "string" ? Date.parse(value.resetsAt) : NaN;
    if (typeof value.percentUsed !== "number" || !Number.isFinite(value.percentUsed) ||
        value.percentUsed < 0 || value.percentUsed > 100 || !Number.isFinite(reset) ||
        reset <= now) continue;
    limits[kind] = { used_percentage: value.percentUsed, resets_at: reset / 1000 };
  }
  if (!Object.keys(limits).length) return null;
  return { rate_limits: limits };
}

export function register(on) {
  let lastDelivered = "";
  let deliveryQueue = Promise.resolve();
  on("session.measure", async ($, event, next) => {
    // Preserve the engine's event unchanged, including other installed mods.
    const result = await next(event);
    if (!event?.changed?.includes("rateLimits")) return result;
    const deliver = deliveryQueue.then(async () => { try {
      const now = await $.clock.now();
      const input = quotaInput(event, now);
      if (!input) return result;
      const signature = JSON.stringify(input.rate_limits);
      if (signature === lastDelivered) return result;
      const userDirectory = await $.env.get("HOME");
      if (typeof userDirectory !== "string" || !userDirectory.startsWith("/") ||
          userDirectory === "/" || userDirectory.includes("\0")) return result;
      const app = `${userDirectory}/Applications/Arqmeter.app/Contents`;
      // Older rollback binaries must never accidentally open a second GUI.
      const capability = await $.process.run([
        "/usr/libexec/PlistBuddy", "-c", "Print :ARQClaudeStatusBridge", `${app}/Info.plist`,
      ], { timeoutMs: 1000 });
      if (capability.exitCode !== 0 || capability.stdout.trim() !== "true") return result;
      // The existing importer projects only official rate_limits, validates and
      // atomically replaces its 0600 cache. This receipt is not a server timestamp.
      // The synthetic receipt ID contains no user/session data; it prevents the
      // transport's fingerprint from merging equal readings after a real reset.
      input.session_id = `arqmeter-mod-receipt:${now}`;
      const delivery = await $.process.run([
        `${app}/MacOS/Arqmeter`, "--capture-claude-status",
      ], { stdin: JSON.stringify(input), timeoutMs: 2000 });
      if (delivery.exitCode === 0) {
        lastDelivered = signature;
        await $.store.set("lastReceipt", {
          schemaVersion: 1,
          source: "Claude Code Mods · session.measure · rateLimits",
          receivedAt: new Date(now).toISOString(),
          serverObservedAt: null,
          rateLimits: input.rate_limits,
          delivered: true,
        });
      }
    } catch {
      // Never interrupt a user's turn or fabricate a quota when delivery fails.
    } });
    deliveryQueue = deliver.catch(() => {});
    await deliver;
    return result;
  });
}
