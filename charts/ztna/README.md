# ztna

GitOps for **WireGuard over STUNner**, the ZTNA alternative to the SSH reverse tunnels. Design:
`plans/wireguard-ztna-tunnel.md` (rev 3); wire contract: `github.com/teknoir/wg-tunnel` `pkg/api/api.go`.
Staging (`teknoir-cloud`, r415) only. The legacy SSH tunnel (deadend, port 2222) has been removed on staging; WireGuard replaces it.

Three new charts and four touched charts, all behind **one switch**:

| Chart / Application | What |
|---|---|
| `charts/gateway-api-crds` (`gateway-api-crds`) | Gateway API CRDs, standard channel v1.4.1 (the set STUNner 1.2.1 ships), server-side applied, never pruned |
| `charts/stunner` (`stunner`) | STUNner operator 1.2.1 (pinned images), GatewayClass `stunner-gatewayclass`, GatewayConfig, Gateway `teknoir-turn` (TURN-UDP 3478, LoadBalancer via k3s servicelb), `stunner.l7mp.io/v1` UDPRoute `wg-hub` -> `teknoir-ztna/wg-hub-pods:51820` |
| `charts/ztna` (`ztna`) | Namespace `teknoir-ztna` (mesh), wg-hub, wg-flags (flags watcher), headless Service, RBAC, admission policies, VirtualServices `wg` and `wg-device`, AuthorizationPolicy, ServiceMonitor, pull secret copy |
| `charts/device-controller` | `ZTNA` key in the controller ConfigMap, Role in `teknoir-ztna`, CRD `status.wireguard`; plus the `vdev-egress-turn` NetworkPolicy of the virtual devices |
| `charts/virtual-devices` | CoreDNS rewrites `wg-device.<domain>` and `turn.<domain>` |
| `charts/auth` | EnvoyFilter patch: `wg.<domain>:443` bypasses the oauth2-proxy ext_authz and the Lua login redirect (the hub validates the Keycloak token itself; the redirect turned its JSON 401/403 into a 302) |
| `charts/backstage` | `teknoir.ztna.enabled: true` in the app-config ConfigMap and `APP_CONFIG_teknoir_ztna_enabled=true` in the frontend env |

