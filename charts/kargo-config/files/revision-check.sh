#!/bin/sh
# revision-check: does the live GitOps state hold the commit that was just promoted?
#
# Runs as the Job of the AnalysisTemplate revision-check (templates/analysis-revision-check.yaml) after the
# staging Stage's argocd-update step: it polls every 15 s for up to 8 minutes and exits 0 once all of the
# following hold, otherwise it prints one line per failing Application and exits 1.
#
#   1. the root Application (ROOT_APP_NAME in ROOT_APP_NAMESPACE) is Synced and its git revision is $REVISION;
#   2. it lists at least one child Application in status.resources (a root that lists none is not checking
#      anything), and every Application it lists exists (one that is listed but missing fails);
#   3. for every child Application of the root, every source of this repository (repoURL equal after stripping
#      a trailing ".git" or "/") is synced at $REVISION: single source status.sync.revision, multi-source
#      (a non-empty spec.sources) status.sync.revisions[i] for each matching spec.sources[i]. A missing
#      revision (status.sync.revision, or revisions[i] absent or the array too short) fails as <none>: a source
#      that never synced is not at $REVISION. Sources of other repositories and of Helm charts (OCI) are not
#      revision-checked. Every child is Synced and Healthy, except one whose spec.destination.server is
#      DEVHOST_CI_SERVER (it runs on the dev-host cluster): sync status and health are never checked, and a
#      revision other than $REVISION fails only while the Application is comparable. When the dev host is
#      unreachable or the Application cannot be compared (status.sync.status Unknown, or a condition of type
#      ComparisonError), ArgoCD may leave its revisions empty or stale, so a wrong or missing revision is a
#      WARN line on stdout and NOT a failure: a dev host that is down must never stall a staging promotion;
#   4. every profile-plugin Application in PLUGIN_NAMESPACE (spec.source.chart starts with profile-plugin-)
#      has spec.source.targetRevision equal to PLUGIN_CHART_VERSION of the live profile-controller ConfigMap.
#      This needs a ConfigMap only when such an Application exists.
#
# Environment (set by the AnalysisTemplate; the defaults are staging's):
#   REVISION                  required: the 40-hex commit the staging Stage promoted
#   REVISION_CHECK_TIMEOUT    seconds to poll in total (default 480; the unit tests use 0)
#   REVISION_CHECK_INTERVAL   seconds between polls (default 15; the unit tests use 0)
#   ROOT_APP_NAME             default app-of-apps
#   ROOT_APP_NAMESPACE        default teknoir-system
#   EXCLUDE_APPS              space-separated child names to skip
#   DEVHOST_CI_SERVER         default empty: no dev-host child (its revisions then only warn while it cannot be
#                             compared)
#   GITOPS_REPO_URL           default https://github.com/teknoir/platform-applications-gitops.git
#   PLUGIN_CONFIGMAP          default profile-controller-config
#   PLUGIN_NAMESPACE          default teknoir-system
#
# POSIX sh and jq only. Never prints a secret (it reads no Secret).
set -u

