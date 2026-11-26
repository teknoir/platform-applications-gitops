{{- /*
Kargo expressions and Argo Rollouts placeholders are EMITTED LITERALLY. Helm must never parse them, so no
template below writes `${{` or `{{args.` in its own text: every one is produced by a helper with printf, and
the Kargo/Argo expression only appears in the rendered output. charts/kargo-config/tests asserts both
literals in the render.

Kargo's own syntax is `${{ ... }}` (Stage/Warehouse expressions); Argo Rollouts' is `{{ ... }}` (AnalysisTemplate
args, e.g. {{args.revision}}).
*/}}

{{/* ${{ commitFrom("<repoURL>").ID }} — the 40-hex commit the Freight was made from. */}}
{{- define "kargo-config.commitFromID" -}}
{{- printf "${{ commitFrom(%q).ID }}" . -}}
{{- end -}}

{{/* ${{ commitFrom("<repoURL>").ID[0:8] }} — its 8-hex short form (the sha-<8> build tag). */}}
{{- define "kargo-config.commitFromShort" -}}
{{- printf "${{ commitFrom(%q).ID[0:8] }}" . -}}
{{- end -}}

{{/* ${{ ctx.targetFreight.name }} */}}
{{- define "kargo-config.targetFreight" -}}
{{- printf "${{ ctx.targetFreight.name }}" -}}
{{- end -}}

{{/* ${{ ctx.promotion }} — the promotion name, unique per attempt (a branch suffix). */}}
{{- define "kargo-config.promotion" -}}
{{- printf "${{ ctx.promotion }}" -}}
{{- end -}}

{{/* ${{ outputs.<step>.<field> }} */}}
{{- define "kargo-config.output" -}}
{{- printf "${{ outputs.%s }}" . -}}
{{- end -}}

{{/* ${{ <expression> }}: a Kargo expression, e.g. a step `if`. */}}
{{- define "kargo-config.expr" -}}
{{- printf "${{ %s }}" . -}}
{{- end -}}

{{/* {{args.revision}} — an Argo Rollouts AnalysisTemplate argument, not a Kargo expression. */}}
{{- define "kargo-config.analysisArg.revision" -}}
{{- printf "{{args.revision}}" -}}
{{- end -}}

{{/*
The verified tag name, computed once by the compose-output step (Kargo cannot evaluate it twice consistently):
  time: <prefix>${{ now().UTC().Format("20060102T150405Z") }}-${{ commitFrom(<repo>).ID[0:8] }}
  none: <prefix>${{ commitFrom(<repo>).ID[0:8] }}
*/}}
{{- define "kargo-config.verifiedTag" -}}
{{- $sha := include "kargo-config.commitFromShort" .repoURL -}}
{{- if eq .verifiedTagStamp "none" -}}
{{- printf "%s%s" .verifiedTagPrefix $sha -}}
{{- else -}}
{{- printf "%s${{ now().UTC().Format(\"20060102T150405Z\") }}-%s" .verifiedTagPrefix $sha -}}
{{- end -}}
{{- end -}}

{{/* The new value of one pins/<group>.yaml key, by the image row's style (scripts/images.yaml):
     ref    repo:tag@sha256:<digest>   tag    tag@sha256:<digest>   digest sha256:<digest> (the tag stays). */}}
{{- define "kargo-config.pinValue" -}}
{{- $i := .image -}}
{{- if eq $i.style "ref" -}}
{{- printf "%s:${{ imageFrom(%q).Tag }}@${{ imageFrom(%q).Digest }}" $i.repository $i.poll $i.poll -}}
{{- else if eq $i.style "tag" -}}
{{- printf "${{ imageFrom(%q).Tag }}@${{ imageFrom(%q).Digest }}" $i.poll $i.poll -}}
{{- else -}}
{{- printf "${{ imageFrom(%q).Digest }}" $i.poll -}}
{{- end -}}
{{- end -}}

{{/* Warehouse.freightCreationCriteria.expression for a same_commit group: every image's tag equals the first
     image's tag, e.g. imageFrom("ghcr.io/x/a").Tag == imageFrom("ghcr.io/x/b").Tag && ... */}}
{{- define "kargo-config.sameCommitExpression" -}}
{{- $first := (index .images 0).poll -}}
{{- $conds := list -}}
{{- range $i, $img := .images -}}
{{- if $i -}}
{{- $conds = append $conds (printf "imageFrom(%q).Tag == imageFrom(%q).Tag" $first $img.poll) -}}
{{- end -}}
{{- end -}}
{{- join " && " $conds -}}
{{- end -}}

{{/* The pin commit message: the COMPONENT names (not the group: plan 7.1 searches commits by image name), the
     Freight's first image tag and [kargo], which marks the commit as Kargo's. */}}
{{- define "kargo-config.pinMessage" -}}
{{- $names := list -}}
{{- range .images -}}
{{- $names = append $names .component -}}
{{- end -}}
{{- printf "chore(pins): %s ${{ imageFrom(%q).Tag }} [kargo]" (join " " $names) (index .images 0).poll -}}
{{- end -}}

{{/*
The revision check's environment (files/revision-check.sh): the revision-check Job and the browser Job's
wait-converged init container run the same script with it.
*/}}
{{- define "kargo-config.revisionCheckEnv" -}}
- name: REVISION
  value: {{ include "kargo-config.analysisArg.revision" "" | squote }}
- name: ROOT_APP_NAME
  value: {{ .Values.verification.rootApp.name | quote }}
- name: ROOT_APP_NAMESPACE
  value: {{ .Values.verification.rootApp.namespace | quote }}
- name: EXCLUDE_APPS
  value: {{ join " " .Values.verification.excludeApps | quote }}
- name: DEVHOST_CI_SERVER
  value: {{ .Values.verification.devhostCiServer | quote }}
- name: GITOPS_REPO_URL
  value: {{ .Values.gitops.repoURL | quote }}
# The profile-controller ConfigMap in the root Application's namespace; its
# PLUGIN_CHART_VERSION key (charts/profile-controller templates/configmap.yaml) is the
# version every profile-plugin Application must follow, and a non-empty PLUGIN_GIT_REPO_URL
# (plus PLUGIN_GIT_PATH, default plugins/charts) switches the check to git mode.
- name: PLUGIN_CONFIGMAP
  value: {{ .Values.verification.pluginConfigMap.name | quote }}
- name: PLUGIN_NAMESPACE
  value: {{ .Values.verification.rootApp.namespace | quote }}
# Fewer selected profile-plugin Applications than this fails the promotion.
- name: PLUGIN_MIN_APPS
  value: {{ .Values.verification.pluginMinApps | quote }}
{{- end -}}
