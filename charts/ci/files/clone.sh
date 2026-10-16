#!/bin/sh
# Clone $ORG/$REPO at $SHA into /src (init container of every pipeline step).
# The GitHub token is sent as an HTTP header for this process only: it is never
# written to .git/config, so the step's main container (repo code, tests) cannot
# read it from the checkout. Env: ORG REPO SHA, DEPTH (default 1; 0 = full history
# with tags), LFS, SUBMODULES (true/false).
set -eu
token=$(cat /github/token)
auth="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
unset token
cd /src
git init -q .
git remote add origin "https://github.com/$ORG/$REPO.git"
if [ "${DEPTH:-1}" = 0 ]; then
	git -c http.extraHeader="$auth" fetch -q --tags origin '+refs/heads/*:refs/remotes/origin/*'
	git checkout -q --detach "$SHA"
else
	git -c http.extraHeader="$auth" fetch -q --no-tags --depth="${DEPTH:-1}" origin "$SHA"
	git checkout -q --detach FETCH_HEAD
fi
if [ "${SUBMODULES:-false}" = true ]; then
	git -c http.extraHeader="$auth" submodule update -q --init --recursive --depth 1
fi
if [ "${LFS:-false}" = true ]; then
	apk add -q --no-cache git-lfs >/dev/null
	git lfs install --local >/dev/null
	git -c http.extraHeader="$auth" lfs pull
fi
# Steps may run as any user (toolchain images).
chmod -R a+rwX /src
echo "clone: $ORG/$REPO@$(git rev-parse --short=8 HEAD)"
