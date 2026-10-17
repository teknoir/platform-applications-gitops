{{/* Hub image reference; the tag is mandatory. */}}
{{- define "ztna.hubImage" -}}
{{- $tag := required "hub.image.tag is required: set '<immutable tag>@sha256:<digest>' of ghcr.io/teknoir/wg-hub before enabling ztna" .Values.hub.image.tag -}}
{{- printf "%s:%s" .Values.hub.image.repository $tag -}}
{{- end -}}

{{/* Labels of the hub objects. */}}
{{- define "ztna.hubLabels" -}}
app.kubernetes.io/name: wg-hub
app.kubernetes.io/part-of: teknoir-ztna
{{- end -}}

{{/* Labels and selector of the flags watcher. */}}
{{- define "ztna.flagsLabels" -}}
app.kubernetes.io/name: wg-flags
app.kubernetes.io/part-of: teknoir-ztna
{{- end -}}
{{- define "ztna.flagsSelector" -}}
app.kubernetes.io/name: wg-flags
{{- end -}}

{{/* Selector of the hub pods (fixed: the Service, AuthorizationPolicy and NetworkPolicies use it). */}}
{{- define "ztna.hubSelector" -}}
app.kubernetes.io/name: wg-hub
{{- end -}}

{{/* system:serviceaccount:<ns>:<name> usernames used in the admission policy. */}}
{{- define "ztna.hubUser" -}}
system:serviceaccount:{{ .Release.Namespace }}:wg-hub
{{- end -}}
{{- define "ztna.controllerUser" -}}
system:serviceaccount:{{ .Values.deviceController.namespace }}:{{ .Values.deviceController.serviceAccount }}
{{- end -}}
{{- define "ztna.flagsUser" -}}
system:serviceaccount:{{ .Release.Namespace }}:wg-flags
{{- end -}}

{{/* hub.orgGate.mode: enforce (default) | audit | off; anything else fails the render. */}}
{{- define "ztna.orgGateMode" -}}
{{- $m := default "enforce" (.Values.hub.orgGate).mode -}}
{{- if not (has $m (list "enforce" "audit" "off")) -}}
{{- fail (printf "hub.orgGate.mode must be enforce, audit or off, got %q" $m) -}}
{{- end -}}
{{- $m -}}
{{- end -}}
