{{- define "release-guard.labels" -}}
app.kubernetes.io/name: release-guard
app.kubernetes.io/part-of: teknoir-release-guard
{{- end -}}

{{- define "release-guard.releaserUser" -}}
system:serviceaccount:{{ .Values.namespace }}:{{ .Values.releaser.serviceAccount }}
{{- end -}}

{{/* Fail the render of THIS chart on a bad mode; a failure here only affects the release-guard Application. */}}
{{- define "release-guard.actions" -}}
{{- if eq .Values.guard.mode "Warn" -}}["Warn", "Audit"]
{{- else if eq .Values.guard.mode "Deny" -}}["Deny", "Audit"]
{{- else -}}{{ fail (printf "guard.mode must be Warn or Deny, got %q" .Values.guard.mode) }}
{{- end -}}
{{- end -}}
