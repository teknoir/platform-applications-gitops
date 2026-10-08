# platform-secrets

Single source of truth for the platform's random Secrets. A small Job
(`files/ensure-secrets.sh`, POSIX sh + kubectl in `docker.io/alpine/k8s`)
reconciles the Secrets listed in `values.yaml` (`secrets:`). Values are
generated inside the cluster and never leave it: nothing prints them, they are
not in Git, not in the bundle and not in K3s manifest files.

## Semantics

| Key spec | Absent Secret | Present Secret |
|---|---|---|
| `random: {length, charset}` or `random: {bytes, encoding}` (+ optional `format: "x %s"`) | generated | never changed; added only when the Secret sets `addMissingKeys: true` |
| `random: {..., seedFrom: <ns>/<secret>/<key>}` | the seed's value if it exists and is not empty, else generated | never changed (as `random`) |
| `value: <literal>` | set | never changed; added only with `addMissingKeys` |
| `value: <literal>`, `sync: true` | set | re-synced every run |
| `copyFrom: <ns>/<secret>/<key>` | copied | re-synced every run |

- When a Secret is created or any key changes, the Deployments in
  `restartDeployments` get `kubectl.kubernetes.io/restartedAt`. The pending
  restart is written onto the Secret (annotation `teknoir.org/restart-pending`)
  in the same request as the data, and cleared after the restarts, so a run that
  fails in between retries the restart on the next run. A Deployment that does
  not exist yet is skipped (it reads the current Secret when it starts).
- An existing Secret is adopted by name and key: its values are kept. Adopted
  Secrets get the label `teknoir.org/managed-by: platform-secrets`; other labels
  are left alone. Adoption therefore changes an adopted Secret's
  `resourceVersion` once (the label), never its `.data`: verify adoption with a
  hash of `.data`, not with `resourceVersion`.
- `seedFrom` adopts a value that so far only exists in a consumer. On an
  existing install the canonical `keycloak-client-secrets[teknoir]` and
  `[argocd]` do not exist yet, but their consumers do
  (`oauth2-proxy-secret[client-secret]`, `argocd-oidc-secret[oidc.auth.clientSecret]`).
  Seeding the canonical keys from them makes the copies no-ops: the consumers'
  data stays byte-identical, oauth2-proxy is not restarted, and the realm import
  sets the same client secrets in realm `teknoir`. A fresh install has no seed
  and gets random values. A seed is used verbatim (no `format`); a seed that
  cannot be read (Forbidden, ...) fails the run instead of generating a value.
- A Secret is never created with a missing copy source (the run fails instead).
- Errors are never read as "absent": only an empty
  `kubectl get --ignore-not-found` means absent; Forbidden, timeouts and so on
  fail the run (exit 1), and nothing is created.
- Generated Secrets carry no ArgoCD tracking and no ownerReference, so no
  Application ever prunes them. Deleting one re-creates it with new values on the
  next run: never delete `backstage-postgres-secrets` while the Postgres PVC
  exists, nor `harbor-secret` / `keycloak-db-secret` with data on disk.

## How it runs

The same render runs three ways:

1. **Bootstrap one-shot** (node converge, before ArgoCD exists): the node
   applies `helm template` of this chart (no value overrides) with
   `kubectl apply --server-side --field-manager=argocd-controller` and waits for
   `job/platform-secrets-ensure` in `teknoir-system` to complete
   (`kubectl wait --for=condition=complete`). The ArgoCD hook annotations are
   inert there; it is a plain Job. The node may delete the completed Job.
2. **ArgoCD Sync hook** (`Sync`, `BeforeHookCreation`, wave -10) on every sync of
   the `platform-secrets` Application. The ServiceAccount, Roles, RoleBindings
   and ConfigMap are at wave -20.
3. **CronJob** `platform-secrets-resync`, every 10 minutes: re-syncs the copies
   (rotating a source never triggers an ArgoCD sync by itself) and re-creates a
   deleted Secret.

