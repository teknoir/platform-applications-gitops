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
#   4. CHART MODE (the profile-controller ConfigMap has no PLUGIN_GIT_REPO_URL): every profile-plugin
#      Application in PLUGIN_NAMESPACE has spec.source.chart starting with profile-plugin-, its
#      spec.source.targetRevision equal to PLUGIN_CHART_VERSION of the ConfigMap, and is Synced and Healthy. A
#      selected Application with a git source (spec.source.path) fails: the plugins have moved to git mode.
#   5. GIT MODE (a non-empty PLUGIN_GIT_REPO_URL in that ConfigMap; CI v4 P9.1 moves the plugin charts into this
#      repository under plugins/charts/profile-plugin-<x>): the ConfigMap's PLUGIN_GIT_REPO_URL is this
#      repository, and every profile-plugin Application is a single source of this repository (no chart) with
#      spec.source.path == <PLUGIN_GIT_PATH>/profile-plugin-<x> (default plugins/charts) and
#      spec.source.targetRevision, status.sync.revision, sync status and health those of this release.
#   Rules 4 and 5 select an Application whose spec.source.chart or spec.source.path (or any spec.sources[]
#   entry) is a profile-plugin chart; names in EXCLUDE_APPS are skipped. A ConfigMap is needed only when at least
#   one Application is selected; PLUGIN_MIN_APPS (default 0) fails the check when fewer are selected, so a set
#   that vanished cannot pass silently.
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
#   PLUGIN_MIN_APPS           default 0: fail when fewer profile-plugin Applications are selected than this
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
PLUGIN_MIN=${PLUGIN_MIN_APPS:-0}
KUBECTL=${KUBECTL:-kubectl}
# The separator of the one-line-per-Application records plugin_check reads back (a non-whitespace byte, so an
# empty field is kept as one).
SEP=$(printf '\037')
PLUGIN_SUMMARY=

FAILS=$(mktemp)
PLUGIN_APPS=$(mktemp)
trap 'rm -f "$FAILS" "$PLUGIN_APPS"' EXIT

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

# plugin_path <path>: true when it is <PLUGIN_GIT_PATH>/profile-plugin-<x>, x of [a-z0-9-] (git mode).
plugin_path() {
    case "$1" in
        "$PLUGIN_GIT_PATH"/profile-plugin-*) tail=${1#"$PLUGIN_GIT_PATH"/profile-plugin-} ;;
        *) return 1 ;;
    esac
    [ -n "$tail" ] || return 1
    case "$tail" in
        *[!a-z0-9-]*) return 1 ;;
    esac
    return 0
}

