#!/usr/bin/env bash
# Validate the manifests scripts/staging-render.sh wrote (root.yaml, apps/, plugins/) with kubeconform
# (.github/workflows/ci.yml). The schemas come from the default kubeconform set plus the datreeio CRDs catalog
# (network); the schema set of pass 2 is what makes that download the only network use besides the schemas.
#
#   kubeconform.sh RENDER_DIR
#
#   pass 1  every *.yaml with -ignore-missing-schemas: many in-house and third-party CRDs have no schema
#   pass 2  only the resources of the kargo.akuity.io, argoproj.io and actions.github.com groups (and the items
#           of a List that belong to them), without -ignore-missing-schemas: those must have one
#
# Exit status 1 if either pass fails (the failing pass is printed). Needs kubeconform, python3 and PyYAML.
set -euo pipefail

# The datreeio CRDs catalog snapshot the schemas are read from, pinned to a commit so a release validates the same
# way every time. Bump when a needed CRD appears in the catalog: take a new SHA of
# https://github.com/datreeio/CRDs-catalog main and change it here only (never a branch again).
CRDS_CATALOG_REF=04af58d740718c4dc719441bf39fb284c784f4a8

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
RENDER=$1
[[ -d "$RENDER" ]] || { echo "kubeconform: $RENDER is not a directory" >&2; exit 2; }
for t in kubeconform python3; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done

files=()
while IFS= read -r f; do files+=("$f"); done < <(find "$RENDER" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
[[ ${#files[@]} -gt 0 ]] || { echo "kubeconform: no YAML files under $RENDER" >&2; exit 2; }

KC=(kubeconform -strict -summary -output text -kubernetes-version 1.34.0
    -schema-location default
    -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRDS_CATALOG_REF}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")

rc=0
echo "kubeconform: pass 1: ${#files[@]} file(s), missing schemas ignored"
if ! "${KC[@]}" -ignore-missing-schemas "${files[@]}"; then
  echo "kubeconform: pass 1 FAILED (every resource, missing schemas ignored)" >&2
  rc=1
fi

# pass 2: the resources of the groups whose schemas exist must validate against them (a .yaml suffix: kubeconform
# skips files it does not recognize)
STRICT=$(mktemp --suffix=.yaml)
trap 'rm -f "$STRICT"' EXIT
python3 -I - "$STRICT" "${files[@]}" <<'PY'
import sys, yaml

class Loader(yaml.SafeLoader):
    """Accepts a bare '=' (the YAML 1.1 'value' tag), which some CRDs contain."""

Loader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: "=")

GROUPS = {"kargo.akuity.io", "argoproj.io", "actions.github.com"}


def wanted(d):
    return isinstance(d, dict) and str(d.get("apiVersion", "")).split("/")[0] in GROUPS


out, docs = sys.argv[1], []
for f in sys.argv[2:]:
    with open(f) as fh:
        try:
            for d in yaml.load_all(fh, Loader=Loader):
                if wanted(d):
                    docs.append(d)
                elif isinstance(d, dict) and str(d.get("kind", "")).endswith("List") \
                        and isinstance(d.get("items"), list):
                    # a typed List (v1 List, *List CRDs) hides its items from kubeconform: emit the ones of a
                    # checked group as documents of their own
                    docs += [i for i in d["items"] if wanted(i)]
        except yaml.YAMLError as e:
            sys.exit(f"{f}: not valid YAML: {e}")
with open(out, "w") as fh:
    yaml.safe_dump_all(docs, fh)
PY

if [[ -s "$STRICT" ]]; then
  echo "kubeconform: pass 2: the kargo.akuity.io, argoproj.io and actions.github.com resources must have a schema"
  if ! "${KC[@]}" "$STRICT"; then
    echo "kubeconform: pass 2 FAILED (kargo.akuity.io / argoproj.io / actions.github.com resources without a schema)" >&2
    rc=1
  fi
else
  echo "kubeconform: pass 2: no kargo.akuity.io, argoproj.io or actions.github.com resources, skipped"
fi

exit "$rc"
