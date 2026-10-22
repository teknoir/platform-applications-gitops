# Harbor

This stage deploys Harbor, an open-source trusted cloud-native registry that stores, signs, and scans content.

## Overview
The Harbor integration is designed to work with the platform's existing Istio and Keycloak infrastructure.

- **Ingress**: Managed by Istio `VirtualService` pointing to the internal Harbor Nginx proxy.
- **TLS**: Terminated at the Istio `ingressgateway` using the wildcard certificate.
- **Authentication**: Native OIDC integration with Keycloak, configured by a PostSync Job. `oauth2-proxy` is NOT used for Harbor to avoid breaking Docker and Helm CLI workflows.
- **Persistence**: `hostPath` PersistentVolumes under `/opt/teknoir/harbor`, with optional `pvNodeAffinity`.

## Prerequisites
These Secrets exist before Harbor is first applied (the airgap bootstrap creates
them; none of them is in Git or in a bundle):
- `harbor-secret` (admin password, secretKey, core/jobservice/registry secrets,
  CSRF key) and `harbor-oidc-secret` (`client-secret`, the Keycloak `harbor`
  client secret of realm `teknoir`): the platform-secrets chart.
- `harbor-token-service` (`tls.key`/`tls.crt`, referenced by
  `harbor.core.secretName`) and `teknoir-root-ca-bundle` (`ca.crt`, the public
  Teknoir Root CA, referenced by `harbor.caBundleSecretName`): the airgap node.
- DNS for `harbor.<teknoir domain>` pointing to the cluster ingress IP.

