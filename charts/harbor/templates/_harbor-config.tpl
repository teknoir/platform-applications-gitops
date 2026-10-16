{{/* Pod spec shared by the harbor-config hook Job and CronJob. */}}
{{- define "harbor.configPodSpec" -}}
{{- $cfg := .Values.harborConfig }}
serviceAccountName: harbor-config
restartPolicy: Never
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  runAsGroup: 65534
  seccompProfile: {type: RuntimeDefault}
containers:
  - name: harbor-config
    image: {{ $cfg.image }}
    imagePullPolicy: {{ $cfg.imagePullPolicy }}
    command: ["python3", "-I", "/config/harbor-config.py"]
    env:
      - name: HARBOR_URL
        value: http://harbor-core.{{ .Values.namespace | default .Release.Namespace }}.svc.cluster.local
      - name: HARBOR_HOST
        value: {{ .Values.hostname | quote }}
      - name: CONFIG
        value: /config/config.json
      - name: HARBOR_ADMIN_PASSWORD
        valueFrom:
          secretKeyRef:
            name: {{ $cfg.adminPasswordSecret.name }}
            key: {{ $cfg.adminPasswordSecret.key }}
    resources:
{{ toYaml $cfg.resources | indent 6 }}
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: {drop: ["ALL"]}
    volumeMounts:
      - {name: config, mountPath: /config, readOnly: true}
volumes:
  - name: config
    configMap: {name: harbor-config}
{{- end }}
