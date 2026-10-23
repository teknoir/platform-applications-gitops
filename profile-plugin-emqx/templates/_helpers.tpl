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

{{/*
Principals allowed to call the EMQX management API / dashboard port (18083) of the broker pod,
as a JSON list: the dashboard proxy's ServiceAccount (the proxy and the guard share it), or the
gateway principals when the proxy is off, plus emqxApi.extraPrincipals.
*/}}
{{- define "emqx.apiPrincipals" -}}
{{- $p := list -}}
{{- if .Values.dashboard.enabled -}}
{{- $p = append $p (printf "%s/ns/%s/sa/emqx-dashboard" .Values.emqxApi.trustDomain .Release.Namespace) -}}
{{- else -}}
{{- $p = concat $p .Values.dashboard.gatewayPrincipals -}}
{{- end -}}
{{- $p = concat $p .Values.emqxApi.extraPrincipals -}}
{{- toJson $p -}}
{{- end -}}
