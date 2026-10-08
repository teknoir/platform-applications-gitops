{{/*
Issuer of the platform realm, e.g. https://auth.teknoir.airgapped/auth/realms/teknoir.
istiod fetches its JWKS over https and trusts the Teknoir CA through
/cacerts/extra.pem (istio chart); Backstage trusts it via NODE_EXTRA_CA_CERTS.
*/}}
{{- define "backstage.oidcIssuer" -}}
{{- printf "https://auth.%s%s/realms/%s" .Values.config.domain (trimSuffix "/" .Values.config.oidc.basePath) .Values.config.oidc.realm -}}
{{- end }}
