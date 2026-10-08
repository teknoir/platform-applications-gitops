{{/*
Names. Fixed (not derived from .Release.Name) so the bootstrap `helm template`
render is byte-identical to ArgoCD's render.
*/}}
{{- define "platform-secrets.name" -}}platform-secrets{{- end }}

{{- define "platform-secrets.labels" -}}
app.kubernetes.io/name: platform-secrets
app.kubernetes.io/component: secret-generator
app.kubernetes.io/part-of: teknoir-platform
{{- end }}

{{/*
Validates .Values.secrets and renders the line-based spec that
files/ensure-secrets.sh reads (no jq/yq needed in the pod):

  S|<namespace>|<name>|<type>|<addMissingKeys 0|1>
  L|<label key>|<label value>
  K|<key>|random|<length>|<charset>|<bytes>|<encoding>|<format, base64>
  K|<key>|value|<value, base64>|<sync 0|1>
  K|<key>|copy|<source namespace>|<source name>|<source key>
  R|<namespace>|<deployment>
  E

Copy keys come after random/value keys, so a copy may refer to a key of the
Secret being created (DATA_SOURCE_PASS <- POSTGRES_PASSWORD).
*/}}
{{- define "platform-secrets.spec" -}}
{{- $seen := dict -}}
{{- $nameRe := "^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$" -}}
{{- $keyRe := "^[-._a-zA-Z0-9]+$" -}}
{{- $labelKeyRe := "^([a-z0-9]([-a-z0-9.]*[a-z0-9])?/)?[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$" -}}
{{- $labelValRe := "^([A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?)?$" -}}
{{- range $s := .Values.secrets }}
{{- if not (and $s.namespace $s.name) }}{{ fail "platform-secrets: every secret needs namespace and name" }}{{ end }}
{{- if not (regexMatch $nameRe $s.namespace) }}{{ fail (printf "platform-secrets: invalid namespace %q" $s.namespace) }}{{ end }}
{{- if not (regexMatch $nameRe $s.name) }}{{ fail (printf "platform-secrets: invalid secret name %q" $s.name) }}{{ end }}
{{- $id := printf "%s/%s" $s.namespace $s.name }}
{{- if hasKey $seen $id }}{{ fail (printf "platform-secrets: %s is listed twice" $id) }}{{ end }}
{{- $_ := set $seen $id true }}
{{- if not $s.keys }}{{ fail (printf "platform-secrets: %s has no keys" $id) }}{{ end }}
S|{{ $s.namespace }}|{{ $s.name }}|{{ $s.type | default "Opaque" }}|{{ ternary "1" "0" (default false $s.addMissingKeys) }}
{{- $labels := merge (dict) ($s.labels | default dict) (dict $.Values.managedByLabel.key $.Values.managedByLabel.value) }}
{{- range $lk := keys $labels | sortAlpha }}
{{- $lv := toString (get $labels $lk) }}
{{- if not (regexMatch $labelKeyRe $lk) }}{{ fail (printf "platform-secrets: %s: invalid label key %q" $id $lk) }}{{ end }}
{{- if not (regexMatch $labelValRe $lv) }}{{ fail (printf "platform-secrets: %s: invalid label value %q" $id $lv) }}{{ end }}
L|{{ $lk }}|{{ $lv }}
{{- end }}
{{- range $k := keys $s.keys | sortAlpha }}
{{- $spec := get $s.keys $k }}
{{- if not (regexMatch $keyRe $k) }}{{ fail (printf "platform-secrets: %s: invalid key name %q" $id $k) }}{{ end }}
{{- $kinds := 0 }}
{{- if hasKey $spec "random" }}{{ $kinds = add1 $kinds }}{{ end }}
{{- if hasKey $spec "value" }}{{ $kinds = add1 $kinds }}{{ end }}
{{- if hasKey $spec "copyFrom" }}{{ $kinds = add1 $kinds }}{{ end }}
{{- if ne (int $kinds) 1 }}{{ fail (printf "platform-secrets: %s key %q needs exactly one of random, value, copyFrom" $id $k) }}{{ end }}
{{- if hasKey $spec "random" }}
{{- $r := $spec.random | default dict }}
{{- $len := int ($r.length | default 0) }}
{{- $bytes := int ($r.bytes | default 0) }}
{{- $charset := $r.charset | default "alnum" }}
{{- $enc := $r.encoding | default "base64" }}
{{- if or (and (gt $len 0) (gt $bytes 0)) (and (le $len 0) (le $bytes 0)) }}{{ fail (printf "platform-secrets: %s key %q: random needs exactly one of length or bytes" $id $k) }}{{ end }}
{{- if not (has $charset (list "alnum" "hex")) }}{{ fail (printf "platform-secrets: %s key %q: charset must be alnum or hex" $id $k) }}{{ end }}
{{- if not (has $enc (list "base64" "base64url" "hex")) }}{{ fail (printf "platform-secrets: %s key %q: encoding must be base64, base64url or hex" $id $k) }}{{ end }}
{{- $fmt := $spec.format | default "%s" }}
{{- if not (contains "%s" $fmt) }}{{ fail (printf "platform-secrets: %s key %q: format must contain %%s" $id $k) }}{{ end }}
K|{{ $k }}|random|{{ $len }}|{{ $charset }}|{{ $bytes }}|{{ $enc }}|{{ $fmt | b64enc }}
{{- else if hasKey $spec "value" }}
K|{{ $k }}|value|{{ toString $spec.value | b64enc }}|{{ ternary "1" "0" (default false $spec.sync) }}
{{- end }}
{{- end }}
{{- range $k := keys $s.keys | sortAlpha }}
{{- $spec := get $s.keys $k }}
{{- if hasKey $spec "copyFrom" }}
{{- $parts := splitList "/" $spec.copyFrom }}
{{- if or (ne (len $parts) 3) (not (regexMatch $nameRe (index $parts 0))) (not (regexMatch $nameRe (index $parts 1))) (not (regexMatch $keyRe (index $parts 2))) }}{{ fail (printf "platform-secrets: %s key %q: copyFrom must be <namespace>/<secret>/<key>" $id $k) }}{{ end }}
{{- if and (eq (index $parts 0) $s.namespace) (eq (index $parts 1) $s.name) (eq (index $parts 2) $k) }}{{ fail (printf "platform-secrets: %s key %q copies itself" $id $k) }}{{ end }}
K|{{ $k }}|copy|{{ index $parts 0 }}|{{ index $parts 1 }}|{{ index $parts 2 }}
{{- end }}
{{- end }}
{{- range $d := $s.restartDeployments | default list }}
{{- $dp := splitList "/" $d }}
{{- if or (ne (len $dp) 2) (not (regexMatch $nameRe (index $dp 0))) (not (regexMatch $nameRe (index $dp 1))) }}{{ fail (printf "platform-secrets: %s: restartDeployments entries are <namespace>/<deployment>" $id) }}{{ end }}
R|{{ index $dp 0 }}|{{ index $dp 1 }}
{{- end }}
E
{{- end }}
{{- end }}

