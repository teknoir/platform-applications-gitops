{{/* Namespace of everything in this chart. */}}
{{- define "ci.namespace" -}}{{ .Values.namespace | default .Release.Namespace }}{{- end -}}

{{/* buildctl address of one builder. */}}
{{- define "ci.builderAddr" -}}
tcp://buildkitd-{{ .name }}.{{ .ns }}.svc.cluster.local:1234
{{- end -}}

{{/* {"vpro": "tcp://...", ...} for plan.py. */}}
{{- define "ci.buildersJson" -}}
{{- $ns := include "ci.namespace" . -}}
{{- $m := dict -}}
{{- range $name, $_ := .Values.builders -}}
{{- $_ := set $m $name (include "ci.builderAddr" (dict "name" $name "ns" $ns)) -}}
{{- end -}}
{{- $m | toJson -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "ci.labels" -}}
app.kubernetes.io/part-of: teknoir-ci
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
