#!/usr/bin/env bash
# Checks the MQTT ACL file of the chart (templates/acl-configmap.yaml, teknoir.emqx.aclConf):
#   1. helm template: the ConfigMap emqx-acl holds one key, that key is the basename of
#      EMQX_AUTHORIZATION__SOURCES__1__PATH in the upstream env ConfigMap (the include of the
#      parent helper inside the upstream chart's tpl works), the name carries the first 12 hex
#      digits of the content's sha256, the StatefulSet mounts emqx-acl at the path's directory,
#      the content has no {allow, all}, no ipaddr and no dashboard rule, the TeknoirBot (tb-)
#      publish deny of T12 comes before the two device rules, and the closing tb- deny
#      ({deny, {username, {re, "^tb-"}}, all, all}) is the last rule;
#   2. docker (emqx/emqx:5.8.9): the file parses (file:consult), every rule compiles with EMQX's
#      own emqx_authz_rule:compile, and a matrix of username/action/topic cases gives the expected
#      allow / deny / nomatch (nomatch falls to authorization.no_match). The rows for usernames
#      without the tb- prefix are those of 0.0.113 unchanged; the tb-neg-c rows are the fence.
#
#   tests/acl-check.sh           render + docker checks
#   tests/acl-check.sh --check   render checks only (no docker)
#
# Needs helm, python3 (PyYAML) and, without --check, docker. Prints no secrets (the chart's
# Secrets are not rendered).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "$HERE/.." && pwd)"
MODE=run
case "${1:-}" in
  --check) MODE=check ;;
  "") ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac
EMQX_IMAGE="${EMQX_IMAGE:-emqx/emqx:5.8.9}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 2; }; }
need helm; need python3
[ "$MODE" = check ] || need docker

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 0755 "$WORK"

if ! ls "$CHART"/charts/emqx-*.tgz >/dev/null 2>&1; then
  helm dependency build "$CHART" >/dev/null || { echo "helm dependency build failed" >&2; exit 2; }
fi

# 1. Render ------------------------------------------------------------------------------------
helm template emqx "$CHART" -n teknoir-demo --set domain=teknoir.cloud \
  --show-only templates/acl-configmap.yaml \
  --show-only charts/emqx/templates/configmap.yaml \
  --show-only charts/emqx/templates/StatefulSet.yaml > "$WORK/rendered.yaml"

