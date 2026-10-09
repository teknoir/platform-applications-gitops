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

Limits of RBAC here:

- ConfigMap create cannot be limited by name, so backstage-api can create
  (not overwrite) a ConfigMap in any namespace.
- The `/api/teknoir-entity/core` PATCH route for Namespaces calls
  `patchNamespace` without a body and never reaches the API server, so no
  namespace permission is granted. Fixing that route needs `patch
  namespaces`.

**Kubernetes tab** (`rbac.kubernetesPlugin`): read-only `get`/`list` on
`objectTypes`, which the chart also renders as app-config
`kubernetes.objectTypes`, so the plugin asks for nothing that RBAC denies.
`configmaps` is left out on purpose. The plugin runs every request with this
ServiceAccount, so backstage's permission policy allows `kubernetes.proxy`,
`kubernetes.resources.read` and `kubernetes.clusters.read` to platform admins
only (catalog group `group:default/superadmin`). Images without that policy
(backstage `robot` up to 9f15dacf) allow the proxy to every signed-in user,
who then gets everything in the table above, though no longer every Secret
or pods/exec. `enabled: false` drops the plugin's ClusterRole.

**externalAccess** (`externalAccess.accessRestrictions`): a `teknoir-cli`
token is a Backstage service principal, which the permission framework
allows everything (the permission policy never sees it) unless
`accessRestrictions` narrow it. tnctl only reads catalog entities, so the
token is limited to plugin `catalog`, permission `catalog.entity.read`. The
chart refuses to render an empty list.

`charts/backstage/tests/rbac-test.sh` (not packaged) checks the render
(`--static`) and, in a throw-away k3d cluster with the real CRDs, runs a
`kubectl auth can-i` matrix and real calls as the ServiceAccount; see its
header.
