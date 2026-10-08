{{/*
Keycloak URLs. Keycloak serves under its http-relative-path (keycloakx
http.relativePath, "/auth" here), so realm `teknoir` has the issuer
https://auth.<domain>/auth/realms/teknoir.
*/}}
{{- define "auth.domain" -}}
{{- .Values.domain | default "teknoir.airgapped" -}}
{{- end }}

{{- define "auth.namespace" -}}
{{- .Values.namespace | default .Release.Namespace -}}
{{- end }}

{{- define "auth.relativePath" -}}
{{- $p := "/auth" -}}
{{- if and .Values.keycloak .Values.keycloak.http (hasKey .Values.keycloak.http "relativePath") -}}
{{- $p = .Values.keycloak.http.relativePath -}}
{{- end -}}
{{- trimSuffix "/" $p -}}
{{- end }}

{{/* Public base URL of Keycloak, e.g. https://auth.teknoir.airgapped/auth */}}
{{- define "auth.keycloakPublicUrl" -}}
{{- printf "https://auth.%s%s" (include "auth.domain" .) (include "auth.relativePath" .) -}}
{{- end }}

{{/* In-cluster base URL of Keycloak (through the mesh). */}}
{{- define "auth.keycloakInternalUrl" -}}
{{- printf "http://keycloak-http.%s.svc.cluster.local%s" (include "auth.namespace" .) (include "auth.relativePath" .) -}}
{{- end }}

{{/* Issuer of the platform realm, e.g. https://auth.teknoir.airgapped/auth/realms/teknoir */}}
{{- define "auth.issuer" -}}
{{- printf "%s/realms/%s" (include "auth.keycloakPublicUrl" .) .Values.realm.name -}}
{{- end }}
