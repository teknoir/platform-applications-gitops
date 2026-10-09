# jq helpers for the Argo CD diagnostics of test/k3d-e2e.sh. Use them as
#   jq -L hack/virtual-device-spike/test/jq 'include "argo"; app_summary'
# test/argo_jq_test.py covers them offline.

# Wall clock (UTC) with milliseconds, as the e2e log prints it.
def clock: now | (strftime("%H:%M:%S") + "." + ((. * 1000 | floor) % 1000 | tostring | ("00" + .)[-3:]));

# Of an Operation: "auto" for an automated one, else the user who started it.
def initiator: if .initiatedBy.automated then "auto" else (.initiatedBy.username // "?") end;
# Of an Operation: "all" for a full sync, else Kind/name of each resource of a partial sync.
def op_resources: [.sync.resources[]? | "\(.kind)/\(.name)"] | if length == 0 then "all" else join(",") end;

def resource_state: "\(.kind)/\(.name)=\(.status)/\(.health.status // "-")";

# Of an Application: what matters for sync operations. notSynced lists every resource
# that is not Synced as Kind/name=status/health ("-" where Argo CD assesses no health,
# for example for a KubeVirt or CDI CR, or for an object it has not seen yet).
def app_summary:
  {rv: .metadata.resourceVersion,
   operation: (.operation | if . == null then null else {by: initiator, resources: op_resources} end),
   operationState: (.status.operationState | if . == null then null else
     {phase, by: (.operation | initiator), resources: (.operation | op_resources),
      started: .startedAt, finished: .finishedAt, retries: (.retryCount // 0), message} end),
   sync: .status.sync.status, health: .status.health.status, history: (.status.history // [] | length),
   notSynced: [.status.resources[]? | select(.status != "Synced") | resource_state]};

# app_summary plus the state of every resource (for the log around the forced re-sync).
def app_detail: app_summary + {resources: [.status.resources[]? | resource_state]};

# Timeline of an Application from `kubectl get --watch --output-watch-events -o json`
# (run with jq -n): one line per change of app_summary other than the resourceVersion,
# so updates that only move refresh timestamps print nothing.
def app_timeline:
  foreach inputs as $e ({prev: null, out: null};
    ($e.object | app_summary) as $s | ($s | del(.rv)) as $key
    | if $key == .prev then .out = null
      else .prev = $key | .out = ({t: clock, event: $e.type} + $s) end;
    .out // empty);

def is_leaf: if type == "object" or type == "array" then length == 0 else true end;
def path_string: map(if type == "number" then "[\(.)]" else ".\(.)" end) | join("");
# [value] at path $p, or null when the path is absent (so an explicit null differs from absent).
def lookup($p):
  reduce $p[] as $k ([.];
    if . == null then null
    else .[0] | if (type == "object" and ($k | type) == "string" and has($k))
                   or (type == "array" and ($k | type) == "number" and $k < length) then [.[$k]] else null end
    end);
# The leaf paths whose values differ between $a and $b, as {"path": [before, after]};
# "<absent>" stands for a path that one side does not have.
def changes($a; $b):
  ([$a | paths(is_leaf)] + [$b | paths(is_leaf)] | unique)
  | map(. as $p | [($a | lookup($p)), ($b | lookup($p))] as $v
        | select($v[0] != $v[1])
        | {key: ($p | path_string), value: ($v | map(if . == null then "<absent>" else .[0] end))})
  | from_entries;

# Of a KubeVirt or CDI CR: generation, spec, finalizers, and which manager owns which
# top-level spec fields (with the time of its last write).
def cr_view:
  {gen: .metadata.generation, spec, finalizers: .metadata.finalizers,
   owners: [.metadata.managedFields[]? | select(.fieldsV1["f:spec"] != null)
            | "\(.manager)/\(.operation)@\(.time): \(.fieldsV1["f:spec"] | keys | map(ltrimstr("f:")) | join(","))"]};

# Timeline of custom resources from `kubectl get --watch --output-watch-events -o json`
# (run with jq -n): one line per change of cr_view, with the full spec the first time an
# object is seen and only the spec changes (path: [before, after]) after that. Status
# writes alone print nothing, unless they move the generation: the CDI CRD has no status
# subresource, so such a line shows an empty specChanges.
def cr_timeline:
  foreach inputs as $e ({out: null};
    ($e.object) as $o | "\($o.kind)/\($o.metadata.name)" as $k | ($o | cr_view) as $v | .[$k] as $p
    | if $p == $v then .out = null
      else .[$k] = $v
        | .out = ({t: clock, event: $e.type, obj: $k, rv: $o.metadata.resourceVersion, gen: $v.gen,
                   phase: $o.status.phase, owners: $v.owners}
                  + (if $p == null then {spec: $v.spec} else {specChanges: changes($p.spec; $v.spec)} end)
                  + (if $p != null and $p.finalizers != $v.finalizers then {finalizers: $v.finalizers} else {} end))
      end;
    .out // empty);

# For each partial automated sync (a selfHeal) in an Application timeline ($app, lines of
# app_timeline): when Argo CD requested it, the not-Synced resources of the status it acted
# on, and for each resource it names, when the CR was created and first written by
# anyone other than Argo CD ($crs, lines of cr_timeline). A selfHeal requested after a
# CR was created but before any other manager had written it cannot be drift: Argo CD
# acted on a comparison made before the object existed.
def selfheal_report($app; $crs):
  [range(0; $app | length) as $i | $app[$i]
   | select(.operation != null and .operation.by == "auto" and .operation.resources != "all"
            and ($i == 0 or $app[$i - 1].operation != .operation))
   | .t as $req
   | {requested: $req, resources: .operation.resources,
      previousOperationFinished: ([$app[:$i][] | .operationState | select(. != null) | .finished | select(. != null)] | last),
      actedOn: (if $i > 0 then $app[$i - 1].notSynced else null end),
      objects: [.operation.resources | split(",")[] as $r
        | ($crs | map(select(.obj == $r))) as $lines
        | {obj: $r, created: ($lines[0].t // null),
           firstOtherWrite: ([$lines[] | select(any(.owners[]; startswith("argocd-controller/") | not)) | .t] | first)}]}
   | .verdict = (if all(.objects[]; .created != null and .created <= $req and (.firstOtherWrite == null or .firstOtherWrite > $req))
                 then "stale comparison: requested after the CRs were created and before any operator wrote them"
                 else "an operator wrote a CR first or a CR was not seen: look for drift in the timeline" end)];

# The merge patch with which the e2e starts a sync, written the way Argo CD's own
# SetAppOperation (argocd app sync, automated sync) writes it: one write that sets
# .operation and clears .status.operationState, on the condition that the Application
# still has the resourceVersion that was read. Input: the Application as read.
#  - Clearing operationState: the controller writes .status.operationState with a JSON
#    merge patch, and SyncOperation.resources is omitempty. A full sync requested next
#    to the operationState of a partial selfHeal keeps that resource list on the server,
#    and once the controller resumes the running operation from status, it runs as that
#    partial sync.
#  - resourceVersion: a concurrent write by the controller makes the patch fail with 409
#    Conflict, instead of merging into an operation the controller set meanwhile.
def sync_patch($user; $revision):
  {metadata: {resourceVersion: .metadata.resourceVersion},
   operation: {initiatedBy: {username: $user},
     retry: (.spec.syncPolicy.retry // {}),
     sync: {revision: $revision, prune: (.spec.syncPolicy.automated.prune // false),
            syncOptions: (.spec.syncPolicy.syncOptions // [])}},
   status: {operationState: null}};
