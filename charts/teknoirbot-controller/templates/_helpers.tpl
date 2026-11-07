{{- define "teknoirbot-controller.selectorLabels" -}}
app.kubernetes.io/name: teknoirbot-controller
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "teknoirbot-controller.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "teknoirbot-controller.selectorLabels" . }}
app.kubernetes.io/part-of: teknoirbot-controller
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
