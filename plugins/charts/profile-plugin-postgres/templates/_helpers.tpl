{{/*
Common helpers for profile-plugin-postgres
*/}}

{{- define "postgres.password" -}}
{{- $name := "postgres-credentials" -}}
{{- $ns := .Release.Namespace -}}
{{- $existing := (lookup "v1" "Secret" $ns $name) -}}
{{- if $existing }}
  {{- index $existing.data "password" | b64dec -}}
{{- else -}}
  {{- randAlphaNum 24 -}}
{{- end -}}
{{- end -}}