# plugin_check: rules 4 and 5. The Applications are listed and counted first (EXCLUDE_APPS skipped): the
# ConfigMap is required only when PLUGIN_MIN_APPS is met by at least one of them.
plugin_check() {
    PLUGIN_SUMMARY=
    apps=$(get "$PLUGIN_NS" applications.argoproj.io) || {
        fail "$PLUGIN_NS: cannot list Applications (needed for the profile plugins)"
        return
    }
    printf '%s' "$apps" | jq -r --arg sep "$SEP" '
      def plugin:
        ((.spec.source.chart // "") | startswith("profile-plugin-"))
        or ((.spec.source.path // "") | test("(^|/)profile-plugin-[a-z0-9-]+$"))
        or any((.spec.sources // [])[]?;
               ((.chart // "") | startswith("profile-plugin-"))
               or ((.path // "") | test("(^|/)profile-plugin-[a-z0-9-]+$")));
      .items[]? | select(plugin)
      | [ .metadata.name,
          ((.spec.sources // []) | length),
          (.spec.source.chart // ""),
          (.spec.source.path // ""),
          (.spec.source.repoURL // ""),
          (.spec.source.targetRevision // ""),
          (.status.sync.revision // "<none>"),
          (.status.sync.status // "-"),
          (.status.health.status // "-") ]
      | join($sep)' > "$PLUGIN_APPS"

    count=0
    while IFS="$SEP" read -r name _; do
        is_excluded "$name" || count=$((count + 1))
    done < "$PLUGIN_APPS"
    if [ "$count" -lt "$PLUGIN_MIN" ]; then
        fail "profile plugins: $count Applications found, want at least $PLUGIN_MIN"
        return
    fi
    [ "$count" -gt 0 ] || return 0

    cm=$(get "$PLUGIN_NS" configmap "$PLUGIN_CM") || {
        fail "$PLUGIN_NS/$PLUGIN_CM: not found (the plugin chart version and git mode)"
        return
    }
    git_repo=$(printf '%s' "$cm" | jq -r '.data.PLUGIN_GIT_REPO_URL // ""')
    if [ -n "$git_repo" ]; then
        # Rule 5: git mode. One ConfigMap key decides for every plugin Application.
        if [ "$(norm "$git_repo")" != "$REPO_NORM" ]; then
            fail "$PLUGIN_NS/$PLUGIN_CM: PLUGIN_GIT_REPO_URL $git_repo is not this repository (want $REPO_NORM)"
            return
        fi
        PLUGIN_GIT_PATH=$(printf '%s' "$cm" | jq -r '.data.PLUGIN_GIT_PATH // ""' | sed 's:/*$::')
        [ -n "$PLUGIN_GIT_PATH" ] || PLUGIN_GIT_PATH=plugins/charts
        while IFS="$SEP" read -r name multi chart path repo target syncrev sync health; do
            is_excluded "$name" && continue
            if [ "$multi" != "0" ]; then
                fail "$name: multi-source Application (want one source $PLUGIN_GIT_PATH/profile-plugin-<x>)"
                continue
            fi
            if [ -n "$chart" ]; then
                fail "$name: Helm chart $chart in git mode (want $PLUGIN_GIT_PATH/profile-plugin-<x>)"
                continue
            fi
            [ "$(norm "$repo")" = "$REPO_NORM" ] || fail "$name: repoURL $repo (want $REPO_NORM)"
            plugin_path "$path" || fail "$name: path $path (want $PLUGIN_GIT_PATH/profile-plugin-<x>)"
            [ "$target" = "$REVISION" ] || fail "$name: targetRevision $target (want $REVISION)"
            [ "$syncrev" = "$REVISION" ] || fail "$name: sync revision $syncrev (want $REVISION)"
            [ "$sync" = "Synced" ] || fail "$name: sync $sync (want Synced)"
            [ "$health" = "Healthy" ] || fail "$name: health $health (want Healthy)"
        done < "$PLUGIN_APPS"
        PLUGIN_SUMMARY="rule 5: $count profile-plugin Applications at $REVISION"
        return
    fi
    # Rule 4: chart mode. PLUGIN_CHART_VERSION is the version every plugin chart must be at.
    version=$(printf '%s' "$cm" | jq -r '.data.PLUGIN_CHART_VERSION // ""')
    if [ -z "$version" ]; then
        fail "$PLUGIN_NS/$PLUGIN_CM: no data.PLUGIN_CHART_VERSION"
        return
    fi
    while IFS="$SEP" read -r name multi chart path repo target syncrev sync health; do
        is_excluded "$name" && continue
        if [ "$multi" != "0" ]; then
            fail "$name: multi-source Application, no spec.source.chart ($PLUGIN_CM)"
            continue
        fi
        case "$chart" in
            "")
                fail "$name: git source (path $path) while $PLUGIN_CM sets no PLUGIN_GIT_REPO_URL (chart mode)"
                continue ;;
            profile-plugin-*) ;;
            *)
                fail "$name: plugin chart $chart is not a profile-plugin chart"
                continue ;;
        esac
        [ "$target" = "$version" ] || fail "$name: plugin chart $target (want $version, $PLUGIN_CM)"
        [ "$sync" = "Synced" ] || fail "$name: sync $sync (want Synced)"
        [ "$health" = "Healthy" ] || fail "$name: health $health (want Healthy)"
    done < "$PLUGIN_APPS"
    PLUGIN_SUMMARY="rule 4: $count profile-plugin Applications at chart $version"
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
        # The plugin summary, once, on the poll that passed (not every poll).
        [ -z "$PLUGIN_SUMMARY" ] || printf '%s\n' "$PLUGIN_SUMMARY"
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
