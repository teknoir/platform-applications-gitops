# Backstage Helm Chart

Backstage (frontend `backstage`, backend `backstage-api`) with its Postgres.

## Secrets

The chart creates no credentials. They come from the platform-secrets chart:

| Secret | Use |
|---|---|
| `backstage-postgres-secrets` | `POSTGRES_USER`/`POSTGRES_PASSWORD` for Postgres and the backend, `DATA_SOURCE_*` for the exporter. Never delete it while PVC `data-backstage-postgres-0` exists: initdb fixed the password on first start. |
| `backstage-backend-auth` | Mounted at `/app/secrets`; `backend-auth-backstage-secrets.yaml` (`secret: <random>`) is `$include`d as `backend.auth.keys`. |
| `backstage-keycloak-secrets` | user-controller's Keycloak client. Backstage does not use it (the keycloakOrg provider is off), so the envFrom is optional. |

## Auth

- oauth2-proxy forwards the user's access token of realm `teknoir`; the istio
  RequestAuthentications verify it (issuer
  `https://auth.<domain>/auth/realms/teknoir`, `config.oidc`) and pass it on as
  `verified-jwt`. istiod trusts the Teknoir CA for the JWKS through
  `/cacerts/extra.pem` (istio chart).
- `backend.auth.externalAccess` (jwks, audience `teknoir-cli`) uses the same
  realm. Node.js trusts the Teknoir CA through `NODE_EXTRA_CA_CERTS` from the
  optional Secret `teknoir-root-ca-bundle` (`backstageApi.caBundle`).
- Sign-in needs a catalog user `default/<email with @ replaced by -at->`,
  i.e. a User CR with that name (`teknoir-airgap admin-user` creates the first).
- Logout: when `config.oidc.realm` is set, the frontend gets
  `teknoir.auth.issuer` (the same issuer) and `teknoir.auth.clientId`
  (`config.oidc.clientId`, default `teknoir`) through
  `APP_CONFIG_teknoir_auth_issuer` / `APP_CONFIG_teknoir_auth_clientId`. Its
  logout goes to `/oauth2/sign_out` with `rd` set to the (URL-encoded)
  `<issuer>/protocol/openid-connect/logout?client_id=<clientId>&post_logout_redirect_uri=https://<domain>/`,
  so it ends both the oauth2-proxy session and the Keycloak SSO session
  (the realm's client must allow that redirect URI: auth chart, client
  `teknoir` `post.logout.redirect.uris`). Without `config.oidc.realm` neither
  variable is rendered and the frontend keeps its legacy logout URL. Needs a
  backstage-app image with `teknoir.auth` support (`buildLogoutUrl`, backstage
  r5, newer than robot 9f15dacf); older images ignore the variables.
  The image's own injection (`docker/inject-config.sh`, into the main chunk)
  never reaches the frontend: the config loader ignores that value whenever
  `index.html` carries a `<script type="backstage.io/config">` tag, which the
  image's always does, so "Log out" went to Keycloak realm `master` and left
  the oauth2-proxy and realm sessions alive (found in the r5 VM browser check).
  The chart therefore mounts `45-inject-index-config.sh` (ConfigMap
  `backstage-frontend-inject`) into `/docker-entrypoint.d/`; it runs after the
  image's script and adds the `teknoir.*` part of the same `APP_CONFIG_*` env
  to `index.html` as `window.__APP_CONFIG__` (the loader merges that last).
  `backstage.indexRuntimeConfig.enabled: false` removes it, for an image that
  does this itself. VM e2e E14 checks that the served page carries it.

## Catalog ingestion

The image's `app-config.yaml` refreshes the k8s entity providers every 30
minutes, and a restart does not pull a scheduled run forward (the next run is
`min(stored, now + cadence)`). `catalog.k8sProviderSchedules` (default `{}`:
no override) maps a provider to a Backstage schedule (`frequency`, `timeout`,
optionally `initialDelay`/`scope`). The chart renders each one as
`catalog.providers.k8s.<provider>: [{schedule: …}]` in
`app-config.prod-env.yaml`, which loads after the image's config and replaces
its array. Only `users`, `profiles`, `roles`, `orgtree`, `services`, `devices`
and `deviceapplicationsets` can be overridden: their entries hold nothing but a
schedule. `peripherals` (its entry also carries `wsUrl`, `mqttUrl` and
`syncOrgConfig`) and unknown names fail the render, as does a schedule without
`frequency` and `timeout`.

