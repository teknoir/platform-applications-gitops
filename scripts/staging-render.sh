#!/usr/bin/env bash
# Render a release of platform-applications-gitops the way ArgoCD does (plans/staging-releases.md,
# "enforcement" 1): the root chart with release=<sha>, then every gitops child Application with its own
# helm parameters, then the profile-plugin charts at the pluginChartVersion of profile-controller.
# Read-only: it never talks to a cluster; the only network use is `helm dependency build/update`, the
# plugin chart repository and (with --plugins) its index.
#
#   staging-render.sh --tree DIR --release SHA --out DIR [--release-name TAG] [--cache DIR]
#                     [--plugins auto|none|VERSION] [--plugin-repo URL]
#
#   DIR/root.yaml            the rendered root chart
#   DIR/apps/<name>.yaml     each gitops child, rendered with its Application's parameters
#   DIR/apps.tsv             name, path, namespace (one per child)
#   DIR/plugins/<chart>.yaml each profile-plugin-* chart at the plugin version, default values
#   DIR/plugins.json         {"version": ..., "digests": {chart: index digest}}
#   DIR/failed               names that failed to render (exit status 1)
#
# Children whose chart path is unchanged since an earlier render (same git tree hash, same parameters)
# are copied from the cache (default ~/.cache/staging-release/render), so a warm run renders only what
# changed. Plugin charts are immutable per version and cached by name@version.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="" RELEASE="" RELEASE_NAME="" OUT="" PLUGINS="auto"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/staging-release/render"
PLUGIN_REPO="https://teknoir.github.io/profile-plugins-helm"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tree) TREE=$2; shift 2 ;;
    --release) RELEASE=$2; shift 2 ;;
    --release-name) RELEASE_NAME=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --cache) CACHE=$2; shift 2 ;;
    --plugins) PLUGINS=$2; shift 2 ;;
    --plugin-repo) PLUGIN_REPO=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$TREE" && -n "$OUT" ]] || { usage >&2; exit 2; }
[[ -d "$TREE/charts/app-of-apps" ]] || { echo "$TREE is not a platform-applications-gitops checkout" >&2; exit 2; }
for t in helm python3 git; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done

