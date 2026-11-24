# The Playwright image matching @playwright/test in package.json; its Node is the one the browser build expects.
# Pinned by index digest (multi-arch); bump the tag and digest together with @playwright/test.
FROM mcr.microsoft.com/playwright:v1.65.1-noble@sha256:1507cbfc550a63a6b7396791ca4f00df17beb56342d2447b3f106c306f525579

WORKDIR /work

# Dependencies first: a spec change does not reinstall them.
COPY package.json package-lock.json ./
RUN npm ci

COPY playwright.config.ts tsconfig.json ./
COPY tests ./tests

# The image's own non-root user; /work stays writable for test-results in case PLAYWRIGHT_OUTPUT_DIR is overridden.
RUN chown -R pwuser:pwuser /work
USER pwuser

ENTRYPOINT ["npx", "playwright", "test"]