{{/*
Least-privilege RBAC plan as JSON: namespace -> {targets, sources, deployments}.
  targets:     Secrets this chart manages (get, patch; create is namespace-wide
               because Kubernetes cannot restrict create by name)
  sources:     Secrets read by copyFrom (get only)
  deployments: Deployments it may restart (get, patch)
*/}}
{{- define "platform-secrets.rbacPlan" -}}
{{- $plan := dict -}}
{{- range $s := .Values.secrets }}
{{- $ns := $s.namespace }}
{{- if not (hasKey $plan $ns) }}{{ $_ := set $plan $ns (dict "targets" list "sources" list "deployments" list) }}{{ end }}
{{- $e := get $plan $ns }}
{{- $_ := set $e "targets" (append (get $e "targets") $s.name | uniq) }}
{{- range $k, $spec := $s.keys }}
{{- if hasKey $spec "copyFrom" }}
{{- $parts := splitList "/" $spec.copyFrom }}
{{- $sns := index $parts 0 }}
{{- if not (hasKey $plan $sns) }}{{ $_ := set $plan $sns (dict "targets" list "sources" list "deployments" list) }}{{ end }}
{{- $se := get $plan $sns }}
{{- $_ := set $se "sources" (append (get $se "sources") (index $parts 1) | uniq) }}
{{- end }}
{{- end }}
{{- range $d := $s.restartDeployments | default list }}
{{- $dp := splitList "/" $d }}
{{- $dns := index $dp 0 }}
{{- if not (hasKey $plan $dns) }}{{ $_ := set $plan $dns (dict "targets" list "sources" list "deployments" list) }}{{ end }}
{{- $de := get $plan $dns }}
{{- $_ := set $de "deployments" (append (get $de "deployments") (index $dp 1) | uniq) }}
{{- end }}
{{- end }}
{{- toJson $plan -}}
{{- end }}

{{/*
Pod template shared by the hook Job and the CronJob.
*/}}
{{- define "platform-secrets.podTemplate" -}}
metadata:
  labels:
    {{- include "platform-secrets.labels" . | nindent 4 }}
    # Only talks to the API server; a sidecar would add nothing and is absent
    # anyway during the bootstrap one-shot (no istiod yet).
    sidecar.istio.io/inject: "false"
spec:
  serviceAccountName: {{ include "platform-secrets.name" . }}
  automountServiceAccountToken: true
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: ensure-secrets
      image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      command: ["/bin/sh", "/opt/platform-secrets/ensure-secrets.sh", "/opt/platform-secrets/secrets.spec"]
      env:
        - name: HOME
          value: /tmp
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      volumeMounts:
        - name: spec
          mountPath: /opt/platform-secrets
          readOnly: true
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: spec
      configMap:
        name: {{ include "platform-secrets.name" . }}
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 16Mi
{{- end }}