teknoir-local: users and profiles every minute (timeout 2 min), roles and
orgtree every 5 minutes, so a new User, owner claim or Profile (e.g. the
GitOps teamspace `teknoir-default`) reaches the catalog within about a minute.

## Probes

`backstageApi.probes` is rendered as is into the backstage-api container.
teknoir-local uses the root health endpoints of
`@backstage/backend-defaults` on port 7007:

| Probe | Path | Period | Timeout | Failures |
|---|---|---|---|---|
| startupProbe | `/.backstage/health/v1/readiness` | 10 s | 5 s | 60 (10 min for first-start migrations) |
| readinessProbe | `/.backstage/health/v1/readiness` | 10 s | 5 s | 3 |
| livenessProbe | `/.backstage/health/v1/liveness` | 20 s | 5 s | 6 |

No `initialDelaySeconds`: liveness starts only after the startup probe has
passed. Readiness answers 503 until every plugin has started.

## Images

Every image is pinned as `<repo>:<immutable tag>@sha256:<digest>` with
`IfNotPresent`, where the digest is the **linux/amd64 manifest** digest
(`crane digest --platform linux/amd64 <repo>:<tag>`), never the index digest:
the airgap bundle pushes only the amd64 manifest to Harbor. The Teknoir
images use their `sha-<8>` CI tag. `postgres` is `17.11-alpine`, the version
the live database runs; the exporter is pinned by its version tag.

`charts/backstage/tests/render-test.sh` (not packaged) renders the chart and
checks the above; see its header.

## GitHub

`backstageApi.github.enabled` (false here) gates `integrations.github`, whose
`$include` makes the GitHub App credentials file mandatory. Without it
Backstage uses the unauthenticated default github.com integration; offline the
GitHub discovery provider only logs errors.

## RBAC

`templates/rbac.yaml` gives backstage-api's ServiceAccount exactly the
Kubernetes calls its backend makes. It replaces the former cluster-wide
binding to `teknoir-admin`, which let the ServiceAccount read every Secret
(including `keycloak-platform-admin` and the `user-initial-password-*`
Secrets) and create pods/exec in every namespace. Teamspace namespaces are
created at runtime, so the teamspace rules are cluster-wide.

The table maps each rule to its callers in the backend (backstage `robot`,
`packages/backend/src/plugins/providers/*` and `plugins/teknoir-*-backend`):

