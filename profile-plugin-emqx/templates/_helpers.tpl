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

{{/*
Files of the dashboard proxy ConfigMap. Shared by the ConfigMap and by the
checksum/config annotation of the Deployment.
*/}}
{{- define "emqx.dashboard.configdata" -}}
default.conf.template: |
{{ .Files.Get "files/dashboard/default.conf.template" | indent 2 }}
teknoir-sso.js: |
{{ .Files.Get "files/dashboard/teknoir-sso.js" | indent 2 }}
05-teknoir-auth.envsh: |
{{ .Files.Get "files/dashboard/05-teknoir-auth.envsh" | indent 2 }}
default-login-guard.sh: |
{{ .Files.Get "files/dashboard/default-login-guard.sh" | indent 2 }}
{{- end -}}
