{{/* chart label value, name-version with + replaced as Helm does */}}
{{- define "ci-runners.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{/* common labels for object metadata */}}
{{- define "ci-runners.labels" -}}
app.kubernetes.io/name: ci-runners
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "ci-runners.chart" . }}
{{- end -}}

{{/* the buildkitd pods carry app.kubernetes.io/name: buildkitd (the NetworkPolicies select on it), so their own
     labels are spelled out instead of included from ci-runners.labels */}}
{{- define "ci-runners.buildkitdLabels" -}}
app.kubernetes.io/name: buildkitd
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "ci-runners.chart" . }}
{{- end -}}
