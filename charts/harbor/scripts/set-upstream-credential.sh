#!/usr/bin/env bash
# Stores the credential for a Harbor proxy-cache upstream as Secret harbor-upstream-<name> in
# teknoir-system (keys username and password). harbor-config mounts it (values.yaml
# harborConfig.config.registries[].credential), sends it to Harbor on its next run (PostSync or
# the hourly CronJob) and records only a short hash. Never prints the credential.
#
#   set-upstream-credential.sh <name> --context CTX [--namespace NS] [--dry-run]
#
#   <name>      upstream registry name, e.g. dockerhub (Secret harbor-upstream-dockerhub)
#   --context   kubectl context (required, there is no default)
#   --namespace default teknoir-system (the namespace of the harbor release)
#   --dry-run   check the input and say what would happen, change nothing
#
# stdin: line 1 = username, line 2 = token/password. Example:
#   printf '%s\n%s\n' tekn0ir "$(cat /path/to/token)" | set-upstream-credential.sh dockerhub --context vpro
# On a terminal it prompts (the token is not echoed).
# Idempotent: running it again with the same input leaves the Secret unchanged. To go back to
# anonymous: kubectl --context CTX -n teknoir-system delete secret harbor-upstream-<name>.
# ghcr uses the platform's existing ghcr-token Secret (dockerconfigjson), not this script.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit "${1:-2}"; }

NAME="" CONTEXT="" NS="teknoir-system" DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="${2:-}"; shift 2 || usage ;;
    --context=*) CONTEXT="${1#*=}"; shift ;;
    --namespace) NS="${2:-}"; shift 2 || usage ;;
    --namespace=*) NS="${1#*=}"; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) [[ -z "$NAME" ]] || { echo "one upstream name only" >&2; usage; }; NAME="$1"; shift ;;
  esac
done
[[ -n "$NAME" ]] || { echo "missing upstream name" >&2; usage; }
[[ -n "$CONTEXT" ]] || { echo "missing --context (never defaults, always pass it explicitly)" >&2; usage; }
[[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "invalid upstream name: $NAME" >&2; exit 2; }
SECRET="harbor-upstream-$NAME"

if [[ -t 0 ]]; then
  read -r -p "username for $NAME: " USERNAME
  read -r -s -p "token for $NAME (not echoed): " TOKEN; echo >&2
else
  IFS= read -r USERNAME || true
  IFS= read -r TOKEN || true
fi
USERNAME="${USERNAME%$'\r'}"; TOKEN="${TOKEN%$'\r'}"
[[ -n "$USERNAME" && -n "$TOKEN" ]] || { echo "need a username (line 1) and a token (line 2) on stdin" >&2; exit 2; }
[[ "$USERNAME" != *[[:space:]]* && "$TOKEN" != *[[:space:]]* ]] || { echo "username and token must not contain whitespace" >&2; exit 2; }

if (( DRY )); then
  echo "dry run: would create or replace Secret $NS/$SECRET (keys username, password) in context $CONTEXT"
  exit 0
fi

# The values travel only through a pipe (a generated manifest), never through argv or the output.
# Server-side apply: client-side apply would copy the manifest, values included, into the
# kubectl.kubernetes.io/last-applied-configuration annotation of the Secret.
kubectl --context "$CONTEXT" -n "$NS" create secret generic "$SECRET" \
    --from-file=username=<(printf '%s' "$USERNAME") --from-file=password=<(printf '%s' "$TOKEN") \
    --dry-run=client -o yaml \
  | kubectl --context "$CONTEXT" -n "$NS" apply --server-side --force-conflicts \
      --field-manager=set-upstream-credential -f - >/dev/null
echo "Secret $NS/$SECRET stored. harbor-config sends it to Harbor on its next run (hourly, or"
echo "kubectl --context $CONTEXT -n $NS create job --from=cronjob/harbor-config harbor-config-manual)."
