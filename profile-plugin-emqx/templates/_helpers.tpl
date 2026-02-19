{{/*
Common helpers for profile-plugin-emqx
*/}}

{{- define "emqx.username" -}}
teknoir
{{- end -}}

{{- define "emqx.password" -}}
{{- $name := "emqx-bootstrap-user" -}}
{{- $ns := .Release.Namespace -}}
{{- $existing := (lookup "v1" "Secret" $ns $name) -}}
{{- if $existing }}
  {{- index $existing.data "password" | b64dec -}}
{{- else -}}
  {{- randAlphaNum 24 -}}
{{- end -}}
{{- end -}}

{{- define "emqx.username_b64" -}}
{{ include "emqx.username" . | b64enc }}
{{- end -}}

{{- define "emqx.password_b64" -}}
{{ include "emqx.password" . | b64enc }}
{{- end -}}

{{- define "emqx.apiKey" -}}
{{- $name := "emqx-bootstrap-api-keys" -}}
{{- $ns := .Release.Namespace -}}
{{- $existing := (lookup "v1" "Secret" $ns $name) -}}
{{- if $existing }}
  {{- index $existing.data "apiKey" | b64dec -}}
{{- else -}}
  {{- randAlphaNum 12 -}}
{{- end -}}
{{- end -}}

{{- define "emqx.apiSecret" -}}
{{- $name := "emqx-bootstrap-api-keys" -}}
{{- $ns := .Release.Namespace -}}
{{- $existing := (lookup "v1" "Secret" $ns $name) -}}
{{- if $existing }}
  {{- index $existing.data "apiSecret" | b64dec -}}
{{- else -}}
  {{- randAlphaNum 24 -}}
{{- end -}}
{{- end -}}

{{- define "emqx.apiKey_b64" -}}
{{ include "emqx.apiKey" . | b64enc }}
{{- end -}}

{{- define "emqx.apiSecret_b64" -}}
{{ include "emqx.apiSecret" . | b64enc }}
{{- end -}}