Names are fixed (not derived from the release) and the namespace is
`values.namespace` (`teknoir-system`), so the bootstrap render equals ArgoCD's.
The Job pods are not mesh-injected (`sidecar.istio.io/inject: "false"`): they
only talk to the API server.

The Application (app-of-apps) needs destination `teknoir-system` and the
AppProject must allow Roles/RoleBindings in `teknoir-auth` and `teknoir-system`.

## RBAC (least privilege)

Per namespace, derived from `values.secrets`:

- `get`, `patch` on the listed Secrets (by name), `get` on copy and seed sources (by name);
- `create` on Secrets (Kubernetes cannot restrict `create` by name);
- `get`, `patch` on the listed Deployments (by name), for restarts.

No `list`, `watch`, `delete` or `update` on anything.

## Secrets (teknoir-local)

| Secret | Keys | Notes |
|---|---|---|
| teknoir-auth/keycloak-client-secrets | teknoir, argocd, harbor, user-controller | canonical client secrets; the auth chart imports them into realm `teknoir`; teknoir and argocd are seeded from their existing consumers |
| teknoir-auth/keycloak-admin | username, password | master-realm admin |
| teknoir-auth/keycloak-platform-admin | username (`platform-admin`), password | initial, temporary password of the human admin of realm `teknoir` (group admin); `teknoir-airgap credentials platform-admin` |
| teknoir-auth/keycloak-db-secret | username, password | adopted |
| teknoir-auth/oauth2-proxy-secret | client-secret (copy of teknoir), cookie-secret | adopted; restarts oauth2-proxy |
| teknoir-auth/oauth2-proxy-redis-secret | password | adopted |
| teknoir-system/harbor-secret | HARBOR_ADMIN_PASSWORD, secretKey, secret, CSRF_KEY, JOBSERVICE_SECRET, REGISTRY_HTTP_SECRET, database-password, redis-password | adopted |
| teknoir-system/harbor-oidc-secret | client-secret (copy of harbor) | for the Harbor OIDC config Job |
| teknoir-system/argocd-oidc-secret | oidc.auth.clientSecret (copy of argocd) | adopted; label app.kubernetes.io/part-of=argocd |
| teknoir-system/backstage-keycloak-secrets | KEYCLOAK_REALM=teknoir, KEYCLOAK_CLIENTID=user-controller, KEYCLOAK_CLIENTSECRET (copy) | restarts user-controller |
| teknoir-system/backstage-postgres-secrets | POSTGRES_USER, POSTGRES_PASSWORD, DATA_SOURCE_USER, DATA_SOURCE_PASS (= POSTGRES_PASSWORD) | |
| teknoir-system/backstage-backend-auth | backend-auth-backstage-secrets.yaml (`secret: <random>`) | |

Not here (the node creates them, they need openssl): the CA, the wildcard TLS
placeholder, the Harbor token-service TLS and the public CA-bundle copies.

## Rotation

- A **copy source** (e.g. `keycloak-client-secrets[argocd]`): change the source
  (deleting `keycloak-client-secrets` does not rotate teknoir/argocd: the
  re-created keys are seeded from the copies again);
  within 10 minutes the copies follow and the listed Deployments restart. For the
  Keycloak client secrets, also sync `auth` so the realm import applies the new
  value to Keycloak.
- A **random** value: delete the key (or the Secret) and run the Job
  (`kubectl -n teknoir-system create job --from=cronjob/platform-secrets-resync rotate-<x>`),
  then restart its consumers. Mind the data-bound ones above.

## Tests

`tests/k3d-test.sh` (not packaged) runs the bootstrap path and re-runs on a
throw-away k3d cluster: creation, adoption, formats, idempotency (no
resourceVersion changes), single re-creation, copy re-sync with restart, restart
retry, Forbidden-is-not-absent, RBAC denials, concurrent runs and a scan of every
Job log for every Secret value, live adoption by seeds (consumer data
unchanged, no restart) and unreadable seeds (an error, nothing created).
