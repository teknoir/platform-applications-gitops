#!/usr/bin/env bash
# Render a release of platform-applications-gitops the way ArgoCD does: the root chart with
# release=<sha> (the helm parameter Kargo passes as release=$ARGOCD_APP_REVISION), then every gitops
# child Application with its own helm valueFiles and parameters, then the profile-plugin charts (see --plugins).
# Read-only: it never talks to a cluster; the only network use is `helm dependency build/update` and, in the
# chart-repository plugin mode, the plugin chart repository and its index (tree mode is offline).
#
# valueFiles are resolved the way ArgoCD resolves them in the repository (not in the chart copy the render uses):
# a relative entry against the chart's path in --tree, an absolute one (leading /) against the repository root.
# Each must be a file inside the tree, and its content is part of the cache key.
#
#   staging-render.sh --tree DIR --release SHA --out DIR [--cache DIR]
#                     [--plugins auto|none|tree|VERSION] [--plugin-repo URL]
#
#   DIR/root.yaml            the rendered root chart
#   DIR/apps/<name>.yaml     each gitops child, rendered with its Application's parameters
#   DIR/apps.tsv             name, path, namespace (one per child)
#   DIR/plugins/<chart>.yaml each profile-plugin-* chart, default values
#   DIR/plugins.json         chart-repository mode: {"version": ..., "digests": {chart: index digest}}
#                            tree mode: {"mode": "git", "revision": SHA, "charts": [...]}
#   DIR/failed               names that failed to render (exit status 1)
#
# --plugins:
#   auto     tree mode when the rendered profile-controller config ConfigMap carries a non-empty
#            PLUGIN_GIT_REPO_URL (profile-controller renders the plugin chart from this repository), else the
#            chart-repository mode at the ConfigMap's PLUGIN_CHART_VERSION (the published repository, today)
#   tree     every plugins/charts/profile-plugin-* of --tree, offline and at the default values: the imported
#            charts (CI v4 P9.1) are rendered, linted and kubeconformed from day one; the one dependency (emqx)
#            is vendored in the tree, so no repository is fetched
#   none     no plugin charts
#   VERSION  chart-repository mode at VERSION
#
# Children whose chart content is unchanged since an earlier render (the same hash of the chart directory's
# files, tracked or untracked-but-not-ignored, and the same parameters) are copied from the cache (default
# ~/.cache/gitops-render), so a warm run renders only what changed: an uncommitted template edit
# invalidates it. Plugin charts are immutable per version and cached by name@version; a tree plugin chart is
# cached by the content hash of its directory, so a gitops revision that changes it renders it again.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="" RELEASE="" OUT="" PLUGINS="auto"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/gitops-render"
PLUGIN_REPO="https://teknoir.github.io/profile-plugins-helm"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tree) TREE=$2; shift 2 ;;
    --release) RELEASE=$2; shift 2 ;;
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
for t in helm python3 git realpath; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done
TREE_ABS=$(realpath "$TREE")