| Resource | Verbs | Callers |
|---|---|---|
| `teknoir.org` users | get, list, create, patch, delete | UserEntityProvider; teknoir-entity `/custom` (create, get, merge patch, delete); teamspace backend (owner claim); email verification (get) |
| users/status | patch | email verification |
| profiles | get, list, create, patch, delete | the Profile, Role, OrgTree, Peripheral, Service, Volume and User providers (list); teknoir-entity `/custom` (get, patch); teamspace backend (create, delete) |
| profiles/status | get | teamspace backend (waits for create/delete) |
| devices | get, list, create, patch, delete | Device and DeviceApplicationSet providers; teknoir-entity `/custom` |
| deviceapplicationsets | get, list | Device and DeviceApplicationSet providers |
| devstudios, notebooks | get, list, create, patch, delete | ServiceEntityProvider; teknoir-entity `/custom` |
| claimsets | get, list, create, patch, delete | Role and User providers; teknoir-entity `/custom` |
| claims | get, list, `teknoir-system` only (Role) | ClaimSetCRDHelper |
| `networking.istio.io` virtualservices | list | ProfileEntityProvider (a plugin's APIs) |
| persistentvolumeclaims | get, list, create, delete | VolumeEntityProvider; teknoir-entity `/core` |
| secrets `mongodb-credentials`, `emqx-bootstrap-user` | get, by name | see below |
| configmaps `peripheral-config` | get, update by name; create | teknoir-entity `/peripherals` |
| the plugin's object types, `metrics.k8s.io` pods | get, list | `@backstage/plugin-kubernetes-backend` |

**Secrets backstage-api still reads** (get by name, in every teamspace
namespace; never list, never another name):

- `mongodb-credentials`: OrgTreeEntityProvider, PeripheralEntityProvider and
  the org-tree API (`/api/teknoir-entity/org-tree`) connect to the
  teamspace's MongoDB with its `username`/`password`.
- `emqx-bootstrap-user`: PeripheralEntityProvider subscribes to the
  teamspace's EMQX with it.

The rule is cluster-wide, so a Secret with one of these names in any
namespace is readable. The ServiceAccount's own token Secret
`backstage-k8s-sa-token` reaches the pod through the kubelet (env), not
through the API.

Limits of RBAC here, and what bounds them instead:

- ConfigMap create cannot be limited by name, and the teamspace rules
  (ConfigMaps, PVCs, Devices, Devstudios, Notebooks, ClaimSets) are
  cluster-wide. The admission policy below keeps those writes inside the
  teamspaces and ConfigMap writes to `peripheral-config`.
- The `/api/teknoir-entity/core` PATCH route for Namespaces calls
  `patchNamespace` without a body and never reaches the API server, so no
  namespace permission is granted. Fixing that route needs `patch
  namespaces`.

**Kubernetes tab** (`rbac.kubernetesPlugin`): read-only `get`/`list` on
`objectTypes`, which the chart also renders as app-config
`kubernetes.objectTypes`, so the plugin lists nothing that RBAC denies.
`configmaps` is left out on purpose. The tab's pod drawers call the proxy
for events, pod logs and pod delete; none of that is granted (and the API
guard closes the proxy), so those drawers show errors. The plugin runs every request with this
ServiceAccount. Two layers keep it to platform admins: the API guard below
(mesh, independent of the image) and backstage's permission policy, which
allows `kubernetes.proxy`, `kubernetes.resources.read` and
`kubernetes.clusters.read` to catalog group `group:default/superadmin` only.
Images without that policy (backstage `robot` up to 9f15dacf) allow the
plugin to every signed-in user; behind the API guard that still leaves group
`admin` only. `enabled: false` drops the plugin's ClusterRole.

**externalAccess** (`externalAccess.accessRestrictions`): a `teknoir-cli`
token is a Backstage service principal, which the permission framework
allows everything (the permission policy never sees it) unless
`accessRestrictions` narrow it. tnctl only reads catalog entities, so the
token is limited to plugin `catalog`, permission `catalog.entity.read`. The
chart refuses to render an empty list.

**Admission policy** (`rbac.admissionPolicy`,
`templates/admission-policy.yaml`): a ValidatingAdmissionPolicy (failurePolicy
Fail, Deny binding) matched on backstage-api's ServiceAccount only. Its
ConfigMap, PVC, Device, Devstudio, Notebook and ClaimSet creates, updates and
deletes must happen in a teamspace namespace (label
`app.kubernetes.io/part-of=teknoir-profile` and an `owner` annotation, as
profile-controller creates them; not `rbac.admissionPolicy.reservedNamespaces`,
the release namespace, `kube-*` or `*-vdev`, device-controller's
virtual-device runtime namespaces), and ConfigMap writes must name one of
`rbac.teamspaceConfigMaps`. So the ServiceAccount cannot create
`kube-system/coredns-custom` (an optional CoreDNS import on k3s), delete a
PVC outside a teamspace, or write Devices in platform namespaces. Users and
Profiles are cluster-scoped and stay bounded by RBAC only. The AppProject
must whitelist ValidatingAdmissionPolicy and ValidatingAdmissionPolicyBinding
(app-of-apps values; r5 has them since r5-controllers, this branch's base
does not, so the chart syncs only on r5). Break-glass:
`rbac.admissionPolicy.enabled=false`.

`charts/backstage/tests/rbac-test.sh` (not packaged) checks the render
(`--static`) and, in a throw-away k3d cluster with the real CRDs, runs a
`kubectl auth can-i` matrix, real calls as the ServiceAccount and the
admission policy (server-side dry-runs); see its header.

## API guard

`templates/istio-api-guard.yaml` (a DENY AuthorizationPolicy on
backstage-api) and the VirtualService close two paths in the mesh, whatever
the Backstage image does (`istio.apiGuard`):

- `/api/kubernetes`: the Kubernetes plugin answers with backstage-api's own
  ServiceAccount (everything in the RBAC table). It needs a verified realm
  token whose `groups` claim holds one of `istio.apiGuard.kubernetesGroups`
  (`admin`: Keycloak group admin, which `teknoir-airgap admin-user` gives
  platform admins). The gateway is admitted to it by an ALLOW rule with
  those values in `backstage-api-auth-policy`: a DENY with `notValues` does
  not apply to a token that has no `groups` claim at all (Keycloak's group
  mapper may leave it out for a user in no group). No other ALLOW admits the
  gateway to backstage-api; keep it that way. `/api/kubernetes/proxy`
  forwards any Kubernetes API call and is closed for everyone
  (`denyKubernetesProxy`); with this RBAC nothing in the UI can use it.
- `/api/auth` without a verified token: the istioVerifiedJWT sign-in provider
  trusts the `verified-jwt` header without a signature check. Envoy writes it
  for a token it verified and then replaces a client-supplied one; with
  Istio 1.29.2 it also drops a client-supplied one from a request without a
  token (`istio-guard-test.sh` prints it as `INFO C4`). The guard does not
  rely on that: `/api/auth` needs a verified token, the gateway removes the
  header, and the in-mesh refresh rule of `backstage-api-auth-policy`
  requires a request principal.

DENY applies before every ALLOW, including namespace-wide ones such as the
harbor chart's `harbor-allow-internal` (every mTLS source in teknoir-system
and teknoir-auth). Istio matches paths case-sensitively, Backstage's Express
routing does not (`/api/KUBERNETES/clusters` reaches the plugin, and
`/api/kubernetes//proxy` the proxy). So at the gateway the VirtualService
answers every other spelling of `/api/kubernetes` and `/api/auth` itself
(404; the proxy 403), and removes a client-supplied `verified-jwt` from every
request to backstage-api. In the mesh (every caller but the gateway, with or
without a token, whatever ALLOW admits it), backstage-api's port 7007 answers
only `/api/catalog/entities` and, with a verified token, `/api/auth/*`; any
other path or spelling is denied, so `/api/kubernetes` is reachable through
the gateway only. Nothing in the platform calls backstage-api in the mesh
today (tnctl and the Ansible inventory go through the gateway). The metrics
port 9464 is not guarded. Through the gateway every request carries the
token oauth2-proxy hands on (X-Auth-Request-Access-Token).

`charts/backstage/tests/istio-guard-test.sh` (not packaged) checks the render
(`--static`) and, in a throw-away k3d cluster with Istio, sends requests
through the gateway and from mesh pods to echo stand-ins, first against the
policies as they were (control), then against this chart's; see its header.

## Release gate (r5)

The RBAC and the API guard assume a Backstage image with backstage
`r5-backstage-perm` (SEC-C11): `kubernetes.*` for platform admins only,
sign-in only as a User entity from UserEntityProvider, no User or Group
entities from registered locations. On the r5 integration branch the WP-BS
image pins (`PIN(WP-BS)` in values.yaml) must come from `r5-backstage` with
`r5-backstage-perm` merged, and that comment must name SEC-C11;
`tests/rbac-test.sh --static` (S9) fails until it does.

Not covered here: the staging (`teknoir-cloud`) and production
(`teknoir-online`) branches of this repo still bind backstage-api to
`teknoir-admin` cluster-wide, and their `externalAccess` has no
`accessRestrictions`. A backstage image with `r5-backstage-perm` closes only
the signed-in-user path there; `teknoir-cli` tokens still bypass the
permission policy. They need the same RBAC, `accessRestrictions` and API
guard on their own branches (production with Anders).
