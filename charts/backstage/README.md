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
- **Devices and DeviceApplicationSets run privileged workloads too.** The teamspace role keeps CRUD on `devices` and
  `deviceapplicationsets`. device-controller runs a virtual Device as a privileged Deployment (`virtual_device.go`,
  `privileged := true`, image `ghcr.io/teknoir/virtual-device:<spec version>`) and a DeviceApplicationSet can deploy
  any HelmChart into that nested k3s. That route is independent of `spec.image`, so the image allowlist above does not
  close it; on a single-node cluster it reaches every service account token. Parked as the follow-up "virtual device /
  DeviceApplicationSet workloads" (a policy scoped to backstage-api, or unprivileged workloads) for Anders to decide.
  Until both are closed the goal "can't bypass the admission policies" is met only in part.
- **Users: Keycloak passwords and claims.** user-controller's Keycloak plugin (`plugin_keycloak.go`) hard-sets the
  password of an existing user (not temporary) whenever a User has `spec.initial_password`, and copies `claims_v0` into
  Keycloak user attributes. Backstage writes `initial_password` on purpose (`validator-update-user.ts`), so a compromised
  backstage-api can reset the password of any user, platform superadmins included (`claims_v0.role: superadmin`), and sign
  in as them in the master realm. That login reaches ArgoCD (`role:admin` through the Keycloak groups `admin` and
  `argocd-admins`), Harbor and the hub. `ztna-backstage-identities` checks only `spec.email`. Parked as the follow-up
  "user password / claims route" for Anders to decide: a policy that denies backstage-api setting `spec.initial_password`
  or `claims_v0` on Users whose `claims_v0.role` is `superadmin`, or temporary passwords (`UPDATE_PASSWORD`).
- **Users and Profiles.** The service account may write both, and the controllers bind roles to the names in them. The
  admission policy `ztna-backstage-identities` (charts/ztna) keeps it from using that on itself: User emails and Profile
  owners must match the strict pattern `^[a-z0-9._%+-]+@[a-z0-9.-]+$` (line breaks, `:`, quotes, spaces and `#` are
  refused, because user-controller renders its RoleBinding and AuthorizationPolicy from unescaped text templates and
  a second `name:` key would win). Addresses outside the pattern (an apostrophe as in `o'brien@...`, internationalised
  domains) are refused by design, so a 403 from the Members page or a bulk invite with such an address is the policy, not
  an RBAC regression. It can still make any e-mail address a teamspace owner. Follow-up in
  user-controller: build both objects as structs, or quote with `toJson`.
  The same policy refuses a Profile create with `spec.plugins` (an empty list is fine) or `spec.resourceQuotaSpec`, and
  any change to either on an existing Profile: profile-controller writes each plugin's `values` verbatim into the
  teamspace's Helm values and the emqx subchart renders `initContainers`, `extraVolumes` and `containerSecurityContext`
  from them, which would have been a third way to a privileged pod. The Backstage code writes neither field.

## Before shipping the Backstage RBAC change (dropping teknoir-admin)

Backstage loses all teamspace rights (fleet, devices, volumes, peripherals) if a teamspace has no `teknoir-portal`
RoleBinding. profile-controller writes it, so the profile-controller image must be one that knows `config.portal`
(`PORTAL_SERVICE_ACCOUNTS`, `PORTAL_TEAMSPACE_CLUSTERROLE`) and must be live first. Check before the ClusterRoleBinding
to `teknoir-admin` goes: `kubectl --context vpro get rolebinding -A --field-selector metadata.name=teknoir-portal` lists every Profile namespace
(`kubectl --context vpro get profiles`); empty output from `comm -23 <(kubectl --context vpro get profiles.teknoir.org -o name | sed 's|.*/||' | sort) <(kubectl --context vpro get rolebinding -A --field-selector metadata.name=teknoir-portal --no-headers | awk '{print $1}' | sort)` means ready (kubectl rejects a name together with `-A`). Rolling the chart back to the previous release re-creates the broad binding.
