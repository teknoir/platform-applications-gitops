{{/*
Common helpers for profile-plugin-mongodb
*/}}

{{- define "mongodb.username" -}}
teknoir
{{- end -}}

{{- define "mongodb.password" -}}
{{- $name := "mongodb-credentials" -}}
{{- $ns := .Release.Namespace -}}
{{- $existing := (lookup "v1" "Secret" $ns $name) -}}
{{- if $existing }}
  {{- index $existing.data "password" | b64dec -}}
{{- else -}}
  {{- randAlphaNum 24 -}}
{{- end -}}
{{- end -}}

{{- define "mongodb.username_b64" -}}
{{ include "mongodb.username" . | b64enc }}
{{- end -}}

{{- define "mongodb.password_b64" -}}
{{ include "mongodb.password" . | b64enc }}
{{- end -}}

{{- define "mongodb.service_uri_b64" -}}
{{- $user := include "mongodb.username" . -}}
{{- $pass := include "mongodb.password" . -}}
{{ printf "mongodb://%s:%s@mongodb:27017/?authSource=admin" $user $pass | b64enc }}
{{- end -}}
