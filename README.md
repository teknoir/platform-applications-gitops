# platform-applications-gitops

## Auth Important Manual Steps

**Setup in Keycloak**

Client setup in master realm:
* Create Client
  * ID: teknoir (or change oauth2-proxy to match)
* Capability config
  * Client authentication: ON (this is “confidential”)
  * Standard flow: ON
  * Service account roles: ON
* Login settings
  * Valid redirect URI: https://teknoir.online/oauth2/callback
  * Web origins: https://teknoir.online

Then update the secret:
* Take the client secret from Keycloak
* Update oauth2-proxy-secret (by running `./scripts/gen-oauth2-proxy-secrets.sh`)
* `./scripts/deploy-secrets.sh` to deploy secret to cluster

Then go to Client scopes menu:
* Add (or create) a scope: teknoir
* Type: Default

Configure a new mapper for the scope:
* Mapper type: Audience
* Included Client Audience: teknoir
* Add to access token: ON

Then add Service Account Role:
* Go to Client menu for teknoir -> Service Account Roles for the client click Assign Roles
* Assign "Client Roles": manage-users, query-users, view-users

Restart oauth2-proxy deployment to pick up new secret and scope changes:
```bash
kubectl -n teknoir-auth rollout restart deploy/oauth2-proxy
```