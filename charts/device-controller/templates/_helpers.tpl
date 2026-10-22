{{/*
Expand the name of the chart.
*/}}
{{- define "device-controller.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "device-controller.fullname" -}}
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
{{- define "device-controller.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "device-controller.labels" -}}
helm.sh/chart: {{ include "device-controller.chart" . }}
{{ include "device-controller.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "device-controller.selectorLabels" -}}
app.kubernetes.io/name: {{ include "device-controller.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "device-controller.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "device-controller.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Virtual devices: whole-number parsing for the allowance and maxPerDevice values.
Called with a dict: value (the raw value), unit ("" or "Gi"), what (for the error).
Returns the digits as a string; fails the render, naming the field, if malformed.
*/}}
{{- define "device-controller.vdev.whole" -}}
{{- $s := toString .value -}}
{{- if not (regexMatch (printf "^[1-9][0-9]{0,5}%s$" .unit) $s) -}}
{{- fail (printf "virtualDevices: %s must be a whole number%s greater than zero (got %q)" .what (ternary " followed by Gi" "" (eq .unit "Gi")) $s) -}}
{{- end -}}
{{- trimSuffix .unit $s -}}
{{- end }}

{{/*
Virtual devices: the device count of an allowance. Like "whole" but 0 is allowed: an
entry with devices: 0 is the GitOps revoke form (the isolation objects keep rendering,
the allowance admits nothing). Called with a dict: value, what.
*/}}
{{- define "device-controller.vdev.devices" -}}
{{- $s := toString .value -}}
{{- if not (regexMatch "^(0|[1-9][0-9]{0,5})$" $s) -}}
{{- fail (printf "virtualDevices: %s must be a whole number, 0 or greater (0 revokes the allowance) (got %q)" .what $s) -}}
{{- end -}}
{{- $s -}}
{{- end }}

{{/*
Virtual devices: the ResourceQuota hard limits for one allowance. Integer math only
(2.2*S would round wrongly in floating point). Called with a dict: ns, allowance,
overcommit. Renders the YAML map entries of spec.hard.
  requests.cpu = ceil(C*1000/O)+1000m   limits.cpu = C+1
  requests.memory = (M+D)Gi            limits.memory = (M+D+1)Gi
  requests.storage = ceil(2.2*S)Gi
With devices: 0 (revoked) the VM/VMI/DataVolume counts are 0, so nothing new can be
created; pods, PVCs and Secrets keep the headroom of one device so existing guests can
still restart or reschedule.
*/}}
{{- define "device-controller.vdev.hard" -}}
{{- $w := printf "virtualDevices.allowances.%s" .ns -}}
{{- $d := atoi (include "device-controller.vdev.devices" (dict "value" .allowance.devices "what" (printf "%s.devices" $w))) -}}
{{- $c := atoi (include "device-controller.vdev.whole" (dict "value" .allowance.cpu "unit" "" "what" (printf "%s.cpu" $w))) -}}
{{- $m := atoi (include "device-controller.vdev.whole" (dict "value" .allowance.memory "unit" "Gi" "what" (printf "%s.memory" $w))) -}}
{{- $s := atoi (include "device-controller.vdev.whole" (dict "value" .allowance.disk "unit" "Gi" "what" (printf "%s.disk" $w))) -}}
{{- $o := atoi (include "device-controller.vdev.whole" (dict "value" .overcommit "unit" "" "what" "virtualDevices.cpuOvercommit")) -}}
requests.cpu: {{ printf "%dm" (add (div (add (mul $c 1000) (sub $o 1)) $o) 1000) | quote }}
limits.cpu: {{ add $c 1 | toString | quote }}
{{- $h := max $d 1 }}
requests.memory: {{ printf "%dGi" (add $m $h) | quote }}
limits.memory: {{ printf "%dGi" (add $m $h 1) | quote }}
requests.storage: {{ printf "%dGi" (div (add (mul 22 $s) 9) 10) | quote }}
persistentvolumeclaims: {{ mul 3 $h | toString | quote }}
pods: {{ mul 3 $h | toString | quote }}
count/secrets: {{ add (mul 2 $h) 2 | toString | quote }}
count/virtualmachines.kubevirt.io: {{ $d | toString | quote }}
count/virtualmachineinstances.kubevirt.io: {{ $d | toString | quote }}
count/datavolumes.cdi.kubevirt.io: {{ $d | toString | quote }}
services: "0"
services.loadbalancers: "0"
services.nodeports: "0"
requests.nvidia.com/gpu: "0"
{{- end }}

{{/*
Virtual devices: the allowance annotation the controller and Backstage read
(teknoir.org/allowance), compact JSON in a fixed key order from the validated values.
Called with a dict: ns, allowance.
*/}}
{{- define "device-controller.vdev.allowanceJSON" -}}
{{- $w := printf "virtualDevices.allowances.%s" .ns -}}
{{- $d := atoi (include "device-controller.vdev.devices" (dict "value" .allowance.devices "what" (printf "%s.devices" $w))) -}}
{{- $c := atoi (include "device-controller.vdev.whole" (dict "value" .allowance.cpu "unit" "" "what" (printf "%s.cpu" $w))) -}}
{{- $m := atoi (include "device-controller.vdev.whole" (dict "value" .allowance.memory "unit" "Gi" "what" (printf "%s.memory" $w))) -}}
{{- $s := atoi (include "device-controller.vdev.whole" (dict "value" .allowance.disk "unit" "Gi" "what" (printf "%s.disk" $w))) -}}
{{- printf "{\"devices\":%d,\"cpu\":\"%d\",\"memory\":\"%dGi\",\"disk\":\"%dGi\"}" $d $c $m $s -}}
{{- end }}

{{/*
Virtual devices: the VIRTUAL_DEVICES JSON for the controller (no allowances: those live
on the quota annotation). Only included in the ConfigMap when virtualDevices.enabled.
*/}}
{{- define "device-controller.vdev.configJSON" -}}
{{- $v := .Values.virtualDevices -}}
{{- $mp := $v.maxPerDevice | default dict -}}
{{- $o := atoi (include "device-controller.vdev.whole" (dict "value" $v.cpuOvercommit "unit" "" "what" "virtualDevices.cpuOvercommit")) -}}
{{- $c := atoi (include "device-controller.vdev.whole" (dict "value" $mp.cpu "unit" "" "what" "virtualDevices.maxPerDevice.cpu")) -}}
{{- $m := atoi (include "device-controller.vdev.whole" (dict "value" $mp.memory "unit" "Gi" "what" "virtualDevices.maxPerDevice.memory")) -}}
{{- $s := atoi (include "device-controller.vdev.whole" (dict "value" $mp.disk "unit" "Gi" "what" "virtualDevices.maxPerDevice.disk")) -}}
{{- $max := dict "cpu" (printf "%d" $c) "memory" (printf "%dGi" $m) "disk" (printf "%dGi" $s) -}}
{{- $c := dict "enabled" true "osImage" $v.osImage "k3sVersion" $v.k3sVersion "innerCIDRs" $v.innerCIDRs "cpuOvercommit" $o "maxPerDevice" $max "storageClassName" $v.storageClassName "priorityClassName" $v.priorityClassName -}}
{{- with $v.nodeSelector }}{{- $_ := set $c "nodeSelector" . -}}{{- end -}}
{{- with $v.tolerations }}{{- $_ := set $c "tolerations" . -}}{{- end -}}
{{- toJson $c -}}
{{- end }}

{{/*
ZTNA: the ZTNA JSON for the controller (key ZTNA of the parameters ConfigMap; the controller's
ZTNAConfig, internal/controller/utils/ztna_config.go). Only included in the ConfigMap when
ztna.enabled. The images are required: the controller refuses an enabled config without them.
*/}}
{{- define "device-controller.ztna.configJSON" -}}
{{- $z := .Values.ztna -}}
{{- $c := dict "enabled" true "hubNamespace" $z.hubNamespace "agentImage" (required "ztna.agentImage is required when ztna.enabled (the wg-agent image, '<tag>@sha256:<digest>')" $z.agentImage) "terminalImage" (required "ztna.terminalImage is required when ztna.enabled (the WireGuard web terminal image)" $z.terminalImage) "allowedPorts" $z.allowedPorts "enrollWindowMinutes" (int $z.enrollWindowMinutes) -}}
{{- if $z.ingressPrincipals }}{{- $_ := set $c "ingressPrincipals" $z.ingressPrincipals -}}{{- end -}}
{{- /* hasKey, not if: an explicit [] must reach the controller (no inspect rule); an absent key means its default */ -}}
{{- if hasKey $z "inspectPrincipals" }}{{- $_ := set $c "inspectPrincipals" $z.inspectPrincipals -}}{{- end -}}
{{- if $z.attestorEnabled }}{{- $_ := set $c "attestorEnabled" true -}}{{- end -}}
{{- if $z.gatewayImage }}{{- $_ := set $c "gatewayImage" $z.gatewayImage -}}{{- end -}}
{{- if $z.terminalRunAsUser }}{{- $_ := set $c "terminalRunAsUser" (int64 $z.terminalRunAsUser) -}}{{- end -}}
{{- /* Tunneling on by default (device-controller wg-default-on, plans/ssh-tunnel-removal.md): only
emitted when set, so an older controller image never sees the keys. */ -}}
{{- if $z.defaultOn }}{{- $_ := set $c "defaultOn" true -}}{{- end -}}
{{- if $z.deviceKeyWindowMinutes }}{{- $_ := set $c "deviceKeyWindowMinutes" (int $z.deviceKeyWindowMinutes) -}}{{- end -}}
{{- toJson $c -}}
{{- end }}