The chart creates one Secret itself: `harbor-registry-auth`, the internal
registry credential (see [Registry credential](#registry-credential)).

## Deterministic render
`harbor.core.secretName` keeps the token-service key pair out of the render,
so ArgoCD no longer rolls harbor-core on every refresh, and
`harbor.registry.credentials.existingSecret` keeps the registry htpasswd (whose
bcrypt salt changed on every render) out of it. Two renders are identical, so
the `harbor` Application needs no `ignoreDifferences`.

## Registry credential
harbor-core and harbor-jobservice log in to harbor-registry with basic auth as
`harbor_registry_user`. The password and its htpasswd line live only in Secret
`harbor-registry-auth` (keys `REGISTRY_PASSWD`, `REGISTRY_HTPASSWD`), which a
Sync hook Job (`templates/registry-auth-job.yaml`, `files/registry-auth.sh`,
wave -1, before the workloads) creates once in-cluster: a random 32-character
password and its bcrypt htpasswd line (the registry accepts bcrypt only; the
Job uses helm's `htpasswd` function from the toolbox image). The Job never
prints a value and never changes an existing complete Secret; the Secret has
no ArgoCD tracking, so no sync prunes it. The airgap bootstrap's one-shot runs
the same Job as a plain Job.

Rotate: `kubectl -n teknoir-system delete secret harbor-registry-auth`, then
sync the `harbor` Application (`argocd app sync harbor`). The Job creates a new
Secret and restarts harbor-core, harbor-jobservice and harbor-registry where
they were running with the old one (pending restarts are recorded on the
Secret, so a Job that dies half-way finishes them on the next sync).

`tests/harbor-registry-auth.sh --context k3d-<name>` runs the Job on a
throwaway k3d cluster (create, re-run, rotation, incomplete Secret, pending
restart, RBAC, no value in the logs) and checks the generated htpasswd against
Harbor's registry image.

The internal database password (`database.internal.password`) cannot come
from a Secret in chart 1.18.3 and stays the chart default; see the comment at
the end of `values.yaml`.

## OIDC (Keycloak)
A PostSync Job (`templates/oidc-config-job.yaml`, `files/oidc-config.sh`)
configures Harbor's OIDC login through Harbor's API after every sync, from
`oidcConfig.settings` in `values.yaml`: endpoint
`https://auth.<teknoir domain>/auth/realms/teknoir`, client `harbor`, groups
claim `groups`, admin group `admin`, certificate verification on (Harbor trusts
the Teknoir Root CA through `harbor.caBundleSecretName`). It PUTs only the
settings that differ and sends the client secret only when its sha256 (kept in
ConfigMap `harbor-oidc-config-state`) changes; it never prints a secret. Harbor
refuses to switch `auth_mode` once users other than `admin` exist, and the Job
then leaves it alone with a warning. The local `admin` keeps working in OIDC
mode, as break-glass and for the airgap node's pushes.

The Keycloak client, the `groups` client scope and the `admin` group are
declared in realm `teknoir` by the auth chart, so no UI steps remain.

## CLI Usage (Docker/Helm)
Docker and Helm CLI clients do not support OIDC redirects directly. To use the registry from a CLI:

1. Log in to the Harbor UI via OIDC.
2. Go to your **Profile** (click your username in the top right).
3. Copy your **CLI Secret**.
4. Use this CLI secret as your password when logging in via CLI:
   ```bash
   docker login harbor.<teknoir domain>
   # Username: (your email/username)
   # Password: (paste CLI secret)
   ```
   Harbor checks the CLI secret against the user's OIDC token and refreshes it
   with the refresh token it gets through the `offline_access` scope.

Alternatively, use **Robot Accounts** for automated workflows (highly recommended for edge devices).

## Robot Accounts
Robot accounts provide long-lived credentials for automated pushes and pulls.
Create them in the Harbor UI under **Robot Accounts** or at the Project level.

## Storage Backend
The initial implementation uses `hostPath`. For production, it is recommended to override the `harbor.persistence` values to use an S3-compatible backend (e.g., MinIO, GCS, AWS S3).

## teknoir-cloud (staging)
Staging runs this chart as the `harbor` Application (`charts/app-of-apps/templates/ci.yaml`),
as the registry of the on-cluster CI (`charts/ci`). Differences from the airgap values:
`harbor.teknoir.cloud`, public Let's Encrypt certificates (no CA bundle), OIDC off (realm
master has no `harbor` client; admin + robot accounts), and `harbor-token-service` comes
from cert-manager (`tokenServiceCert`, templates/token-service-cert.yaml).

### Configuration as code (`harborConfig`)
`files/harbor-config.py` (PostSync hook + hourly CronJob `harbor-config`) reconciles:
- system settings (admin-only project creation, no self-registration);
- proxy-cache upstreams and projects `dockerhub`, `ghcr`, `quay`, `k8s`, `gcr`, `nvcr` (all
  private; see [Pull-through cache](#pull-through-cache-for-the-cluster-and-the-robots));
- project `teknoir` (CI images) and the proxies with storage quotas and tag retention. Harbor's
  data is on vpro's root filesystem (1.8 TB, 1.2 TB free on 2026-10-22) and kubelet image GC
  starts at 75 % use, so the quotas total 700 GiB: `teknoir` 250, `ghcr` 150, `dockerhub` 100,
  `nvcr` 100, `quay` 40, `gcr` 30, `k8s` 30. Retention: `ci` keeps release/environment tags,
  the 15 newest pushes per repository and anything pulled in 30 days; `proxy` keeps what was
  pulled in 30 days, digest-pinned (untagged) pulls included;
- weekly GC (blobs only; `deleteUntagged: false`, untagged artifacts go through the retention rules), audit-log purge (30 days), weekly scan-all;
- robot `robot$ci`, written as `teknoir-ci/harbor-ci-robot` (charts/ci grants the Job that
  Secret), robot `robot$nodes` (pull-only on the six proxies, never on `teknoir`), written as
  `teknoir-system/harbor-nodes-pull`, and one pull-only robot per teamspace (below). A missing
  or stale Secret (or empty one, in teknoir-system) gets a fresh robot secret; delete `harbor-ci-robot` or empty the data of the other two to rotate.
The Job only changes what differs and never prints a credential.

### Pull-through cache for the cluster and the robots
Design: `plans/harbor-proxy-staging.md`. Every image the staging nodes and robots pull can go
through `harbor.teknoir.cloud/<project>/<path>`, with the upstream as the fallback (k3s
`registries.yaml`, see infra `scripts/ci-node-setup.sh`, cli `tnctl bootstrap` and ansible
`playbooks/registry-mirror.yml`).

- **Upstream credentials.** `harborConfig.config.registries[].credential` names a Secret that is
  mounted (optional volume) at `/upstream/<registry>`. `ghcr` uses the platform's `ghcr-token`
  (dockerconfigjson) and is used only by harbor-core's outbound fetch; robots never see it.
  `dockerhub` is anonymous until Secret `harbor-upstream-dockerhub` exists (a Docker Hub
  "Public Repo Read-only" token), stored with
  `scripts/set-upstream-credential.sh dockerhub --context vpro` (reads the username and the
  token from stdin, never prints them). Harbor never returns the secret, so the registry
  description carries `credential sha256:<12 hex>` (a truncated hash of username and token) and
  the credential is sent again only when it changes; removing the Secret makes the upstream
  anonymous again. A credential that is `optional: false` and missing is an ERROR (the registry
  is not created without it).
- **Never public.** harbor-config refuses (ERROR, the step fails, the project stays private) a
  `public: true` project whose upstream has a credential or held one, so the private ghcr cache
  cannot become public through a values edit.
- **Teamspace robots.** `teamspaceRobots` lists `profiles.teknoir.org` (ClusterRole
  `harbor-config-profiles`: get/list on profiles only) and keeps one system robot
  `robot$ts-<profile>` per Profile: pull-only on the six proxies, never expiring (nothing rotates
  it yet), all credentials in ONE Secret `teknoir-system/harbor-teamspace-pull` with the keys
  `<profile>.username` and `<profile>.password` (Role `harbor-config`: get/update on that Secret
  and `harbor-nodes-pull`, no `create`; see "Secrets in teknoir-system" below). A robot with the
  description `managed by harbor-config (teamspace)` is deleted when its Profile is gone; robots
  made by hand are never touched. Delete a key (or empty the Secret's data) to rotate that
  teamspace's credential. A failing Profile list deletes nothing.
- **Secrets in teknoir-system.** harbor-config has no `create` on Secrets there. A Role that
  could create Secrets in `teknoir-system` could mint a `kubernetes.io/service-account-token`
  Secret for one of the cluster-admin ServiceAccounts that live in that namespace
  (`profile-controller`, `user-controller`) and read its token. The chart therefore renders
  `harbor-nodes-pull` and `harbor-teamspace-pull` as empty Opaque Secrets
  (`templates/harbor-config-rbac.yaml`; `Prune=false,Delete=false`, and `ignoreDifferences` on
  `.data` in the harbor Application), and harbor-config only updates them (Secret `type` is
  immutable, so get/update cannot turn them into a token Secret). Rotate by deleting the data
  keys, never the Secret; if it is deleted anyway, ArgoCD renders it again and the next job run
  fills it (until then the job logs `may not create it`). `teknoir-ci/harbor-ci-robot` is
  created by harbor-config as before (the ci chart grants that Role).
- **Path guard.** The ghcr credential can read every package its owner can read, but robots need
  only `ghcr.io/teknoir/*`. `templates/harbor-proxy-guard.yaml` is an EnvoyFilter on
  harbor-core's inbound listener (port 8080, before the router) that runs
  `files/harbor-proxy-guard.lua`: it percent-decodes (until stable), merges slashes, resolves dot
  segments and lowercases the path, then answers 403 for `/v2/ghcr/<org>/...` unless `<org>` is
  in `harborConfig.proxyGuard.ghcr.allowOrgs` (default `[teknoir]`). Public ghcr images of other
  organisations (for example `dexidp/dex`) then get 403 from Harbor and containerd falls through
  to ghcr.io. An AuthorizationPolicy `notPaths` rule could not do this: it cannot see `%2F`
  forms. Not suitable for customer teamspaces: the teamspace robot can pull every private
  `ghcr.io/teknoir/*` image (plan phase 2: one credential per device).
  The same goes for the `nodes` robot: its credential sits in every node's `registries.yaml`, so
  any pod on such a node, in any namespace and without a pull secret, can pull those images.
  On a cluster with customer teamspaces drop the `ghcr` line from `nodes`, or enable
  `KubeletEnsureSecretPulledImages` / `AlwaysPullImages`.
  Pods with their own upstream pull secret (staging: 22 pods carry `ghcr-token`) bypass the
  cache: kubelet never sets the credential's server address, so containerd sends the pod's
  credential to every mirror endpoint, including this Harbor, which rejects it; the pull then goes
  to the upstream. The credential reaches only harbor-core. Accepted on staging
  (plans/harbor-proxy-staging.md); on a new cluster do not put upstream pull secrets on pods of
  mirrored nodes (plans/new-cluster-requirements.md section 10).

### Tests
- `python3 -m unittest discover -s charts/harbor/tests -p 'test_*.py'` (stdlib only):
  - `test_harbor_config.py`: files/harbor-config.py against an in-process fake Harbor and
    Kubernetes API (idempotency, credential hash, public guard, retention, teamspace robot
    lifecycle, no secret in the logs), plus the chart's real config rendered with helm;
  - `test_proxy_guard.py`: the Lua guard in LuaJIT (needs docker and the digest-pinned
    `nickblah/luajit` image locally, else skipped) and the rendered EnvoyFilter;
  - `test_set_upstream_credential.py`: the credential script with a stub kubectl.
- `helm unittest charts/harbor` (`tests/*_test.yaml`): RBAC, credential volumes, guard.
  Both helm-based tests need the subchart: `helm dependency build charts/harbor` once.
