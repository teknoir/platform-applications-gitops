{{/*
Common labels for objects this chart renders itself (not for the vendored
operator manifests, which are passed through byte-for-byte).
*/}}
{{- define "virtual-devices.labels" -}}
app.kubernetes.io/name: virtual-devices
app.kubernetes.io/part-of: teknoir-virtual-devices
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Custom resources reconciled by an operator installed in the same sync: apply them
after the operator Deployments are healthy, and let Argo CD skip the dry-run while
their CRD does not exist yet.
*/}}
{{- define "virtual-devices.operandAnnotations" -}}
argocd.argoproj.io/sync-wave: "1"
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end -}}