REVISION=${REVISION:?REVISION is required}
TIMEOUT=${REVISION_CHECK_TIMEOUT:-480}
INTERVAL=${REVISION_CHECK_INTERVAL:-15}
ROOT_APP=${ROOT_APP_NAME:-app-of-apps}
ROOT_NS=${ROOT_APP_NAMESPACE:-teknoir-system}
EXCLUDE=${EXCLUDE_APPS:-}
DEVHOST=${DEVHOST_CI_SERVER:-}
REPO=${GITOPS_REPO_URL:-https://github.com/teknoir/platform-applications-gitops.git}
PLUGIN_NS=${PLUGIN_NAMESPACE:-teknoir-system}
PLUGIN_CM=${PLUGIN_CONFIGMAP:-profile-controller-config}
KUBECTL=${KUBECTL:-kubectl}

FAILS=$(mktemp)
trap 'rm -f "$FAILS"' EXIT

fail() {
    printf '%s\n' "$*" >> "$FAILS"
}

# norm <repoURL>: no trailing ".git", no trailing "/" (the same repository spelled both ways).
norm() {
    printf '%s' "$1" | sed -e 's/\.git$//' -e 's:/*$::'
}

REPO_NORM=$(norm "$REPO")

is_excluded() {
    for x in $EXCLUDE; do
        [ "$x" = "$1" ] && return 0
    done
    return 1
}

# get <namespace> <resource> [name]: the object as JSON on stdout (non-zero when it cannot be read).
get() {
    if [ -n "${3:-}" ]; then
        "$KUBECTL" --namespace "$1" get "$2" "$3" --output json 2>/dev/null
    else
        "$KUBECTL" --namespace "$1" get "$2" --output json 2>/dev/null
    fi
}

# expected_revisions <application JSON>: prints one line per source of this repository, the revision it is
# synced at (status.sync.revisions[i] for a multi-source Application, status.sync.revision for a single-source
# one). A missing revision prints the placeholder <none>, so it can never equal $REVISION.
expected_revisions() {
    printf '%s' "$1" | jq -r --arg repo "$REPO_NORM" '
      def n: sub("\\.git$"; "") | sub("/+$"; "");
      if ((.spec.sources // []) | length) > 0 then
        (.status.sync.revisions // []) as $revs
        | .spec.sources | to_entries[]
        | select(((.value.repoURL // "") | n) == $repo)
        | ($revs[.key] // "<none>")
      else
        select(((.spec.source.repoURL // "") | n) == $repo)
        | (.status.sync.revision // "<none>")
      end'
}

# state <application JSON>: "<sync status>|<health status>".
state() {
    printf '%s' "$1" | jq -r '"\(.status.sync.status // "-")|\(.status.health.status // "-")"'
}

# uncomparable <application JSON>: true (exit 0) when ArgoCD could not compare the Application with its cluster:
# status.sync.status Unknown, or a condition of type ComparisonError (an unreachable dev-host cluster).
uncomparable() {
    if printf '%s' "$1" | jq -e '(.status.sync.status // "") == "Unknown"' >/dev/null 2>&1; then
        return 0
    fi
    printf '%s' "$1" | jq -e 'any(.status.conditions[]?; .type == "ComparisonError")' >/dev/null 2>&1
}

# plugin_check: rule 4. The Applications are listed first: the ConfigMap is required only when there is one.
plugin_check() {
    apps=$(get "$PLUGIN_NS" applications.argoproj.io) || {
        fail "$PLUGIN_NS: cannot list Applications (needed for the profile plugins)"
        return
    }
    plugins=$(printf '%s' "$apps" | jq -r '
      .items[]?
      | select(((.spec.source.chart // "") | startswith("profile-plugin-")))
      | "\(.metadata.name)\t\(.spec.source.targetRevision // "")"')
    [ -n "$plugins" ] || return 0
    cm=$(get "$PLUGIN_NS" configmap "$PLUGIN_CM") || {
        fail "$PLUGIN_NS/$PLUGIN_CM: not found (the plugin chart version)"
        return
    }
    version=$(printf '%s' "$cm" | jq -r '.data.PLUGIN_CHART_VERSION // ""')
    if [ -z "$version" ]; then
        fail "$PLUGIN_NS/$PLUGIN_CM: no data.PLUGIN_CHART_VERSION"
        return
    fi
    printf '%s\n' "$plugins" | while IFS="$(printf '\t')" read -r name have; do
        [ "$have" = "$version" ] || fail "$name: plugin chart $have (want $version, $PLUGIN_CM)"
    done
}

# check: one poll. Appends failure lines to $FAILS and returns 1 when there is any.
check() {
    : > "$FAILS"

    root=$(get "$ROOT_NS" application.argoproj.io "$ROOT_APP") || {
        fail "$ROOT_NS/$ROOT_APP: not found"
        return 1
    }
    rstate=$(state "$root")
    if [ "${rstate%%|*}" != "Synced" ]; then
        fail "$ROOT_APP: sync ${rstate%%|*} (want Synced)"
    fi
    rrev=$(printf '%s' "$root" | jq -r '.status.sync.revision // ""')
    if [ "$rrev" != "$REVISION" ]; then
        fail "$ROOT_APP: revision $rrev (want $REVISION)"
    fi

    children=$(printf '%s' "$root" | jq -r '.status.resources[]? | select(.kind == "Application") | .name')
    if [ -z "$children" ]; then
        # A root that lists no child (no status.resources yet, or an empty one) is checking nothing: whatever
        # the journal says, the release is not on the cluster.
        fail "$ROOT_APP lists no child Applications"
    fi
    for name in $children; do
        if is_excluded "$name"; then
            continue
        fi
        child=$(get "$ROOT_NS" application.argoproj.io "$name") || {
            fail "$name: listed in $ROOT_APP but not found in $ROOT_NS"
            continue
        }
        # The destination server decides first: a dev-host child has its own rule (below), every other child the
        # ordinary one. Nothing else about a dev-host child is checked: its sync status and health are not.
        server=$(printf '%s' "$child" | jq -r '.spec.destination.server // ""')
        if [ -n "$DEVHOST" ] && [ "$server" = "$DEVHOST" ]; then
            # Revisions word-split (a SHA or <none>: no spaces) so the decision is made here, not in a subshell.
            revs=$(expected_revisions "$child")
            stale=0
            for rev in $revs; do
                [ "$rev" = "$REVISION" ] || stale=1
            done
            if [ "$stale" -eq 1 ]; then
                cstate=$(state "$child")
                if uncomparable "$child"; then
                    printf 'revision-check: WARN %s: devhost-ci unreachable or not comparable (sync %s); not blocking\n' \
                        "$name" "${cstate%%|*}"
                else
                    for rev in $revs; do
                        [ "$rev" = "$REVISION" ] || fail "$name: revision $rev (want $REVISION)"
                    done
                fi
            fi
            continue
        fi
        expected_revisions "$child" | while IFS= read -r rev; do
            [ "$rev" = "$REVISION" ] || fail "$name: revision $rev (want $REVISION)"
        done
        cstate=$(state "$child")
        if [ "${cstate%%|*}" != "Synced" ]; then
            fail "$name: sync ${cstate%%|*} (want Synced)"
        fi
        if [ "${cstate#*|}" != "Healthy" ]; then
            fail "$name: health ${cstate#*|} (want Healthy)"
        fi
    done

    plugin_check

    if [ -s "$FAILS" ]; then
        return 1
    fi
    return 0
}

deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
    if check; then
        echo "revision-check: $ROOT_APP is Synced at $REVISION and every Application checked is current"
        exit 0
    fi
    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
        break
    fi
    sleep "$INTERVAL"
done

cat "$FAILS"
exit 1
