{{- define "vds.vdevNamespace" -}}{{ .Values.device.teamspace }}-vdev{{- end }}
{{- define "vds.renderNamespace" -}}teknoir-vdev-spike{{- end }}

{{/* The kit's labels (same as hack/virtual-device-spike/render.sh). */}}
{{- define "vds.labels" -}}
teknoir.org/teamspace: {{ .Values.device.teamspace }}
teknoir.org/component: virtual-device
teknoir.org/spike: s1
app.kubernetes.io/managed-by: vd-spike-kit
{{- end }}
