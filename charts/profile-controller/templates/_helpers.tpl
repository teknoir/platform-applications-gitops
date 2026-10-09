{{- define "profile-controller.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "profile-controller.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "profile-controller.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "profile-controller.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "profile-controller.selectorLabels" -}}
app.kubernetes.io/name: {{ include "profile-controller.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- /*
profile-controller.istiodFetchableUrl (list <value name> <url>): fails unless
<url> is https:// and not a cluster-internal host (*.svc, *.cluster.local).
istiod resolves RequestAuthentication issuers/jwksUri from istio-system
without a sidecar.
*/}}
{{- define "profile-controller.istiodFetchableUrl" -}}
{{- $name := index . 0 -}}
{{- $url := index . 1 | toString -}}
{{- if not (hasPrefix "https://" $url) -}}
{{- fail (printf "%s %q: must be an https:// URL that istiod can fetch (leave config.oidcJwksUri empty for <oidcIssuer>/protocol/openid-connect/certs)" $name $url) -}}
{{- end -}}
{{- if regexMatch "^https://[^/]*\\.(svc|cluster\\.local)(:[0-9]+)?(/|$)" $url -}}
{{- fail (printf "%s %q: a cluster-internal host; istiod fetches it without a sidecar (leave config.oidcJwksUri empty for <oidcIssuer>/protocol/openid-connect/certs)" $name $url) -}}
{{- end -}}
{{- end -}}

{{- /*
Names a teamspace (a Profile, its namespace and its AppProject) never has:
platform namespaces and the platform AppProjects of every environment.
Prefix kube- is refused as well. Used by templates/profiles.yaml and by the
admission policies.
*/}}
{{- define "profile-controller.reservedNames" -}}
default teknoir teknoir-local teknoir-cloud teknoir-online teknoir-system teknoir-auth teknoir-user-credentials istio-system cert-manager
{{- end -}}

{{- /*
The plugin chart repository the controller uses: config.pluginChartRepo, or
its compiled default (profile-controller main.go) when that is empty.
*/}}
{{- define "profile-controller.pluginChartRepo" -}}
{{- .Values.config.pluginChartRepo | default "https://teknoir.github.io/profile-plugins-helm" -}}
{{- end -}}

{{- /* The controller's ServiceAccount as an authenticated user name. */}}
{{- define "profile-controller.serviceAccountUser" -}}
system:serviceaccount:{{ .Release.Namespace }}:{{ include "profile-controller.fullname" . }}
{{- end -}}
