# verify/ — browser verification of a staging release

One Playwright Test spec (TypeScript) that answers "is this release actually serving?" for the staging
environment, past Keycloak:

1. navigates to `BASE_URL` and follows the redirect into Keycloak,
2. signs in with the test user by Keycloak's standard login form ids (`#username`, `#password`, `#kc-login`),
3. waits for the Backstage home (`header` / the home page test id) back on the environment's own origin,
4. asserts Backstage's identity refresh — a request below `/api/auth/` answering 200 with a JSON body — because a
   page that renders while the gateway session is dead is not a working release,
5. collects console errors and every failed first-party request (non-2xx/3xx if the main document, `requestfailed`
   other than a navigation abort) on the `BASE_URL` host and fails when any was seen,
6. writes a full-page screenshot to `/tmp/verify-<REVISION>.png` and prints its path.

A missing environment variable fails the spec immediately with a message that names it. Certificate errors are
never ignored (`ignoreHTTPSErrors: false`): a bad certificate is a finding, not noise.

## Environment

| variable | meaning |
|---|---|
| `BASE_URL` | environment root, e.g. `https://teknoir.cloud` |
| `TEST_USER` | the staging test user (`claude-agent@teknoir.cloud`) |
| `TEST_PASSWORD` | its password (a Secret: `staging-test-user` in namespace `platform`) |
| `REVISION` | the commit under test; used in the screenshot path and the log line |

Never print or screenshot the credentials. The image takes all four as sink values of the Kargo
`analysis-browser.yaml` AnalysisTemplate (P4.2 section 4).

## Locally

```sh
cd verify
npm ci
npx tsc --noEmit                  # typecheck
npx playwright test --list        # collect only: needs no env, no browser, no network
BASE_URL=https://teknoir.cloud TEST_USER=… TEST_PASSWORD=… REVISION=$(git rev-parse HEAD) \
  npx playwright test             # a live run
```

The repository's own test job may run only `npx playwright test --list`; a live URL is never touched from this
repo's checks (the live run belongs to P4.3's rehearsal/import and to Kargo's browser analysis).

## Image

`.github/workflows/verify-image.yml` builds `verify/Dockerfile` as `gitops-verify` through
`teknoir/ci-workflows/.github/workflows/image.yml@main`, on a push to **main** that touches `verify/**` (ci-workflows
`image.yml` refuses other refs) and by `workflow_dispatch`.

```sh
docker build -t gitops-verify verify
docker run --rm -e BASE_URL -e TEST_USER -e TEST_PASSWORD -e REVISION gitops-verify
```

`Dockerfile` pins `mcr.microsoft.com/playwright:v1.65.1-noble` by digest (`@sha256:…`), the image matching the
pinned `@playwright/test` version. It runs as the image's non-root `pwuser`.
