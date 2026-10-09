# shellcheck shell=bash
# lib.sh: helpers shared by the auth chart's tests (sourced, not run).
#
#   auth_chart_copy <dest>   copy the chart (without tests/) to <dest> and fill
#                            <dest>/charts/ from the dependency cache that
#                            tests/render.sh uses (RENDER_CACHE, default
#                            ~/.cache/teknoir-render), pulling what is missing.
#                            Never touches the working tree. Calls `yq` with
#                            stdin only, so a docker-wrapped yq function works.
#   auth_render <dest> <out> [helm args...]
#                            helm template auth <dest> --namespace teknoir-auth
#                            [args] > <out> (release and namespace as the
#                            app-of-apps Application deploys it)

AUTH_CHART_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

auth_chart_copy() {
	local dest=$1 cache=${RENDER_CACHE:-${HOME}/.cache/teknoir-render} name version repo key
	rm -rf "$dest"
	mkdir -p "$dest"
	(cd "$AUTH_CHART_DIR" && tar --exclude=./tests --exclude=./charts --exclude=./Chart.lock -cf - .) | tar -xf - -C "$dest"
	mkdir -p "$dest/charts"
	while IFS=$'\t' read -r name version repo; do
		[ -n "$name" ] || continue
		key="$cache/$(printf '%s' "$repo" | sed 's#[^A-Za-z0-9._-]#_#g')/$name-$version"
		if ! compgen -G "$key/*.tgz" >/dev/null; then
			rm -rf "$key.tmp" && mkdir -p "$key.tmp"
			helm pull "$name" --repo "$repo" --version "$version" -d "$key.tmp" >/dev/null
			rm -rf "$key" && mv "$key.tmp" "$key"
		fi
		cp "$key"/*.tgz "$dest/charts/"
	done < <(yq -r '.dependencies // [] | .[] | [.name, .version, .repository] | @tsv' <"$dest/Chart.yaml")
}

auth_render() {
	local dest=$1 out=$2
	shift 2
	helm template auth "$dest" --namespace teknoir-auth "$@" >"$out"
}
