# Harbor

This stage deploys Harbor, an open-source trusted cloud-native registry that stores, signs, and scans content.

## Overview
The Harbor integration is designed to work with the platform's existing Istio and Keycloak infrastructure.

- **Ingress**: Managed by Istio `VirtualService` pointing to the internal Harbor Nginx proxy.
- **TLS**: Terminated at the Istio `ingressgateway` using the wildcard certificate.
- **Authentication**: Native OIDC integration with Keycloak, configured by a PostSync Job. `oauth2-proxy` is NOT used for Harbor to avoid breaking Docker and Helm CLI workflows.
- **Persistence**: `hostPath` PersistentVolumes under `/opt/teknoir/harbor`, with optional `pvNodeAffinity`.
- **Mesh policy, namespace-wide**: neither `harbor-strict-mtls` (STRICT
  PeerAuthentication) nor `harbor-allow-internal` (ALLOW from teknoir-system
  and teknoir-auth) has a selector. Both apply to every workload in
  teknoir-system, including Argo CD, Backstage, the controllers and the
  monitoring stack, not only to Harbor. Some in-namespace paths work only
  through `harbor-allow-internal` today, for example Grafana's Alertmanager
  datasource. `charts/monitoring/tests/namespace-authz-test.sh` lists them,
  and test H3 makes sure the policy never admits the ingress gateway. The
  next release, with VM tests, gives it a selector and adds explicit ALLOWs
  for every workload. Once it has a selector, a workload with no ALLOW of its
  own admits any mesh source.

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
the Teknoir Root CA through `harbor.caBundleSecretName`), and project creation
for Harbor admins only (`project_creation_restriction: adminonly`: the local
`admin` and group `admin`; Harbor's default lets every user who signs in
create projects). It PUTs only the
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