There are **no Argo sync waves**: a wave makes the whole root app-of-apps wait for the previous wave to be Healthy, so one
failing ZTNA Application would stall every other Application. The order (CRDs, operator, ztna, device-controller's Role) is
covered by retry (10 attempts, 30s to 5m backoff) and `SkipDryRunOnMissingResource`.

## The switch

`charts/app-of-apps/values.yaml`: `ztna.enabled` (default **false**). It renders only when the environment is in
the allowlist in `charts/app-of-apps/templates/_helpers.tpl` (`teknoir-cloud`), so a cherry-pick of the flag onto
`teknoir-online` or `teknoir-local` renders nothing. When on, app-of-apps also passes `ztna.enabled=true` to the
`device-controller`, `virtual-devices`, `auth` and `backstage` Applications (Helm parameters). Flipping it is a values change.

**Before flipping**, once the images exist (these are required; the render of that chart fails without them, so
nothing half-configured is applied):

1. `charts/ztna/values.yaml`: `hub.image.tag` (`<immutable tag>@sha256:<digest>` of `ghcr.io/teknoir/wg-hub`).
2. `charts/device-controller/values.yaml`: `ztna.agentImage` (wg-agent) and `ztna.terminalImage` (WireGuard web terminal).
3. The TURN shared secret exists: `infra/scripts/gen-stunner-auth-secret.sh --context r415` (creates
   `stunner-system/stunner-auth-secret`; not in Git; rotating it resets every tunnel).
4. UDP 3478 is free on the node (`ss -ulpn`) and, for real devices, forwarded on the router.
5. `charts/device-controller` image supports the `ZTNA` config and `status.wireguard` (WP B).

Tests: `charts/ztna/tests/run.sh` (renders everything on and off, kubeconform, structural assertions, helm unittest,
and the admission policies against a throwaway local apiserver).

## What the hub is allowed

- **ClusterRole `wg-hub`**: create `subjectaccessreviews` and `tokenreviews`. **No access to Devices**: RBAC cannot give
  metadata-only access, and a Device carries the legacy RSA private key in `spec.keys`.
- **Role in `teknoir-ztna`**: get/list/watch/create/update/patch ConfigMaps (it reads policy and flags, writes identity
  ConfigMaps only, by admission policy), get ServiceAccounts. No delete, no Secrets. With `hub.leaderElection.enabled`
  (default): create Leases plus get/update on the one Lease `wg-hub` (leader election), and patch Pods, without get (it sets
  the role label of its own pod; it cannot read other pods; admission policy `ztna-workloads` lets it change nothing else).
- **Role in `stunner-system`**: get Secret `stunner-auth-secret` (by name).
- The hub image runs non-root, read-only root file system, all capabilities dropped, RuntimeDefault seccomp,
  no service account token beyond its own. Only one replica serves (see "Hub replicas": two serving hubs would split
  the session state), and a single replica uses the **Recreate** strategy.
- **Hub replicas (hub-ha, plans/ztna-later.md).** The hub keeps every session in memory, so replicas are
  active-passive: `hub.replicas` (default 2) replicas campaign for the Lease `wg-hub` (`hub.leaderElection`, env
  `LEADER_ELECTION`, `POD_NAME`, `LEASE_DURATION`, `RENEW_DEADLINE`, `RETRY_PERIOD`, `HANDOVER_WAIT`, `HANDOVER_SETTLE`);
  the leader serves and the others are ready hot standbys that answer 503. The timings are long on purpose
  (`leaseDuration` 120s, `renewDeadline` 110s): a k3s API outage over `renewDeadline` makes the leader step down and
  drop all sessions, and vpro is a single node whose k3s restarts take a minute or two; a pod or node loss costs up to
  `leaseDuration` before the standby serves. `hub.image.leaderElection` must be `true` (set together with the image pin,
  once the image is built from wg-tunnel with leader election): without it the render fails, because an older image never
  sets the `hub-role` label and Service `wg-hub` (selecting the leader) would have no endpoints. Each pod labels itself
  `ztna.teknoir.org/hub-role: leader|standby` and sets `controller.kubernetes.io/pod-deletion-cost` (100 or 0). Service
  `wg-hub` selects the leader (`name`, `component: hub`, `hub-role: leader`), so the VirtualServices, the internal port
  and the status port need no change; Service `wg-hub-pods` (headless, UDP 51820, `publishNotReadyAddresses`, selector
  name + component `hub`, so not the pull secret pods) is STUNner's only UDPRoute backend, so a failover needs no operator
  re-render and a terminating leader stays reachable for its handover notices. With more than one replica the Deployment
  rolls (`maxSurge: 1`, `maxUnavailable: 0`; the deletion cost makes it delete the standby first, so a rollout hands over
  once), a PodDisruptionBudget `wg-hub` (`hub.pdb.maxUnavailable: 1`, `unhealthyPodEvictionPolicy: AlwaysAllow`) is
  rendered and the pods prefer different nodes. One replica: Recreate, no budget (`HANDOVER_WAIT` is `0s`). More than
  one replica without `hub.leaderElection.enabled` fails the render. Covered: pod deletion, eviction, rollouts. Not
  covered: open TCP streams end at the handover; a crash of the leader still costs the agents the dead-tunnel limit; a
  single node stays a single point of failure (`kubectl drain` of that node blocks on the last hub pod, as it does on
  the other PDBs there). The metrics of every hub pod, the standby
  included, are scraped through the headless Service `wg-hub-metrics` (label `ztna.teknoir.org/scrape: hub-pods`, no role
  selector; the ServiceMonitor selects only that label), so `wghub_leader` and `wghub_role_patch_errors_total` stay
  visible when no pod carries the leader label. PrometheusRule `wg-hub` (`metrics.prometheusRule`) alerts on
  `WgHubLeaderCount` (`(sum(wghub_leader) or vector(0)) != 1` for `leaderFor`, default 5m, above `leaseDuration` so a normal
  failover is no incident), `WgHubRolePatchErrors` and `WgHubReplicaNotScraped`.
  **Rollback:** do not repin `hub.image.tag` alone. `scripts/pin-image wg-hub=<tag>` resets `hub.image.leaderElection` to
  false (and `--leader-election` sets it true for an image with leader election), so the render stops instead of leaving
  Service `wg-hub` without endpoints; to go back to an image without leader election, switch `hub.leaderElection.enabled`
  and `hub.replicas` off first (selector without the role label, one replica), then repin.

## The flags watcher (`templates/flags.yaml`)

Deployment `wg-flags` (same image as the hub, args `["flags-watcher"]`, own ServiceAccount, no Service, no ports; an
empty-ALLOW AuthorizationPolicy denies all mesh traffic to it). It is the **only** ZTNA identity that can read Devices
(ClusterRole `wg-flags`: get/list/watch `devices`) and writes the security annotations as
`ztna-flags-<teamspace>.<device>` ConfigMaps (Role `wg-flags` in `teknoir-ztna`: get/list/watch/create/update/patch/delete
ConfigMaps). The hub reads those ConfigMaps, so revocation does not depend on device-controller and a hub compromise does
not expose device keys.

## Admission policies (`templates/admission.yaml`)

Backstage's service account can write Devices and Users in every teamspace, so RBAC alone does not protect the policy store.

- `ztna-policy-store`: ConfigMaps labelled `ztna.teknoir.org/policy` or named `ztna-policy-*` are written only by
  `system:serviceaccount:teknoir-system:device-controller-service-account`; `ztna.teknoir.org/identity` or
  `ztna-identity-*` only by `system:serviceaccount:teknoir-ztna:wg-hub`; the hub writes no other ConfigMap.
  A label or name on the old or the new object counts (relabelling does not escape).
  `ztna.teknoir.org/flags` or `ztna-flags-*` only by `system:serviceaccount:teknoir-ztna:wg-flags`, and the hub and the
  watcher write no ConfigMap of the other kinds.
- `ztna-workloads`: CREATE and UPDATE of pods, deployments, replicasets, statefulsets, daemonsets, jobs and cronjobs in
  `teknoir-ztna` and `stunner-system` only by device-controller, ArgoCD's application controller, the stunner operator
  (`admission.workloadCreators` in values) and `system:serviceaccount:kube-system:*` / `system:kube-controller-manager` (the
  replicaset and job controllers create the pods). A compromised UI can neither run its own pod as `wg-hub` nor patch the
  hub image.
  One carve-out (`hub.leaderElection.enabled`): `system:serviceaccount:teknoir-ztna:wg-hub` may UPDATE a pod of the hub
  (old labels `app.kubernetes.io/name=wg-hub` and `app.kubernetes.io/component=hub`, in `teknoir-ztna`), changing only
  the label `ztna.teknoir.org/hub-role` (`leader` or `standby`) and the annotation
  `controller.kubernetes.io/pod-deletion-cost` (`0` or `100`); `spec`, ownerReferences, finalizers and every other label
  and annotation must stay equal. The pod name is not checked: the worst a hub can do is relabel the other hub pod, and a
  hub already holds every session. It still creates no pod and changes no image.
- `ztna-hub-lease`: the Lease `wg-hub` (`hub.leaderElection.lease`) is created, updated and deleted only by the wg-hub
  service account (and by namespace teardown); the hub writes no other Lease. Backstage's `teknoir-admin` cannot take the
  leadership (impersonation stays the accepted risk below).
- `ztna-no-token-mint`: TokenRequest (`serviceaccounts/token`) for `wg-hub`, `wg-flags` and the terminal accounts `wgt-*`
  only by `system:node:*` (the kubelet's projected tokens) and kube-system identities.
- `ztna-device-annotations` (phase 2): on `devices.teknoir.org` CREATE and UPDATE, any add, change or removal of a
  `ztna.teknoir.org/*` annotation (wireguard enable, approved identity, trusted host key, compromised and health flags,
  reenroll) is denied unless the user is the Backstage backend (`system:serviceaccount:teknoir-system:backstage-api`,
  `backstage.serviceAccount` in values), device-controller, or in the group `system:masters`. Notebook pods run as
  `default-editor`, which can edit Devices and would otherwise bypass the Backstage admin gate. Other annotations and
  DELETE are unaffected, and so is the status subresource. Unlike the other policies, `system:masters` is exempt here.
- `ztna-no-exec`: no `pods/exec`, `pods/attach`, `pods/portforward` CONNECT and no `pods/ephemeralcontainers`
  update in `teknoir-ztna` and `stunner-system`, for anyone (system:masters included; the hub holds session keys in
  memory and stunnerd the TURN secret).
- **ArgoCD is not blocked.** The policy and identity ConfigMaps are written at runtime, not by Git, and the chart
  renders no ConfigMap. **Namespace teardown**: the namespace controller deletes the ConfigMaps as itself, so DELETE is
  allowed while the namespace is `Terminating`. The Namespace itself carries `Prune=false,Delete=false`, so removing the
  Application never deletes the pinned identities.
- **Backstage cannot become another identity directly, but it is not harmless.** The policies match
  `request.userInfo.username`, so they hold only while no caller can stand in for an allowed identity. Backstage's
  service account has no `impersonate`, no pods, `pods/exec`, Secret list/read (two named Secrets per teamspace only),
  `roles`/`rolebindings` or `serviceaccounts` right, no `teknoir-admin` and no `*` group: cluster-wide it manages
  Profiles and Users and reads Devices, DeviceApplicationSets and claims (`backstage-api-resources-role`); inside a
  teamspace it has the ClusterRole `backstage-api-teamspace` through a RoleBinding `teknoir-portal` that
  profile-controller writes (and only in namespaces the Profile owns); in `teknoir-ztna` it may only `get`
  Deployments (Role `backstage-api-hub-workloads`, this chart). The two username exemptions for it,
  `ztna-device-annotations` and `ztna-user-org-annotations`, are deliberate: Backstage checks the end user
  (SubjectAccessReview, org gate) before it writes; making the policy check the end user would need impersonation of
  users and groups, a stronger right than the one removed.
- `ztna-backstage-identities`: closes the route from "may write Users and Profiles" to teknoir-admin. user-controller
  writes a RoleBinding for `kind: User, name: <spec.email>` and profile-controller binds `teknoir-admin` to a
  Profile's `spec.owner` verbatim, and neither checks the name. For requests from the Backstage service account (only):
  a User's `spec.email` must contain an `@` and must not start with `system:`, and a Profile's owner must be
  `kind: User` with such an address. So it cannot make itself (`system:serviceaccount:teknoir-system:backstage-api`),
  `system:masters` or a service account group a teamspace owner. Everyone else is unaffected. Tested in
  `tests/vap-test.sh` (kube-apiserver) and `charts/backstage/tests/k3d-rbac-test.sh` (as the service account).
- **Remaining risks of a compromised Backstage (accepted, not closed):**
  - it can still change `ztna.teknoir.org/*` and org-tree annotations through the two username exemptions, create
    Profiles and make any e-mail address, its own included, an owner of a teamspace;
  - **it can run code.** It may create and patch Devstudios and Notebooks in every teamspace, and
    devstudio-controller and notebook-controller copy `spec.image` into a container that runs privileged
    (`privileged: true`, SYS_ADMIN). So it can run any image privileged on a node, which is a host escape and a way
    around these policies. Teamspace developers have the same right today (it is not new with this change). Closing it
    needs an image allowlist on `devstudios`/`notebooks` (platform images only, the Harbor mirror on airgapped
    installs) or unprivileged workloads; both change what teamspace developers may do, so they are parked as the named
    follow-up "teamspace image allowlist" for Anders to decide.
- <a name="break-glass"></a>**Break-glass**: the `ztna` Application has `selfHeal`, so a deleted binding is restored within
  seconds. Order: (1) `argocd app set ztna --sync-policy none`; (2) delete the ValidatingAdmissionPolicyBinding; (3) act;
  (4) re-apply the binding (or re-sync) and `argocd app set ztna --sync-policy automated --self-heal`. system:masters is
  not exempt from any of these policies. The behaviour is tested by `tests/vap-test.sh` against a real kube-apiserver 1.30 (r415 runs 1.34).

## Networking

- `wg.<domain>` (443, `teknoir-gateway`; bypasses the edge login, see `charts/auth`: the hub validates the Keycloak token) and
  `wg-device.<domain>:8084` (`teknoir-gateway-public`, no edge auth; the hub authenticates) both go to `wg-hub:8080`.
  Both hosts are covered by the gateways' `*.<domain>` wildcard hosts and certificate.
- AuthorizationPolicy `wg-hub` (ALLOW): TCP **8080** (the public API) from the two ingress gateway principals only; TCP
  **8081** (`http-internal`: service account delegation `onBehalfOf` and direct sessions) from workloads in `teknoir-ztna`
  only, and no VirtualService routes to it; TCP **8082** (`http-status`, live status for the Backstage console; env `STATUS_ADDR=:8082`, `BACKSTAGE_SA`) only from the
  mTLS principal `cluster.local/ns/teknoir-system/sa/backstage-api` (the hub also checks the exact TokenReview username; the
  `app=backstage-api` pods carry an `istio-proxy` sidecar in the injected namespace `teknoir-system`, verified on r415); TCP 9090 from the Prometheus service account. Istio does not see UDP: the WireGuard
  socket (51820/UDP) is reachable only through STUNner, whose UDPRoute admits an authenticated TURN client to exactly that port.
- `wg-hub` is the **headless** Service of the leader: its endpoints are pod IPs (`POD_IP:51820` is the hub endpoint and
  the TURN peer), so there is no ClusterIP NAT or conntrack on the TURN leg. `wg-hub-pods` is a second headless Service
  (UDP 51820 only, every hub pod ready or not) and the UDPRoute's backend.

## STUN source IP (acceptance probe)

The Gateway `teknoir-turn` carries `stunner.l7mp.io/external-traffic-policy: "local"`, so the LoadBalancer Service keeps the
client source address. Without it kube-proxy SNATs to the node and a STUN binding response would report the node, not the
client's server-reflexive address, which breaks candidate exchange for the direct (P2P) path. Probe after a sync, from a
host that is not on the node network (the response must show your public address, not an address of r415):

    stunner-probe: turnutils_stunclient -p 3478 turn.<domain>      # coturn-utils; or: stunclient turn.<domain> 3478
    # expect: "Mapped address" / "XOR-MAPPED-ADDRESS" == the probing host's public IP
    kubectl --context r415 -n stunner-system get svc teknoir-turn -o jsonpath='{.spec.externalTrafficPolicy}'   # Local

With `Local` only nodes that run a dataplane pod answer on the LoadBalancer address; the replica count of the dataplane
(GatewayConfig) must cover the node that servicelb advertises. On the single-node r415 that is automatic.

## Client IP and rate limits

The hub does **not** set `CLIENT_IP_HEADER`, so it applies no per-IP rate limit; only the global backstop per endpoint and the
per-subject caps limit requests. Reason (k3s servicelb / klipper): on r415 both ingress gateway Services are `LoadBalancer`
with `externalTrafficPolicy: Cluster` behind klipper-lb, which masquerades the traffic, so Envoy sees the svclb/node address
for every client and `X-Envoy-External-Address` would be the same private address for everybody. (The hub also ignores a
header value that is loopback, private, CGNAT, link-local or unspecified, so setting it there would not make things worse,
but it would not help either.) A flood on the public `wg-device.<domain>:8084` can therefore still use up the global
backstop.

To switch per-IP limiting on: make real client addresses reach Envoy (`externalTrafficPolicy: Local` on
`istio-ingressgateway` and `istio-ingressgateway-public`, an infra decision in charts/istio, plus the trusted-proxy setting
if a proxy sits in front), verify in the hub logs that distinct public addresses show up, and only then add
`CLIENT_IP_HEADER=X-Envoy-External-Address` to the hub Deployment. `charts/ztna/tests/run.sh` fails while the variable is
present, so removing that check is part of the change.

## Image pull secret

`ghcr.io/teknoir/wg-hub` needs `ghcr-token`, which exists in `teknoir-system` and the teamspaces but is not copied into a
new namespace by any controller. A Sync hook Job (`templates/pull-secret.yaml`, `pullSecretCopy`) copies it once per
sync and an hourly CronJob (`pullSecretCopy.refreshSchedule`) repeats it (get on that one Secret in `teknoir-system`,
create/patch in `teknoir-ztna`, no sidecar, nothing prints the value), so a rotated token reaches the namespace within the
hour without a Git change; set `pullSecretCopy.enabled=false` if the package is public.

## The STUNner chart dependency

`charts/stunner/Chart.lock` and `charts/stunner/charts/stunner-1.2.1.tgz` are **committed** (`.gitignore` re-includes them
for this chart only; the other wrapper charts, for example cert-manager, ignore both and let ArgoCD build their dependencies).
The lock pins the chart digest and the vendored archive means a render does not depend on l7mp.io being reachable or on the
tarball behind 1.2.1 staying the same. To bump: edit `Chart.yaml`, run `helm dependency update` in `charts/stunner` and commit
both files.

## Removing

Turning the flag off removes the Applications and nothing else: no finalizers, and the CRDs and namespaces are kept (the
CRDs delete every object of their kind; `teknoir-ztna` holds the pinned identities and the web terminals device-controller
created). To remove the feature: disable WireGuard on every device (the controller removes the policy and the terminal),
delete the Gateway/UDPRoute (the operator removes stunnerd and the LoadBalancer Service), then the namespaces. Delete
the Gateway API CRDs only when nothing else uses them.

## Not covered here

Hub and agent code, the controller plugin, web terminal, Backstage and `tnctl` are other work packages. The hub is one replica
with in-memory sessions: a restart drops every tunnel and clients re-establish them.

## Keycloak audience (hub tokens)

- Hub env `KEYCLOAK_AUDIENCE` (`hub.keycloak.audience`, `teknoir-ztna`) and `KEYCLOAK_AUDIENCE_MODE` from
  `hub.keycloak.audienceMode`: `transition` accepts a Keycloak token without the audience and counts it
  (`wghub_user_tokens_total{audience="legacy"}`, log field `token_audience`), `enforce` (also the default when unset)
  refuses it; any other value fails the render. The `azp` pin (`hub.allowedAZP`) stays.
- The hub image must contain the audience check (wg-tunnel `ztna-audience` merge commit or later). An older pin ignores
  both env vars, so `enforce` would only look enforced. `scripts/check-pins.py` (run by `scripts/staging-release`) fails
  both `transition` and `enforce` on any tag that is not in the allowlist `release-policy.yaml` `audience_hub_tags`
  (fail closed: old main builds, branch builds and unknown tags all fail). When you re-pin the hub to the
  ztna-audience merge commit or a descendant, add its tag to that list in the same change. After the release, the negative test (a downscoped main token POSTed to `wg.<domain>/v1/client/session` must give 401) is a hard
  gate before `staging-release --verified`.
- Rollback: set `audienceMode: transition` (or re-pin the previous image). Reverting the realm change alone is not
  enough: `teknoir-cli` must keep `teknoir-ztna` in `optionalClientScopes` while tnctl >= 0.1.2 is in use (the scope
  stays in the realm; keycloak-config-cli syncs the client's scope list to the file). tnctl falls back without the
  scope on `invalid_scope`, with a warning, so a revert is survivable but loses the audience.
- The audience comes from the optional client scope `teknoir-ztna` of `teknoir-cli` (charts/auth realm); tnctl >= 0.1.2
  asks for it on hub calls only. Plan: `plans/ztna-later.md`, "ztna-audience".

## Org gate (hub CanOpen)

- Hub env `ORG_GATE_MODE` from `hub.orgGate.mode` (`enforce` default, `audit`, `off`); any other value fails the render.
- ClusterRole `wg-flags` also reads `users.teknoir.org` (get/list/watch); the watcher writes `ztna-org-<teamspace>`
  ConfigMaps. `ztna-policy-store` lets only `wg-flags` write them (name prefix `ztna-org-` or label `ztna.teknoir.org/org`).
- Accepted risk: `wg-flags` can read User objects cluster-wide, including `status` (user-controller keeps an initial
  password there), comparable to its Device read. Follow-up: user-controller should stop keeping the initial password
  in status.
- `ztna-device-annotations` also guards `teknoir.org/org-tree-path` and `teknoir.org/org-tree-node-id` on Devices.
- `ztna-user-org-annotations` guards `teknoir.org/org-tree-member-*` and `org-tree-units-*` on Users; writers are
  values `userOrgAnnotations.writers` plus `system:masters`.
