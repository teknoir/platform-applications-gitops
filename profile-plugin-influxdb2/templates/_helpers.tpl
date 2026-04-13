{{/*
Common helpers for profile-plugin-influxdb2
*/}}

{{- define "influxdb2.adminToken" -}}
{{- $name := "influxdb2-auth" -}}
{{- $ns := .Release.Namespace -}}
{{- $existing := (lookup "v1" "Secret" $ns $name) -}}
{{- if $existing }}
  {{- index $existing.data "admin-token" | b64dec -}}
{{- else -}}
  {{- randAlphaNum 32 -}}
{{- end -}}
{{- end -}}

{{- define "influxdb2.adminPassword" -}}
{{- $name := "influxdb2-auth" -}}
{{- $ns := .Release.Namespace -}}
{{- $existing := (lookup "v1" "Secret" $ns $name) -}}
{{- if $existing }}
  {{- index $existing.data "admin-password" | b64dec -}}
{{- else -}}
  {{- randAlphaNum 24 -}}
{{- end -}}
{{- end -}}