mkdir -p "$OUT/apps" "$OUT/plugins" "$CACHE" "$CACHE/deps"
rm -f "$OUT"/apps/*.yaml "$OUT"/plugins/*.yaml "$OUT/failed" "$OUT/apps.tsv"

# --- the root --------------------------------------------------------------------------------
ROOT_ARGS=()
[[ -n "$RELEASE" ]] && ROOT_ARGS+=(--set-string "release=$RELEASE")
helm template app-of-apps "$TREE/charts/app-of-apps" --namespace teknoir-system "${ROOT_ARGS[@]}" > "$OUT/root.yaml"

# name<TAB>path<TAB>namespace<TAB>release-name<TAB>json-params<TAB>json-valueFiles for every gitops child
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
                     json.dumps(helm.get("parameters") or [], separators=(",", ":")),
                     json.dumps(helm.get("valueFiles") or [], separators=(",", ":"))]))
PY
cut -f1-3 "$OUT/apps.full.tsv" > "$OUT/apps.tsv"

# --- the children ----------------------------------------------------------------------------
chart_key() { # path: a hash of the chart directory's files by content and name
  # Every file git would see there, tracked or untracked but not ignored (subchart archives are git-ignored; they
  # are cached separately): the git tree hash of a path would ignore uncommitted edits, a content hash does not.
  local f
  git -C "$TREE" ls-files -co --exclude-standard -- "$1" 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sha256sum < "$TREE_ABS/$f" | cut -d' ' -f1)" "$f"
  done | sha256sum | cut -c1-40
}

render_child() { # name path ns relname params-json valuefiles-json
  local name=$1 path=$2 ns=$3 rel=$4 params=$5 vfiles=${6:-[]} ckey key cached work args=()
  local vf resolved vhash=""
  # ArgoCD resolves helm.valueFiles in the repository, so resolve them in $TREE (the chart itself is copied to a
  # temp dir for the render): a relative entry against the chart path, an absolute one against the repository
  # root. Refuse anything outside the tree: the render must not read a file the repository does not have.
  while IFS= read -r vf; do
    [[ -z "$vf" ]] && continue
    if [[ "$vf" == /* ]]; then resolved=$(realpath -m -- "$TREE_ABS$vf"); else resolved=$(realpath -m -- "$TREE_ABS/$path/$vf"); fi
    case "$resolved" in
      "$TREE_ABS"/*) ;;
      *) echo "REFUSED  $name: value file $vf is outside the tree ($resolved)" >&2; return 1 ;;
    esac
    [[ -f "$resolved" ]] || { echo "REFUSED  $name: value file $vf does not exist ($resolved)" >&2; return 1; }
    vhash+="$vf $(sha256sum "$resolved" | cut -d' ' -f1)"$'\n'
    args+=(-f "$resolved")
  done < <(python3 -I -c 'import json,sys
for v in json.loads(sys.argv[1]):
    print(v)' "$vfiles")
  ckey=$(chart_key "$path") || ckey=nogit
  # chart_key hashes the chart's files by content, so uncommitted template edits invalidate the cache; the value
  # files (pins/<group>.yaml, outside the chart) are hashed into vhash the same way.
  key=$(printf '%s\0%s\0%s\0%s\0%s\0%s' "$ckey" "$name" "$ns" "$rel" "$params" "$vhash" | sha256sum | cut -c1-40)
  cached="$CACHE/$key.yaml"
  if [[ "$ckey" != nogit && -s "$cached" ]]; then cp "$cached" "$OUT/apps/$name.yaml"; echo "cached   $name"; return 0; fi
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
    [[ "$ckey" != nogit ]] && cp "$OUT/apps/$name.yaml" "$cached"
    echo "rendered $name"
  else
    echo "FAILED   $name: $(head -c 400 "$work/err")" >&2
    rm -f "$OUT/apps/$name.yaml"; rm -rf "$work"; return 1
  fi
  rm -rf "$work"
}
failed=()
while IFS=$'\t' read -r name path ns rel params vfiles; do
  render_child "$name" "$path" "$ns" "$rel" "$params" "$vfiles" || failed+=("$name")
done < "$OUT/apps.full.tsv"
rm -f "$OUT/apps.full.tsv"

# --- profile plugins -------------------------------------------------------------------------
# render_plugins_tree: every plugins/charts/profile-plugin-* of the tree, offline (the emqx dependency is vendored
# and needs no repository; helm-repos.sh adds nothing for it), at the default values. The imported charts ship by
# gitops revision, not by a version, so each render is cached by the content hash of its chart directory.
render_plugins_tree() {
  local d chart name ckey c
  local charts=()
  for d in "$TREE_ABS"/plugins/charts/profile-plugin-*/; do
    [[ -f "$d/Chart.yaml" ]] || continue
    chart=$(basename "$d")
    charts+=("$chart")
    name=${chart#profile-plugin-}
    ckey=$(chart_key "plugins/charts/$chart") || ckey=nogit
    c="$CACHE/plugin-git-$chart-$ckey.yaml"
    if [[ "$ckey" != nogit && -s "$c" ]]; then
      cp "$c" "$OUT/plugins/$chart.yaml"
      echo "plugins  cached $chart"
      continue
    fi
    if helm template "$name" "$d" --namespace teknoir-plugins > "$OUT/plugins/$chart.yaml" 2>"$CACHE/plugin.err"; then
      [[ "$ckey" != nogit ]] && cp "$OUT/plugins/$chart.yaml" "$c"
      echo "plugins  rendered $chart"
    else
      echo "FAILED   $chart: $(head -c 300 "$CACHE/plugin.err")" >&2
      rm -f "$OUT/plugins/$chart.yaml"
      failed+=("$chart")
    fi
  done
  ((${#charts[@]})) || echo "plugins: no plugins/charts/profile-plugin-* under $TREE_ABS" >&2
  python3 -I - "$OUT/plugins.json" "${RELEASE:-}" ${charts[@]+"${charts[@]}"} <<'PY'
import json, sys
with open(sys.argv[1], "w") as fh:
    json.dump({"mode": "git", "revision": sys.argv[2] or None, "charts": sys.argv[3:]}, fh, indent=1)
    fh.write("\n")
PY
}

if [[ "$PLUGINS" != "none" ]]; then
  MODE=chart VERSION="" GIT_REPO_URL=""
  if [[ "$PLUGINS" == "tree" ]]; then
    MODE=tree
  elif [[ "$PLUGINS" != "auto" ]]; then
    VERSION="$PLUGINS"
  fi
  if [[ "$PLUGINS" == "auto" ]]; then
    # The controller's config ConfigMap says where a profile plugin's chart comes from: PLUGIN_GIT_REPO_URL (non-empty)
    # means this repository (rendered from plugins/charts/ at the release), PLUGIN_CHART_VERSION the published chart
    # repository at that version (today, until the CI v4 P9.1 switch).
    CFG=$(python3 -I - "$OUT/apps/profile-controller.yaml" <<'PY' 2>/dev/null || true
import sys, yaml
version = git = ""
try:
    docs = list(yaml.safe_load_all(open(sys.argv[1])))
except OSError:
    docs = []
for d in docs:
    if not isinstance(d, dict) or d.get("kind") != "ConfigMap":
        continue
    data = d.get("data") or {}
    version = version or str(data.get("PLUGIN_CHART_VERSION") or "")
    git = git or str(data.get("PLUGIN_GIT_REPO_URL") or "")
print(f"{version}\t{git}")
PY
)
    IFS=$'\t' read -r VERSION GIT_REPO_URL <<<"$CFG"
    [[ -n "$GIT_REPO_URL" ]] && MODE=tree
  fi
  if [[ "$MODE" == tree ]]; then
    echo "plugins  tree ${RELEASE:-unknown}: $(ls -d "$TREE_ABS"/plugins/charts/profile-plugin-*/ 2>/dev/null | wc -l) charts"
    render_plugins_tree
  elif [[ -z "$VERSION" ]]; then
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
