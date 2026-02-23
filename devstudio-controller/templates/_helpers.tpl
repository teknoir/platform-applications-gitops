{{/*
Expand the name of the chart.
*/}}
{{- define "devstudio-controller.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "devstudio-controller.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "devstudio-controller.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "devstudio-controller.labels" -}}
helm.sh/chart: {{ include "devstudio-controller.chart" . }}
{{ include "devstudio-controller.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app: {{ include "devstudio-controller.name" . }}
kustomize.component: {{ include "devstudio-controller.name" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "devstudio-controller.selectorLabels" -}}
app.kubernetes.io/name: {{ include "devstudio-controller.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: {{ include "devstudio-controller.name" . }}
kustomize.component: {{ include "devstudio-controller.name" . }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "devstudio-controller.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (printf "%s-%s" (include "devstudio-controller.fullname" .) "service-account") .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
