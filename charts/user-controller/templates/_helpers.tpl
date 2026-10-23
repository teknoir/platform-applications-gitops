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
teknoir.org/part-of: user-controller
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
The non-secret read set of teknoir-view: no secrets, no exec, no impersonate, no writes. Shared by
teknoir-kubernetes-view (aggregated into teknoir-view) and teknoir-workload, so the two cannot drift.
*/}}
{{- define "user-controller.viewRules" -}}
- apiGroups:
    - ""
  resources:
    - configmaps
    - endpoints
    - persistentvolumeclaims
    - persistentvolumeclaims/status
    - pods
    - replicationcontrollers
    - replicationcontrollers/scale
    - serviceaccounts
    - services
    - services/status
  verbs:
    - get
    - list
    - watch
- apiGroups:
    - ""
  resources:
    - bindings
    - events
    - limitranges
    - namespaces/status
    - pods/log
    - pods/status
    - replicationcontrollers/status
    - resourcequotas
    - resourcequotas/status
  verbs:
    - get
    - list
    - watch
- apiGroups:
    - ""
  resources:
    - namespaces
  verbs:
    - get
    - list
    - watch
- apiGroups:
    - apps
  resources:
    - controllerrevisions
    - daemonsets
    - daemonsets/status
    - deployments
    - deployments/scale
    - deployments/status
    - replicasets
    - replicasets/scale
    - replicasets/status
    - statefulsets
    - statefulsets/scale
    - statefulsets/status
  verbs:
    - get
    - list
    - watch
- apiGroups:
    - autoscaling
  resources:
    - horizontalpodautoscalers
    - horizontalpodautoscalers/status
  verbs:
    - get
    - list
    - watch
- apiGroups:
    - batch
  resources:
    - cronjobs
    - cronjobs/status
    - jobs
    - jobs/status
  verbs:
    - get
    - list
    - watch
- apiGroups:
    - extensions
  resources:
    - daemonsets
    - daemonsets/status
    - deployments
    - deployments/scale
    - deployments/status
    - ingresses
    - ingresses/status
    - networkpolicies
    - replicasets
    - replicasets/scale
    - replicasets/status
    - replicationcontrollers/scale
  verbs:
    - get
    - list
    - watch
- apiGroups:
    - policy
  resources:
    - poddisruptionbudgets
    - poddisruptionbudgets/status
  verbs:
    - get
    - list
    - watch
- apiGroups:
    - networking.k8s.io
  resources:
    - ingresses
    - ingresses/status
    - networkpolicies
  verbs:
    - get
    - list
    - watch
{{- end }}
