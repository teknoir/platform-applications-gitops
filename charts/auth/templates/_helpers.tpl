{{/* Namespace of the auth chart's own objects. */}}
{{- define "auth.namespace" -}}
{{- .Values.namespace | default .Release.Namespace -}}
{{- end }}

{{/* Keycloak's http-relative-path ("/auth" on this install). */}}
{{- define "auth.relativePath" -}}
{{- trimSuffix "/" (.Values.keycloakConfig.relativePath | default "/auth") -}}
{{- end }}

{{/* In-cluster base URL of Keycloak (through the mesh). */}}
{{- define "auth.keycloakInternalUrl" -}}
{{- printf "http://keycloak-http.%s.svc.cluster.local%s" (include "auth.namespace" .) (include "auth.relativePath" .) -}}
{{- end }}
