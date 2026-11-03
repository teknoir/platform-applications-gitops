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
{{- range .Values.emqxApi.callers -}}
{{- $p = append $p (printf "%s/ns/%s/sa/%s" $.Values.emqxApi.trustDomain .namespace .serviceAccount) -}}
{{- end -}}
{{- $p = concat $p .Values.emqxApi.extraPrincipals -}}
{{- toJson $p -}}
{{- end -}}

{{/*
The MQTT ACL of the broker (authorization source 1, type file), keyed on the username. A literal
that depends on no value: it is also rendered from the upstream chart's configmap.yaml (through
teknoir.emqx.aclFile in emqxConfig), where "." is the emqx subchart's context. Rules, first match
wins; anything unmatched falls to authorization.no_match:
  - the platform user (emqx.username) may do anything under /devices/;
  - nobody may subscribe to $SYS/# or to the bare wildcards # and +/#;
  - a device (a DNS-1123 name, so ${username} never holds +, # or /) may subscribe to its own
    config and commands/#, and publish its own state/# and events/#, never retained.
There is deliberately no {allow, all}, no ipaddr rule (a port-forward is 127.0.0.1) and no
dashboard rule.
*/}}
{{- define "teknoir.emqx.aclConf" -}}
%% Teknoir MQTT ACL (profile-plugin-emqx). First match wins; the rest falls to authorization.no_match.
{allow, {username, {{ include "emqx.username" . | quote }}}, all, ["/devices/#"]}.
{deny, all, subscribe, ["$SYS/#", {eq, "#"}, {eq, "+/#"}]}.
{allow, {username, {re, "^[a-z0-9][a-z0-9.-]*$"}}, subscribe,
    ["/devices/${username}/config", "/devices/${username}/commands/#"]}.
{allow, {username, {re, "^[a-z0-9][a-z0-9.-]*$"}}, {publish, [{retain, false}]},
    ["/devices/${username}/state/#", "/devices/${username}/events/#"]}.
{{ end -}}

{{/*
File name of the ACL, with a hash of its content. EMQX reads the file only when the source is
created (at boot), and only a change of the upstream env ConfigMap rolls the pod
(checksum/config). The name is in EMQX_AUTHORIZATION__SOURCES__1__PATH, so an ACL change
changes the env ConfigMap and restarts EMQX with the new file.
*/}}
{{- define "teknoir.emqx.aclFile" -}}
acl-{{ include "teknoir.emqx.aclConf" . | sha256sum | trunc 12 }}.conf
{{- end -}}
