{{/*
Issuer of the platform realm, e.g. https://auth.teknoir.airgapped/auth/realms/teknoir.
istiod fetches its JWKS over https and trusts the Teknoir CA through
/cacerts/extra.pem (istio chart); Backstage trusts it via NODE_EXTRA_CA_CERTS.
*/}}
{{- define "backstage.oidcIssuer" -}}
{{- printf "https://auth.%s%s/realms/%s" .Values.config.domain (trimSuffix "/" .Values.config.oidc.basePath) .Values.config.oidc.realm -}}
{{- end }}

{{/*
API group -> resources that @backstage/plugin-kubernetes-backend reads for
rbac.kubernetesPlugin.objectTypes (its DEFAULT_OBJECTS group/plural per
objectType; "pods" also reads metrics.k8s.io pods for the pod metrics). The
same list is rendered as app-config kubernetes.objectTypes, so the plugin
asks for exactly what RBAC allows. Output: YAML map, for fromYaml.
*/}}
{{- define "backstage.kubernetesPluginResources" -}}
{{- $groups := dict "pods" "" "services" "" "configmaps" "" "limitranges" "" "resourcequotas" "" "deployments" "apps" "replicasets" "apps" "statefulsets" "apps" "daemonsets" "apps" "horizontalpodautoscalers" "autoscaling" "jobs" "batch" "cronjobs" "batch" "ingresses" "networking.k8s.io" -}}
{{- $out := dict -}}
{{- range ((.Values.rbac | default dict).kubernetesPlugin | default dict).objectTypes | default list -}}
{{- if not (hasKey $groups .) -}}
{{- fail (printf "rbac.kubernetesPlugin.objectTypes: unknown object type %q (allowed: %s)" . (keys $groups | sortAlpha | join ", ")) -}}
{{- end -}}
{{- $g := get $groups . -}}
{{- $_ := set $out $g (append (get $out $g | default list) .) -}}
{{- if eq . "pods" -}}
{{- $_ := set $out "metrics.k8s.io" (list "pods") -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}
