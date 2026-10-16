#!/bin/sh
# Build and push one image with buildctl against a BuildKit daemon (charts/ci
# templates/buildkitd.yaml). Env: ARGS (base64, one buildctl argument per line,
# from plan.py), PREBUILD (base64 shell, may be empty), BUILDERS (buildkitd
# addresses in order of preference), HARBOR_HOST, REFS (for the log).
set -eu
cd /src
if [ -n "${PREBUILD:-}" ]; then
	printf %s "$PREBUILD" | base64 -d >/tmp/prebuild.sh
	echo "build: running preBuild"
	sh -eu /tmp/prebuild.sh
fi

# Registry credentials for buildctl (sent to the daemon per session).
mkdir -p /tmp/docker
g=$(printf '%s:%s' "$(cat /github/username)" "$(cat /github/token)" | base64 | tr -d '\n')
if [ -n "${HARBOR_HOST:-}" ]; then
	[ -s /harbor/password ] || { echo "build: Harbor robot Secret missing (charts/harbor harbor-config)" >&2; exit 1; }
	h=$(printf '%s:%s' "$(cat /harbor/username)" "$(cat /harbor/password)" | base64 | tr -d '\n')
	printf '{"auths":{"%s":{"auth":"%s"},"ghcr.io":{"auth":"%s"}}}\n' "$HARBOR_HOST" "$h" "$g" >/tmp/docker/config.json
else
	printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$g" >/tmp/docker/config.json
fi
unset h g
export DOCKER_CONFIG=/tmp/docker

addr=
for a in $BUILDERS; do
	if timeout 10 buildctl --addr "$a" debug workers >/dev/null 2>&1; then
		addr=$a
		break
	fi
	echo "build: builder $a is not reachable, trying the next one"
done
[ -n "$addr" ] || { echo "build: no BuildKit daemon reachable ($BUILDERS)" >&2; exit 1; }
echo "build: builder $addr"
echo "build: pushing $REFS" | tr ' ' '\n'

printf %s "$ARGS" | base64 -d >/tmp/args
set --
while IFS= read -r a || [ -n "$a" ]; do
	set -- "$@" "$a"
done </tmp/args
buildctl --addr "$addr" build --progress=plain "$@" --metadata-file /tmp/meta.json
sed -n 's/.*"containerimage.digest": *"\(sha256:[0-9a-f]*\)".*/\1/p' /tmp/meta.json | head -n 1 >/tmp/digest
echo "build: digest $(cat /tmp/digest)"
