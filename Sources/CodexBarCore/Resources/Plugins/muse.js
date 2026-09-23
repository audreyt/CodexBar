function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}
function _optionalChain(ops) {
  let lastAccessLHS = undefined;
  let value = ops[0];
  let i = 1;
  while (i < ops.length) {
    const op = ops[i];
    const fn = ops[i + 1];
    i += 2;
    if ((op === "optionalAccess" || op === "optionalCall") && value == null) {
      return undefined;
    }
    if (op === "access" || op === "optionalAccess") {
      lastAccessLHS = value;
      value = fn(value);
    } else if (op === "call" || op === "optionalCall") {
      value = fn((...args) => value.call(lastAccessLHS, ...args));
      lastAccessLHS = undefined;
    }
  }
  return value;
}
defineProvider({
  id: "muse",
  name: "Muse Code",
  endpoints: ["https://api.meta.ai", "https://dev.meta.ai"],
  settings: [{ key: "MUSE_DEVICE_TOKEN", title: "Muse login", type: "secure" }],
  capabilities: ["http-status", "browser-cookies"],
  cookieDomains: ["dev.meta.ai"],
  async fetchUsage(ctx) {
    // Keep the device credential off dashboard requests, which authenticate with the browser session instead.
    const token = ctx.settings.getSecret("MUSE_DEVICE_TOKEN");
    if (!_optionalChain([token, "optionalAccess", (_) => _.startsWith, "call", (_2) => _2("dca:")])) {
      throw ctx.fail.authenticationExpired("Muse Code requires a device-code login. Run `muse login` again.");
    }
    const response = await ctx.http.post("https://api.meta.ai/muse-code/key", {
      body: {},
      headers: { Authorization: `Bearer ${token}`, "x-api-version": "1.0.0", "User-Agent": "CodexBar" },
      timeoutSeconds: 15,
    });
    if (response.status === 401 || response.status === 403) {
      throw ctx.fail.authenticationExpired("Muse Code login was rejected. Run `muse login` again.");
    }
    if (response.status === 429) throw ctx.fail.rateLimited("Muse Code usage requests are rate limited.");
    if (response.status >= 500) throw ctx.fail.providerUnavailable(`Muse Code API returned HTTP ${response.status}.`);
    if (response.status !== 200) throw ctx.fail.apiFailure(`Muse Code API returned HTTP ${response.status}.`);
    const fail = (field) => {
      throw ctx.fail.parseFailure(`Could not parse Muse Code subscription usage: ${field}`);
    };
    const object = (value, field) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail(field);
      return value;
    };
    const number = (value, field) => {
      if (typeof value !== "number" || !Number.isFinite(value)) return fail(field);
      return value;
    };
    const text = (value, field) => {
      if (value === undefined || value === null) return undefined;
      if (typeof value !== "string") return fail(field);
      return value.trim() || undefined;
    };
    const reset = (value) => {
      if (value === undefined || value === null) return undefined;
      const seconds = number(value, "resets_at");
      // Match the native countdown boundary; oversized dates must not discard useful quota data.
      if (seconds <= 0 || seconds > 64092211200) return undefined;
      return ctx.date.unixSeconds(seconds);
    };
    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail("expected JSON");
    }
    const root = object(decoded, "expected a response object");
    for (const key of ["require_payment", "is_subs_active"]) {
      if (root[key] !== undefined && root[key] !== null && typeof root[key] !== "boolean") return fail(key);
    }
    if (root.require_payment === true) {
      throw ctx.fail.permissionDenied("Muse Code requires a payment method. Finish billing at https://dev.meta.ai");
    }
    if (root.is_subs_active !== true) {
      throw ctx.fail.permissionDenied("No Muse Code subscription is active on this login.");
    }
    const plan = text(root.subs_tier_name, "subs_tier_name");
    const rows = [];
    if (plan) rows.push({ label: "Plan", value: plan });
    const identity = {
      email: text(root.user_email, "user_email"),
      loginMethod: _nullishCoalesce(plan, () => "Muse login"),
    };
    const snapshot = {
      details: [{ title: "Muse Code subscription", rows }],
      identity,
      dataConfidence: "unknown",
    };
    // The mint endpoint can confirm a subscription without reporting its quota.
    // Absence is unknown usage, not an unused allowance or a failed login.
    if (root.subs_usage === undefined || root.subs_usage === null) {
      // The dashboard usage page reads the same subscription through a dev.meta.ai session. That source is optional:
      // every failure keeps the confirmed CLI identity, names the reason, and never guesses quota.
      const domain = "dev.meta.ai";
      let reason = "Sign in at https://dev.meta.ai/usage in Chrome, or paste its Cookie header in Muse settings.";
      const unavailable = (message) => {
        reason = message;
        throw new Error(message);
      };
      try {
        const email = identity.email;
        if (!email) return unavailable("The Muse login did not report an account email to match.");
        if (ctx.browser.availability(domain) === "off")
          return unavailable("Meta dashboard cookies are off in Muse settings.");
        const cookie = await ctx.browser.cookieHeader(domain);
        const get = async (path) => {
          let result;
          try {
            result = await ctx.http.get(`https://${domain}${path}`, {
              headers: { Cookie: cookie, Accept: "application/json" },
              timeoutSeconds: 4,
            });
          } catch (error) {
            if (error.transportClass === "cancelled") throw error;
            return unavailable("Meta dashboard could not be reached.");
          }
          if (result.status === 401 || result.status === 403) {
            ctx.browser.rejectCookie(domain);
            return unavailable("Meta dashboard session expired. Sign in again or update its Cookie header.");
          }
          if (result.status !== 200) return unavailable(`Meta dashboard returned HTTP ${result.status}.`);
          reason = "Meta dashboard quota format was not recognized.";
          return object(JSON.parse(result.bodyText), "dashboard response");
        };
        const user = await get("/api/auth/me");
        if (
          _optionalChain([
            text,
            "call",
            (_3) => _3(user.email, "dashboard email"),
            "optionalAccess",
            (_4) => _4.toLowerCase,
            "call",
            (_5) => _5(),
          ]) !== email.toLowerCase()
        ) {
          return unavailable("Meta dashboard account does not match the Muse CLI login.");
        }
        const teams = (await get("/api/portal/teams")).teams;
        if (!Array.isArray(teams) || teams.length !== 1) {
          return unavailable("Meta dashboard team is ambiguous; quota was not selected.");
        }
        const teamID = text(object(teams[0], "dashboard team").team_id, "dashboard team ID");
        if (!teamID || !/^\d+$/.test(teamID)) return fail("dashboard team ID");
        const report = await get(`/api/portal/teams/${teamID}/subscription-quota`);
        if (report.subscription_quota === undefined || report.subscription_quota === null) {
          return unavailable("Meta dashboard did not report subscription quota.");
        }
        const quota = object(report.subscription_quota, "subscription_quota");
        // Weighted counters exceed 2^31 and arrive as decimal strings.
        const weighted = (value, field) => {
          const parsed = typeof value === "string" && /^\d+$/.test(value) ? Number(value) : value;
          if (typeof parsed !== "number" || !Number.isSafeInteger(parsed) || parsed < 0) return fail(field);
          return parsed;
        };
        const percent = (used, limit, field) => {
          const denominator = weighted(limit, `${field} limit`);
          if (denominator <= 0) return fail(`${field} limit`);
          return Math.min(100, (weighted(used, `${field} used`) / denominator) * 100);
        };
        const minutes = number(quota.window_duration_secs, "window_duration_secs") / 60;
        if (!Number.isSafeInteger(minutes) || minutes <= 0) return fail("window_duration_secs");
        const primaryPercent = percent(quota.window_weighted_used, quota.window_weighted_limit, "window");
        const weeklyPercent = percent(quota.weekly_weighted_used, quota.weekly_weighted_limit, "weekly");
        const primaryReset = reset(quota.window_resets_at);
        const weeklyReset = reset(quota.weekly_resets_at);
        rows.push({ label: "5 hours", value: `${ctx.format.number(primaryPercent, { maximumFractionDigits: 0 })}%` });
        rows.push({ label: "Weekly", value: `${ctx.format.number(weeklyPercent, { maximumFractionDigits: 0 })}%` });
        return {
          ...snapshot,
          primary: { usedPercent: primaryPercent, windowMinutes: minutes, resetsAt: primaryReset },
          secondary: { usedPercent: weeklyPercent, windowMinutes: 10080, resetsAt: weeklyReset },
          dataConfidence: "exact",
        };
      } catch (error) {
        if (error.transportClass === "cancelled") throw error;
      }
      rows.push({ label: "Quota", value: "Not included in this login response", secondaryValue: reason });
      return snapshot;
    }
    const usage = object(root.subs_usage, "subs_usage");
    const window = object(usage.window, "missing subscription window");
    const weekly = object(usage.weekly, "missing weekly window");
    const minutes = Math.round(number(window.window_duration_mins, "window_duration_mins"));
    if (!Number.isSafeInteger(minutes) || minutes <= 0) return fail("window_duration_mins");
    const primaryPercent = Math.min(100, Math.max(0, number(window.used_percent, "window.used_percent")));
    const weeklyPercent = Math.min(100, Math.max(0, number(weekly.used_percent, "weekly.used_percent")));
    rows.push({ label: "5 hours", value: `${ctx.format.number(primaryPercent, { maximumFractionDigits: 0 })}%` });
    rows.push({ label: "Weekly", value: `${ctx.format.number(weeklyPercent, { maximumFractionDigits: 0 })}%` });
    return {
      ...snapshot,
      primary: { usedPercent: primaryPercent, windowMinutes: minutes, resetsAt: reset(window.resets_at) },
      secondary: { usedPercent: weeklyPercent, windowMinutes: 10080, resetsAt: reset(weekly.resets_at) },
      dataConfidence: "exact",
    };
  },
});
