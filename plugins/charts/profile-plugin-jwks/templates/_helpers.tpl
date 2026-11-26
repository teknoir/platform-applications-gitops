{{/*
Common helpers for profile-plugin-jwks
*/}}

{{/*
MQTT_AUTHN_MODE of jwks-server. Only observe and enforce are valid; anything else fails the
render (jwks-server would refuse to start with it).
*/}}
{{- define "jwks.authnMode" -}}
{{- $m := toString .Values.mqttAuth.authnMode -}}
{{- if not (has $m (list "observe" "enforce")) -}}
{{- fail (printf "mqttAuth.authnMode must be observe or enforce (got %q)" $m) -}}
{{- end -}}
{{- $m -}}
{{- end -}}

{{/*
The mTLS principal of the EMQX pod in this namespace: the only caller allowed on
/api/v1/mqtt/* (authorizationpolicy.yaml).
*/}}
{{- define "jwks.emqxPrincipal" -}}
{{- printf "%s/ns/%s/sa/%s" .Values.authorization.trustDomain .Release.Namespace .Values.mqttAuth.emqxServiceAccount -}}
{{- end -}}

{{/*
LEGACY_KEYS_EXCLUDE_PREFIXES of jwks-server: mqttAuth.legacyExcludePrefixes joined with ",".
Device ids with one of these prefixes are left out of GET /api/v1/keys/legacy (the key set of
EMQX's legacy JWT authenticator); /api/v1/keys stays complete. Every item must match
^[a-z0-9][a-z0-9.-]{0,62}$ (jwks-server refuses to start on anything else), so the render fails
on an empty, capitalised or otherwise invalid prefix. Empty for an empty list (deployment.yaml
then leaves the variable out).
*/}}
{{- define "jwks.legacyExcludePrefixes" -}}
{{- $l := .Values.mqttAuth.legacyExcludePrefixes | default list -}}
{{- if not (kindIs "slice" $l) -}}
{{- fail (printf "mqttAuth.legacyExcludePrefixes must be a list (got %q)" (toString $l)) -}}
{{- end -}}
{{- $out := list -}}
{{- range $l -}}
{{- $p := toString . -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9.-]{0,62}$" $p) -}}
{{- fail (printf "mqttAuth.legacyExcludePrefixes: %q must match ^[a-z0-9][a-z0-9.-]{0,62}$" $p) -}}
{{- end -}}
{{- $out = append $out $p -}}
{{- end -}}
{{- join "," $out -}}
{{- end -}}