mkdir -p "$OUT/apps" "$OUT/plugins" "$CACHE" "$CACHE/deps"
rm -f "$OUT"/apps/*.yaml "$OUT"/plugins/*.yaml "$OUT/failed" "$OUT/apps.tsv"

# --- the root --------------------------------------------------------------------------------
ROOT_ARGS=()
[[ -n "$RELEASE" ]] && ROOT_ARGS+=(--set-string "release=$RELEASE")
[[ -n "$RELEASE_NAME" ]] && ROOT_ARGS+=(--set-string "releaseName=$RELEASE_NAME")
helm template app-of-apps "$TREE/charts/app-of-apps" --namespace teknoir-system "${ROOT_ARGS[@]}" > "$OUT/root.yaml"

# name<TAB>path<TAB>namespace<TAB>release-name<TAB>json-params for every gitops child
python3 -I - "$OUT/root.yaml" > "$OUT/apps.full.tsv" <<'PY'
import json, sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not isinstance(d, dict) or d.get("kind") != "Application":
        continue
    spec = d["spec"]; src = spec.get("source") or {}
    if not str(src.get("repoURL", "")).rstrip("/").endswith("platform-applications-gitops"):
        continue
    helm = src.get("helm") or {}
    print("\t".join([d["metadata"]["name"], src["path"], spec["destination"]["namespace"],
                     helm.get("releaseName", d["metadata"]["name"]),
                     json.dumps(helm.get("parameters") or [], separators=(",", ":"))]))
PY
cut -f1-3 "$OUT/apps.full.tsv" > "$OUT/apps.tsv"

# --- the children ----------------------------------------------------------------------------
render_child() { # name path ns relname params-json
  local name=$1 path=$2 ns=$3 rel=$4 params=$5 tree key cached work args=()
  tree=$(git -C "$TREE" rev-parse "HEAD:$path" 2>/dev/null || echo nogit)
  key=$(printf '%s\0%s\0%s\0%s\0%s' "$tree" "$name" "$ns" "$rel" "$params" | sha256sum | cut -c1-40)
  cached="$CACHE/$key.yaml"
  if [[ "$tree" != nogit && -s "$cached" ]]; then cp "$cached" "$OUT/apps/$name.yaml"; echo "cached   $name"; return 0; fi
  work=$(mktemp -d); cp -a "$TREE/$path/." "$work/"
  if [[ -f "$work/Chart.yaml" ]] && grep -q '^dependencies:' "$work/Chart.yaml"; then
    local dkey; dkey=$(sha256sum "$work/Chart.yaml" "$work/Chart.lock" 2>/dev/null | cut -d' ' -f1 | sha256sum | cut -c1-40)
    if [[ -d "$CACHE/deps/$dkey" ]]; then
      rm -rf "$work/charts"; cp -a "$CACHE/deps/$dkey" "$work/charts"
    else
      if [[ -f "$work/Chart.lock" ]]; then helm dependency build "$work" >/dev/null 2>"$work/dep.err" || { cat "$work/dep.err" >&2; rm -rf "$work"; return 1; }
      else helm dependency update "$work" >/dev/null 2>"$work/dep.err" || { cat "$work/dep.err" >&2; rm -rf "$work"; return 1; }; fi
      [[ -d "$work/charts" ]] && cp -a "$work/charts" "$CACHE/deps/$dkey"
    fi
  fi
  # ArgoCD passes parameters as --set (forceString: --set-string)
  while IFS=$'\t' read -r pn pv pf; do
    [[ -z "$pn" ]] && continue
    if [[ "$pf" == "true" ]]; then args+=(--set-string "$pn=$pv"); else args+=(--set "$pn=$pv"); fi
  done < <(python3 -I -c 'import json,sys
for p in json.loads(sys.argv[1]):
    print("\t".join([p["name"], str(p.get("value","")), "true" if p.get("forceString") else "false"]))' "$params")
  if helm template "$rel" "$work" --namespace "$ns" --include-crds "${args[@]}" > "$OUT/apps/$name.yaml" 2>"$work/err"; then
    [[ "$tree" != nogit ]] && cp "$OUT/apps/$name.yaml" "$cached"
    echo "rendered $name"
  else
    echo "FAILED   $name: $(head -c 400 "$work/err")" >&2
    rm -f "$OUT/apps/$name.yaml"; rm -rf "$work"; return 1
  fi
  rm -rf "$work"
}
failed=()
while IFS=$'\t' read -r name path ns rel params; do
  render_child "$name" "$path" "$ns" "$rel" "$params" || failed+=("$name")
done < "$OUT/apps.full.tsv"
rm -f "$OUT/apps.full.tsv"

# --- profile plugins at pluginChartVersion ---------------------------------------------------
if [[ "$PLUGINS" != "none" ]]; then
  VERSION="$PLUGINS"
  if [[ "$PLUGINS" == "auto" ]]; then
    VERSION=$(python3 -I - "$OUT/apps/profile-controller.yaml" <<'PY' 2>/dev/null || true
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if isinstance(d, dict) and d.get("kind") == "ConfigMap":
        v = (d.get("data") or {}).get("PLUGIN_CHART_VERSION")
        if v: print(v); break
PY
)
  fi
  if [[ -z "$VERSION" ]]; then
    echo "plugins: no pluginChartVersion in the profile-controller render, skipping" >&2
    echo '{"version": null, "digests": {}}' > "$OUT/plugins.json"
  else
    INDEX="$CACHE/plugin-index-$(date +%Y%m%d%H).yaml"
    [[ -s "$INDEX" ]] || curl -fsS -m 60 "$PLUGIN_REPO/index.yaml" -o "$INDEX" || { echo "plugins: cannot fetch $PLUGIN_REPO/index.yaml" >&2; rm -f "$INDEX"; failed+=("plugin-index"); }
    if [[ -s "$INDEX" ]]; then
      python3 -I - "$INDEX" "$VERSION" > "$OUT/plugins.json" <<'PY'
import json, sys, yaml
idx = yaml.safe_load(open(sys.argv[1])); ver = sys.argv[2]; dig = {}
for name, vs in idx["entries"].items():
    if name.startswith("profile-plugin-"):
        for v in vs:
            if v["version"] == ver:
                dig[name] = v["digest"]
print(json.dumps({"version": ver, "digests": dig}, indent=1, sort_keys=True))
PY
      for chart in $(python3 -I -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["digests"])))' "$OUT/plugins.json"); do
        c="$CACHE/plugin-$chart-$VERSION.yaml"
        if [[ ! -s "$c" ]]; then
          helm template "${chart#profile-plugin-}" "$chart" --repo "$PLUGIN_REPO" --version "$VERSION" --namespace teknoir-plugins > "$c" 2>"$CACHE/plugin.err" \
            || { echo "FAILED   $chart@$VERSION: $(head -c 300 "$CACHE/plugin.err")" >&2; rm -f "$c"; failed+=("$chart"); continue; }
        fi
        cp "$c" "$OUT/plugins/$chart.yaml"
      done
      echo "plugins  $VERSION: $(ls "$OUT/plugins" | wc -l) charts"
    fi
  fi
fi

if ((${#failed[@]})); then printf '%s\n' "${failed[@]}" > "$OUT/failed"; echo "render failed for: ${failed[*]}" >&2; exit 1; fi
echo "rendered $(wc -l < "$OUT/apps.tsv") applications into $OUT"
