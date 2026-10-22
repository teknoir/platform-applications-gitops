# Backstage Helm Chart

## RBAC of the API service account

The backend (`<name>-api`, default `backstage-api`) has no Kubernetes impersonation and no admin role. It is the policy
point itself: it asks a LocalSubjectAccessReview as the end user, applies the org scope and then writes as itself, so its
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
