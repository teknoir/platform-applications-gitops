#!/bin/sh
# Clone $ORG/$REPO at $SHA into /src (init container of every pipeline step).
# The GitHub token is sent as an HTTP header for this process only, and only to
# https://github.com/ (never to submodule or LFS hosts a repo could point elsewhere): it
# is never written to .git/config, so the step's main container (repo code, tests)
# cannot read it from the checkout. Env: ORG REPO SHA, DEPTH (default 1; 0 = full history
# with tags), LFS (true/false/auto, default false), SUBMODULES (true/false).
set -eu
# alpine/git installs the LFS smudge filter system-wide (filter.lfs.required=true): without this, `git checkout` would
# try to download LFS objects without the token header and abort on a private repo. Objects are fetched below instead.
export GIT_LFS_SKIP_SMUDGE=1
token=$(cat /github/token)
auth="Authorization: Basic $(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
unset token
cd /src
git init -q .
git remote add origin "https://github.com/$ORG/$REPO.git"
if [ "${DEPTH:-1}" = 0 ]; then
	git -c http.https://github.com/.extraHeader="$auth" fetch -q --tags origin '+refs/heads/*:refs/remotes/origin/*'
	git checkout -q --detach "$SHA"
else
	git -c http.https://github.com/.extraHeader="$auth" fetch -q --no-tags --depth="${DEPTH:-1}" origin "$SHA"
	git checkout -q --detach FETCH_HEAD
fi
if [ "${SUBMODULES:-false}" = true ]; then
	git -c http.https://github.com/.extraHeader="$auth" submodule update -q --init --recursive --depth 1
fi
# Git LFS. LFS=true|false|auto (unset = false). auto pulls the LFS objects when the checkout has
# LFS-tracked files (image builds: a Dockerfile COPY of a pointer file would otherwise ship
# the 130-byte pointer instead of the model). Tests pass false so their pods do not download
# large LFS objects on every push.
tracked=$(git ls-files -- ':(attr:filter=lfs)' | wc -l | tr -d ' ')
if [ "${LFS:-false}" = auto ]; then
	if [ "$tracked" -gt 0 ]; then LFS=true; else LFS=false; fi
fi
if [ "${LFS:-false}" = true ]; then
	# alpine/git ships git-lfs; the apk fallback needs egress, which airgapped installs lack.
	git lfs version >/dev/null 2>&1 || apk add -q --no-cache git-lfs >/dev/null
	git lfs install --local >/dev/null
	git -c http.https://github.com/.extraHeader="$auth" lfs pull
	# `git lfs ls-files` marks an object that is not in the working tree with "-" (present: "*").
	# Fail the step rather than build an image of pointer files.
	lfs_files=$(git lfs ls-files) || { echo 'clone: git lfs ls-files failed' >&2; exit 1; }
	missing=$(printf '%s\n' "$lfs_files" | grep -E '^[0-9a-f]+ - ' || true)
	if [ -n "$missing" ]; then
		echo "clone: LFS objects missing after git lfs pull (files are still pointers):" >&2
		echo "$missing" >&2
		exit 1
	fi
elif [ "$tracked" -gt 0 ]; then
	echo "clone: warning: $tracked file(s) of $ORG/$REPO are in Git LFS but lfs is false: they stay pointer files (set lfs: true or auto)" >&2
fi
# Steps may run as any user (toolchain images).
chmod -R a+rwX /src
echo "clone: $ORG/$REPO@$(git rev-parse --short=8 HEAD)"
