import { test, expect, type Response } from '@playwright/test';

// One test: a staging release is verified when the environment serves Backstage past Keycloak, the identity
// refresh answers 200 JSON, and nothing the first party served failed or logged a console error.
//
// Required environment (missing ones fail the test with a message naming them):
//   BASE_URL       environment root, e.g. https://teknoir.cloud
//   TEST_USER      the staging test user (claude-agent@teknoir.cloud)
//   TEST_PASSWORD  its password
//   REVISION       the commit under test; names the screenshot
//
// Read at run time, never at module load: `npx playwright test --list` must work without them and without a browser.

const REQUIRED_ENV = ['BASE_URL', 'TEST_USER', 'TEST_PASSWORD', 'REVISION'] as const;

interface Config {
  base: URL;
  user: string;
  password: string;
  revision: string;
}

function readConfig(): Config {
  const missing = REQUIRED_ENV.filter((name) => !process.env[name]);
  if (missing.length > 0) {
    throw new Error(
      `gitops verify: missing required environment variable(s): ${missing.join(', ')}. ` +
        'Set BASE_URL (the environment root, e.g. https://teknoir.cloud), TEST_USER and TEST_PASSWORD ' +
        '(the staging test user) and REVISION (the commit under test).',
    );
  }
  const base = new URL(process.env.BASE_URL as string);
  if (base.protocol !== 'https:' && base.protocol !== 'http:') {
    throw new Error(`gitops verify: BASE_URL must be an http(s) URL, not ${base.protocol}`);
  }
  return {
    base,
    user: process.env.TEST_USER as string,
    password: process.env.TEST_PASSWORD as string,
    revision: process.env.REVISION as string,
  };
}

// First party is the BASE_URL host and anything below it: Keycloak lives on auth.teknoir.cloud; a CDN or an
// analytics host does not.
function firstParty(rawUrl: string, base: URL): boolean {
  try {
    const url = new URL(rawUrl);
    const sameSite = url.host === base.host || url.host.endsWith('.' + base.host);
    return sameSite && (url.protocol === 'https:' || url.protocol === 'http:');
  } catch {
    return false;
  }
}

// Backstage's identity refresh is /api/auth/<provider>/refresh (the real call is /api/auth/istioVerifiedJWT/refresh):
// a 200 with a JSON body proves the gateway session is live, however the page looks.
function isIdentityRefresh(response: Response, base: URL): boolean {
  if (!firstParty(response.url(), base)) return false;
  if (!/^\/api\/auth\/[^/]+\/refresh$/.test(new URL(response.url()).pathname)) return false;
  if (response.status() !== 200) return false;
  return /json/i.test(response.headers()['content-type'] ?? '');
}

test('staging release is verified', async ({ page }) => {
  const cfg = readConfig();
  const consoleErrors: string[] = [];
  const failedRequests: string[] = [];

  page.on('console', (msg) => {
    if (msg.type() === 'error') consoleErrors.push(msg.text());
  });
  page.on('pageerror', (err) => consoleErrors.push(`uncaught: ${err.message}`));
  page.on('requestfailed', (req) => {
    if (!firstParty(req.url(), cfg.base)) return;
    // A request the browser cancelled for a navigation (SPA route change, the Keycloak round trip) is not a failure.
    const reason = req.failure()?.errorText ?? 'unknown';
    if (reason === 'net::ERR_ABORTED') return;
    failedRequests.push(`${req.method()} ${req.url()} (${reason})`);
  });
  page.on('response', (res) => {
    if (!firstParty(res.url(), cfg.base)) return;
    // Browsers ask for a favicon whether or not the app ships one; a missing one says nothing about the release.
    if (new URL(res.url()).pathname === '/favicon.ico') return;
    if (res.status() >= 400) {
      failedRequests.push(`${res.request().method()} ${res.url()} (${res.status()})`);
    }
  });

  // Set up before the first navigation: the sign-in round trip ends with the app reloading and calling the refresh.
  const refreshed = page.waitForResponse((res) => isIdentityRefresh(res, cfg.base), { timeout: 120_000 });
  // The assertion below awaits it; this only keeps an earlier failure from also reporting an unhandled rejection.
  void refreshed.catch(() => undefined);

  // Follow the redirect from BASE_URL into Keycloak and fill its standard login form ids.
  await page.goto(cfg.base.toString(), { waitUntil: 'domcontentloaded', timeout: 60_000 });
  const username = page.locator('#username');
  try {
    await username.waitFor({ state: 'visible', timeout: 60_000 });
  } catch {
    throw new Error(`expected the Keycloak login form (#username) after ${cfg.base}; landed on ${page.url()}`);
  }
  await username.fill(cfg.user);
  await page.locator('#password').fill(cfg.password);
  await Promise.all([
    page.waitForLoadState('domcontentloaded').catch(() => undefined),
    page.locator('#kc-login').click(),
  ]);

  // After the submit it is one of three things: the app again (signed in), a Keycloak error, or a required
  // action (new password, profile, email) the test user has not completed. Race the three, so a rejected
  // sign-in fails at once instead of after the 120 s deadline. The error text is never the password.
  const keycloakError = page.locator('#input-error, .kc-feedback-text, .alert-error').first();
  const requiredAction = page.locator('#password-new, #kc-update-profile-form, #kc-update-email-form').first();
  const rejected = keycloakError.waitFor({ state: 'visible', timeout: 120_000 }).then(async () => {
    const text = (await keycloakError.innerText().catch(() => '')).trim();
    throw new Error(`Keycloak rejected the sign-in: ${text || 'an error was shown'}`);
  });
  const needsAction = requiredAction.waitFor({ state: 'visible', timeout: 120_000 }).then(() => {
    throw new Error('Keycloak asks for a required action for the test user; complete it by hand');
  });
  const signedIn = page.waitForURL((url) => url.host === cfg.base.host && !url.pathname.startsWith('/oauth2'), {
    timeout: 120_000,
  });
  void rejected.catch(() => undefined);     // a loser's late rejection must not surface as unhandled
  void needsAction.catch(() => undefined);
  void signedIn.catch(() => undefined);
  await Promise.race([signedIn, rejected, needsAction]);

  // Backstage home: the environment's own origin, its header rendered, and the Keycloak form gone.
  await page
    .locator('[data-testid="home-page"], header')
    .first()
    .waitFor({ state: 'visible', timeout: 120_000 });
  await expect(page.locator('#username')).toHaveCount(0);

  const refresh = await refreshed;
  expect(refresh.status(), `identity refresh ${refresh.url()} answered ${refresh.status()}`).toBe(200);
  expect(
    refresh.headers()['content-type'] ?? '',
    `identity refresh ${refresh.url()} is not JSON`,
  ).toMatch(/json/i);

  // Evidence even when a check below fails.
  const screenshot = `/tmp/verify-${cfg.revision}.png`;
  await page.screenshot({ path: screenshot, fullPage: true });
  console.log(`revision ${cfg.revision}: ${cfg.base} loads past Keycloak, signed in as ${cfg.user}`);
  console.log(`screenshot: ${screenshot}`);

  expect(failedRequests, `failed requests to ${cfg.base.host}`).toEqual([]);
  expect(consoleErrors, 'console errors').toEqual([]);
});
