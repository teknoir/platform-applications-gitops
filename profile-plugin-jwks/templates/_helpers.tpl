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