python3 -I - "$WORK/rendered.yaml" "$WORK/acl.conf" <<'PY'
import hashlib, os, re, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
acl = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "emqx-acl")
env = next(d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"].endswith("-env"))
sts = next(d for d in docs if d["kind"] == "StatefulSet")
fails = 0
def check(ok, what):
    global fails
    print(("ok   - " if ok else "FAIL - ") + what)
    fails += 0 if ok else 1

keys = list(acl["data"])
check(len(keys) == 1, f"emqx-acl holds one file ({keys})")
key, content = keys[0], acl["data"][keys[0]]
path = env["data"].get("EMQX_AUTHORIZATION__SOURCES__1__PATH", "")
check(re.fullmatch(r"/opt/emqx-acl/acl-[0-9a-f]{12}\.conf", path) is not None,
      f"SOURCES__1__PATH is /opt/emqx-acl/acl-<12 hex>.conf ({path})")
check(os.path.basename(path) == key, "the ConfigMap key equals the basename of SOURCES__1__PATH")
digest = hashlib.sha256(content.encode()).hexdigest()[:12]
check(key == f"acl-{digest}.conf", "the file name carries the content hash")
spec = sts["spec"]["template"]["spec"]
vols = {v["name"]: v for v in spec.get("volumes", [])}
check(vols.get("emqx-acl", {}).get("configMap", {}).get("name") == "emqx-acl",
      "the StatefulSet has the emqx-acl ConfigMap volume")
mounts = [m for c in spec["containers"] for m in c.get("volumeMounts", []) if m["name"] == "emqx-acl"]
check(len(mounts) == 1 and mounts[0]["mountPath"] == os.path.dirname(path) and mounts[0].get("readOnly") is True,
      "emqx-acl is mounted read-only at the directory of SOURCES__1__PATH")
check(re.search(r"\{\s*allow\s*,\s*all\b", content) is None, "no {allow, all} rule")
check("ipaddr" not in content, "no ipaddr rule")
check("dashboard" not in content, "no dashboard rule")
check(env["data"].get("EMQX_AUTHORIZATION__SOURCES__1__TYPE") == "file", "source 1 is type file")
# Rules in file order: comment lines dropped, whitespace collapsed, split at the closing "}.".
body = " ".join(l for l in content.splitlines() if not l.lstrip().startswith("%%"))
rules = [re.sub(r"\s+", " ", r).strip() for r in re.split(r"\}\.(?=\s|$)", body) if r.strip()]
TB_RE = '{username, {re, "^tb-"}}'
DEV_RE = '{username, {re, "^[a-z0-9][a-z0-9.-]*$"}}'
t12 = [i for i, r in enumerate(rules) if r.startswith("{deny, " + TB_RE + ", publish,")]
dev = [i for i, r in enumerate(rules) if r.startswith("{allow, " + DEV_RE + ",")]
check(len(t12) == 1 and len(dev) == 2 and t12[0] < min(dev),
      f"the T12 deny comes before the device rules (tb- publish deny at {t12}, device rules at {dev})")
check(bool(rules) and rules[-1] == "{deny, " + TB_RE + ", all, all",
      f"the closing tb- deny is the last rule ({len(rules)} rules)")
open(sys.argv[2], "w").write(content)
sys.exit(1 if fails else 0)
PY
chmod 0644 "$WORK/acl.conf"

if [ "$MODE" = check ]; then echo "check: render checks passed (docker checks skipped)"; exit 0; fi

# 2. Parse, compile and match with EMQX's own code -----------------------------------------------
# Cases: {Username, Action, Retain, Topic, Expected}. Expected is allow, deny or nomatch.
cat > "$WORK/matrix.script" <<'ERL'
{ok, Rules} = file:consult("/w/acl.conf"),
io:format("ok   - file:consult parses ~p rules~n", [length(Rules)]),
Compiled = [emqx_authz_rule:compile(R) || R <- Rules],
io:format("ok   - emqx_authz_rule:compile accepts every rule~n"),
Cases = [
  %% platform user
  {<<"teknoir">>, subscribe, false, <<"/devices/#">>, allow},
  {<<"teknoir">>, subscribe, false, <<"/devices/+/events/alerts">>, allow},
  {<<"teknoir">>, subscribe, false, <<"/devices/+/events/inference">>, allow},
  {<<"teknoir">>, publish, true, <<"/devices/neg-a/config">>, allow},
  {<<"teknoir">>, publish, false, <<"/devices/neg-a/commands/framerates">>, allow},
  {<<"teknoir">>, publish, false, <<"/devices/neg-a/commands/alerts/ack">>, allow},
  {<<"teknoir">>, subscribe, false, <<"#">>, deny},
  {<<"teknoir">>, subscribe, false, <<"$SYS/#">>, deny},
  %% device: own set
  {<<"neg-a">>, subscribe, false, <<"/devices/neg-a/config">>, allow},
  {<<"neg-a">>, subscribe, false, <<"/devices/neg-a/commands/#">>, allow},
  {<<"neg-a">>, subscribe, false, <<"/devices/neg-a/commands/framerates">>, allow},
  {<<"neg-a">>, publish, false, <<"/devices/neg-a/state">>, allow},
  {<<"neg-a">>, publish, false, <<"/devices/neg-a/state/events">>, allow},
  {<<"neg-a">>, publish, false, <<"/devices/neg-a/events">>, allow},
  {<<"neg-a">>, publish, false, <<"/devices/neg-a/events/inference">>, allow},
  {<<"vm-fresh-01.x">>, publish, false, <<"/devices/vm-fresh-01.x/events">>, allow},
  %% device: everything else falls to no_match (or the wildcard deny)
  {<<"neg-a">>, publish, true, <<"/devices/neg-a/events">>, nomatch},
  {<<"neg-a">>, publish, false, <<"/devices/neg-a/config">>, nomatch},
  {<<"neg-a">>, publish, false, <<"/devices/neg-a/commands">>, nomatch},
  {<<"neg-a">>, publish, false, <<"/devices/neg-b/events">>, nomatch},
  {<<"neg-a">>, subscribe, false, <<"/devices/neg-b/config">>, nomatch},
  {<<"neg-a">>, subscribe, false, <<"/devices/neg-b/commands/#">>, nomatch},
  {<<"neg-a">>, subscribe, false, <<"/devices/+/events/#">>, nomatch},
  {<<"neg-a">>, subscribe, false, <<"/devices/#">>, nomatch},
  {<<"neg-a">>, subscribe, false, <<"/devices/neg-a/state">>, nomatch},
  {<<"neg-a">>, subscribe, false, <<"#">>, deny},
  {<<"neg-a">>, subscribe, false, <<"+/#">>, deny},
  {<<"neg-a">>, subscribe, false, <<"$SYS/#">>, deny},
  %% usernames that are not device names never match the device rules
  {<<"+">>, subscribe, false, <<"/devices/+/config">>, nomatch},
  {<<"#">>, subscribe, false, <<"/devices/#/config">>, nomatch},
  {<<"a/b">>, subscribe, false, <<"/devices/a/b/config">>, nomatch},
  {<<"NEG-A">>, subscribe, false, <<"/devices/NEG-A/config">>, nomatch},
  {<<"+">>, publish, false, <<"/devices/+/events">>, nomatch},
  %% TeknoirBot computer (tb-): its own config, commands, state and events (never retained) ...
  {<<"tb-neg-c">>, subscribe, false, <<"/devices/tb-neg-c/config">>, allow},
  {<<"tb-neg-c">>, subscribe, false, <<"/devices/tb-neg-c/commands/#">>, allow},
  {<<"tb-neg-c">>, publish, false, <<"/devices/tb-neg-c/state">>, allow},
  {<<"tb-neg-c">>, publish, false, <<"/devices/tb-neg-c/state/x">>, allow},
  {<<"tb-neg-c">>, publish, false, <<"/devices/tb-neg-c/events">>, allow},
  {<<"tb-neg-c">>, publish, false, <<"/devices/tb-neg-c/events/alerts">>, allow},
  %% ... never the two event families the platform acts on (T12) ...
  {<<"tb-neg-c">>, publish, false, <<"/devices/tb-neg-c/events/inference">>, deny},
  {<<"tb-neg-c">>, publish, false, <<"/devices/tb-neg-c/events/inference/x">>, deny},
  {<<"tb-neg-c">>, publish, false, <<"/devices/tb-neg-c/events/peripheral-manager">>, deny},
  {<<"tb-neg-c">>, publish, false, <<"/devices/tb-neg-c/events/peripheral-manager/x">>, deny},
  %% ... and nothing else, $-topics included (the closing deny, whatever no_match says)
  {<<"tb-neg-c">>, publish, true, <<"/devices/tb-neg-c/events">>, deny},
  {<<"tb-neg-c">>, publish, false, <<"/devices/tb-neg-c/config">>, deny},
  {<<"tb-neg-c">>, publish, true, <<"/devices/neg-a/config">>, deny},
  {<<"tb-neg-c">>, publish, false, <<"/devices/neg-a/commands/x">>, deny},
  {<<"tb-neg-c">>, publish, false, <<"/devices/neg-a/state">>, deny},
  {<<"tb-neg-c">>, publish, false, <<"/devices/neg-a/events">>, deny},
  {<<"tb-neg-c">>, publish, false, <<"negtest/free">>, deny},
  {<<"tb-neg-c">>, publish, false, <<"$negtest/x">>, deny},
  {<<"tb-neg-c">>, subscribe, false, <<"/devices/neg-a/config">>, deny},
  {<<"tb-neg-c">>, subscribe, false, <<"/devices/#">>, deny},
  {<<"tb-neg-c">>, subscribe, false, <<"/devices/+/events/#">>, deny},
  {<<"tb-neg-c">>, subscribe, false, <<"/devices/tb-neg-c/state">>, deny},
  {<<"tb-neg-c">>, subscribe, false, <<"negtest/free">>, deny},
  {<<"tb-neg-c">>, subscribe, false, <<"$negtest/x">>, deny},
  {<<"tb-neg-c">>, subscribe, false, <<"$SYS/#">>, deny},
  {<<"tb-neg-c">>, subscribe, false, <<"#">>, deny},
  %% the tb- prefix is anchored and case-sensitive
  {<<"tbx">>, publish, false, <<"/devices/neg-a/events">>, nomatch},
  {<<"rig-tb-x">>, subscribe, false, <<"/devices/#">>, nomatch},
  {<<"TB-X">>, publish, true, <<"/devices/neg-a/config">>, nomatch}
],
Fails = lists:foldl(fun({U, A, Ret, T, Want}, N) ->
    Client = #{username => U, clientid => U, peerhost => {127,0,0,1}},
    Action = case A of
               subscribe -> #{action_type => subscribe, qos => 1};
               publish -> #{action_type => publish, qos => 1, retain => Ret}
             end,
    Got = case emqx_authz_rule:matches(Client, Action, T, Compiled) of
            {matched, R} -> R;
            nomatch -> nomatch
          end,
    Tag = case Got =:= Want of true -> "ok  "; false -> "FAIL" end,
    io:format("~s - ~s ~p retain=~p ~s -> ~p (want ~p)~n", [Tag, U, A, Ret, T, Got, Want]),
    case Got =:= Want of true -> N; false -> N + 1 end
  end, 0, Cases),
io:format("matrix: ~p cases, ~p failed~n", [length(Cases), Fails]),
Fails.
ERL
chmod 0644 "$WORK/matrix.script"

docker run --rm --network none --entrypoint sh -v "$WORK":/w:ro "$EMQX_IMAGE" -c '
B=$(ls /opt/emqx/releases/*/start_clean.boot | head -1)
exec /opt/emqx/erts-*/bin/erl -boot "${B%.boot}" -noshell -pa /opt/emqx/lib/*/ebin -eval "
  try file:script(\"/w/matrix.script\") of
    {ok, 0} -> halt(0);
    {ok, _} -> halt(1);
    Err -> io:format(\"FAIL - ~p~n\", [Err]), halt(1)
  catch C:E:S -> io:format(\"FAIL - ~p:~p ~p~n\", [C, E, S]), halt(1)
  end."'
echo "acl-check: all checks passed"
