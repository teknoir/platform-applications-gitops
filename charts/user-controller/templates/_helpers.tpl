{{/*
Expand the name of the chart.
*/}}
{{- define "user-controller.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "user-controller.fullname" -}}
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
{{- define "user-controller.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "user-controller.labels" -}}
helm.sh/chart: {{ include "user-controller.chart" . }}
{{ include "user-controller.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: manager
app.kubernetes.io/created-by: user-controller
{{- end }}

{{/*
Selector labels
*/}}
{{- define "user-controller.selectorLabels" -}}
app.kubernetes.io/name: {{ include "user-controller.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
control-plane: controller-manager
teknoir.org/part-of: user-controller
{{- end }}

{{/*
Namespace of the temporary-password Secrets. A dedicated namespace: the
controller's only Secret access is there, so it must not be a namespace that
holds other Secrets.
*/}}
{{- define "user-controller.credentialsNamespace" -}}
{{- $ns := .Values.credentials.namespace | default "" | toString -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$" $ns) -}}
{{- fail (printf "credentials.namespace %q is not a DNS-1123 label" $ns) -}}
{{- end -}}
{{- if or (has $ns (list "default" "teknoir" "teknoir-system" "teknoir-auth" "istio-system" "cert-manager" .Release.Namespace)) (hasPrefix "kube-" $ns) -}}
{{- fail (printf "credentials.namespace %q must be a dedicated namespace" $ns) -}}
{{- end -}}
{{- $ns -}}
{{- end }}

{{- /*
Namespaces that are never a teamspace, as in the profile-controller chart's
profile-controller.reservedNames (keep the two lists equal; the render test
compares them). Prefix kube- is refused as well.
*/}}
{{- define "user-controller.reservedNamespaces" -}}
default teknoir teknoir-local teknoir-cloud teknoir-online teknoir-system teknoir-auth teknoir-user-credentials istio-system cert-manager
{{- end -}}
