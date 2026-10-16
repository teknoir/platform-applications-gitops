#!/bin/bash
# Release the changed charts of $ORG/$REPO exactly like helm/chart-releaser-action:
# runs that action's own cr.sh (pinned version + sha256) which packages the charts
# changed since the last tag, uploads them as GitHub releases and pushes index.yaml
# to the pages branch. Env: ORG REPO SHA REF, HELM_CONFIG (JSON from plan.py: mode
# release|beta, chartsDir, crAction, crSha256, betaVersionCheck, skipExisting,
# markAsLatest, pagesBranch).
set -euo pipefail
apk add -q --no-cache git curl coreutils jq >/dev/null
cfg() { jq -r --arg k "$1" '.[$k]' <<<"$HELM_CONFIG"; }
BRANCH=${REF#refs/heads/}
MODE=$(cfg mode) CHARTS_DIR=$(cfg chartsDir) CR_ACTION=$(cfg crAction) CR_SHA256=$(cfg crSha256)
BETA_VERSION_CHECK=$(cfg betaVersionCheck) SKIP_EXISTING=$(cfg skipExisting)
MARK_AS_LATEST=$(cfg markAsLatest) PAGES_BRANCH=$(cfg pagesBranch)
export CR_TOKEN
CR_TOKEN=$(cat /github/token)
# git reads the token through a credential helper (from the mounted Secret), so it is
# never written to .git/config or a remote URL.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.https://github.com.helper
export GIT_CONFIG_VALUE_0='!f() { echo username=x-access-token; printf "password=%s\n" "$(cat /github/token)"; }; f'
cd /work
git clone -q --branch "$BRANCH" "https://github.com/${ORG}/${REPO}.git" src
cd src
git checkout -q "$SHA"
git config user.name "teknoir-ci"
git config user.email "ci@teknoir.ai"

if [ "$MODE" = beta ] && [ "$BETA_VERSION_CHECK" = true ]; then
	version=$(find "$CHARTS_DIR" -name Chart.yaml -exec grep '^version:' {} \; | awk '{print $2}')
	if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-.+ ]]; then
		echo "Chart version $version is not in the format X.Y.Z-something"
		exit 1
	fi
	echo "Chart version $version is valid for beta release"
fi

curl -fsSL -o /work/cr.sh "https://raw.githubusercontent.com/helm/chart-releaser-action/${CR_ACTION}/cr.sh"
echo "${CR_SHA256}  /work/cr.sh" | sha256sum -c -
export RUNNER_TOOL_CACHE=/work/tools
# Pre-install the pinned chart-releaser where cr.sh looks for it, so cr.sh never fetches
# an unverified binary.
CR=$(cfg cr) CR_TAR_SHA256=$(cfg crTarSha256)
cr_dir="$RUNNER_TOOL_CACHE/cr/$CR/$(uname -m)"
mkdir -p "$cr_dir"
curl -fsSL -o /work/cr.tar.gz \
	"https://github.com/helm/chart-releaser/releases/download/${CR}/chart-releaser_${CR#v}_linux_amd64.tar.gz"
echo "${CR_TAR_SHA256}  /work/cr.tar.gz" | sha256sum -c -
tar -xzf /work/cr.tar.gz -C "$cr_dir" cr
args=(--owner "$ORG" --repo "$REPO" --charts-dir "$CHARTS_DIR")
[ "$SKIP_EXISTING" = true ] && args+=(--skip-existing)
[ "$MARK_AS_LATEST" = false ] && args+=(--mark-as-latest false)
[ -n "$PAGES_BRANCH" ] && args+=(--pages-branch "$PAGES_BRANCH")
bash /work/cr.sh "${args[@]}"
