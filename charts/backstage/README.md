# Backstage Helm Chart

## RBAC of the API service account

The backend (`<name>-api`, default `backstage-api`) has no Kubernetes impersonation and no admin role (that does NOT
make it unable to run code, see "Remaining risks" below). It is the policy point itself: it asks a LocalSubjectAccessReview as the end user, applies the org scope and then writes as itself, so its
own rights are kept to what the code calls (plans/ztna-later.md, "backstage-sa").

| Object | Where | Rights |
|---|---|---|
| ClusterRole `<name>-api-resources-role` + ClusterRoleBinding | cluster-wide | `profiles`, `users`: CRUD; their `/status`: get; `devices`, `deviceapplicationsets`, `claims`, `claimsets`: get, list, watch; `resourcequotas`: get, list |
| ClusterRole `<name>-api-teamspace`, **no binding in this chart** | each teamspace | `devices`, `robots`, `robottypes`, `deviceapplicationsets`, `devstudios`, `notebooks`, `claimsets`: CRUD (+ `/status` get); VirtualServices: read; PVCs: get, list, watch, create, delete; ConfigMaps: create, get/update `peripheral-config`; Secrets: get `mongodb-credentials`, `emqx-bootstrap-user`; Events: read, create, patch; LocalSubjectAccessReviews: create |
| Role `backstage-api-hub-workloads` (charts/ztna) | `teknoir-ztna` | `deployments`: get |

profile-controller binds the teamspace ClusterRole with a RoleBinding `teknoir-portal` in every teamspace it owns
(`config.portal` in charts/profile-controller: `serviceAccounts`, `clusterRole`). With `config.portal` empty nothing is
bound and the service account has no rights in teamspaces. A new Backstage call to a new resource needs a rule here
first; `tests/rbac_test.yaml` fails on wildcards, impersonation, pods, Secrets without names, roles and service accounts,
and `tests/k3d-rbac-test.sh` checks the whole matrix on a throwaway cluster.

## Remaining risks (accepted)

- **Devstudios and Notebooks run any image privileged.** The teamspace role lets the service account create and patch
  `devstudios` and `notebooks`, and devstudio-controller and notebook-controller copy `spec.image` into a container with
  `privileged: true` and SYS_ADMIN. A compromised Backstage can therefore run its own image privileged in any teamspace,
  which reaches the node and, from there, the other controllers' credentials. Teamspace developers have the same right;
  it predates this change. It is parked as the named follow-up "teamspace image allowlist" (a ValidatingAdmissionPolicy
  limiting `spec.image` to the platform images, the Harbor mirror on airgapped installs) for Anders to decide, because it
  also limits what developers may run. The RBAC tests here cover only the direct routes (impersonate, pods, exec, RBAC).
- **Users and Profiles.** The service account may write both, and the controllers bind roles to the names in them. The
  admission policy `ztna-backstage-identities` (charts/ztna) keeps it from using that on itself: User emails and Profile
  owners must be e-mail addresses. It can still make any e-mail address a teamspace owner.

## Before shipping the Backstage RBAC change (dropping teknoir-admin)

Backstage loses all teamspace rights (fleet, devices, volumes, peripherals) if a teamspace has no `teknoir-portal`
RoleBinding. profile-controller writes it, so the profile-controller image must be one that knows `config.portal`
(`PORTAL_SERVICE_ACCOUNTS`, `PORTAL_TEAMSPACE_CLUSTERROLE`) and must be live first. Check before the ClusterRoleBinding
to `teknoir-admin` goes: `kubectl --context vpro get rolebinding teknoir-portal -A` lists every Profile namespace
(`kubectl --context vpro get profiles`). Rolling the chart back to the previous release re-creates the broad binding.
