{{- define "release-guard.labels" -}}
app.kubernetes.io/name: release-guard
app.kubernetes.io/part-of: teknoir-release-guard
{{- end -}}

{{- define "release-guard.releaserUser" -}}
system:serviceaccount:{{ .Values.namespace }}:{{ .Values.releaser.serviceAccount }}
{{- end -}}

{{/* Fail the render of THIS chart on a bad mode; a failure here only affects the release-guard Application. */}}
{{- define "release-guard.actions" -}}
{{- if eq .Values.guard.mode "Warn" -}}["Warn", "Audit"]
{{- else if eq .Values.guard.mode "Deny" -}}["Deny", "Audit"]
{{- else -}}{{ fail (printf "guard.mode must be Warn or Deny, got %q" .Values.guard.mode) }}
{{- end -}}
{{- end -}}

{{/*
CEL building blocks of the operation rule (see policy.yaml, "operations"). Each is ONE line of CEL so it can be
included into a folded YAML scalar. They are used twice, in matchConditions (which cannot reference variables)
and in the variables/validations.

ArgoCD v3.5.1 writes operation.sync as follows (verified in the source, tag v3.5.1):
  server/application/application.go Sync (UI Sync button, `argocd app sync`):
      source = copy of spec.source (single source, else omitted), sources = spec.sources, revision = the revision
      RESOLVED for the request (the request's, else spec.source.targetRevision resolved: a commit SHA when
      targetRevision is a branch or tag, the chart version for a Helm repo), revisions = per-source resolved.
  controller/appcontroller.go autoSync: the same, with revision = status.sync.revision (resolved).
The operation then stays on the object until the controller completes it, so ANY later write of the Application
(for example the releaser patching the root while an autosync is Running) carries the same operation.
*/}}

{{/* the request creates or changes the operation (UPDATE only; object and oldObject are not null) */}}
{{- define "release-guard.opChanged" -}}
has(object.operation) && (!has(oldObject.operation) || object.operation != oldObject.operation)
{{- end -}}

{{/* the operation is a plain sync of the Application's own spec: no own source(s), revision(s) empty or the
     Application's own (targetRevision; for a symbolic targetRevision, the revision ArgoCD resolved for it) */}}
{{- define "release-guard.opOk" -}}
!has(object.operation) || !has(object.operation.sync) || (
(!has(object.operation.sync.source) || (has(object.spec.source) && object.operation.sync.source == object.spec.source)) &&
(!has(object.operation.sync.sources) || size(object.operation.sync.sources) == 0 || (has(object.spec.sources) && object.operation.sync.sources == object.spec.sources)) &&
(!has(object.operation.sync.revision) || object.operation.sync.revision == '' ||
  object.operation.sync.revision == (has(object.spec.source) && has(object.spec.source.targetRevision) ? object.spec.source.targetRevision : '') ||
  (!(has(object.spec.source) && has(object.spec.source.targetRevision) && object.spec.source.targetRevision.matches('^[0-9a-f]{40}$')) &&
   oldObject != null && has(oldObject.status) && has(oldObject.status.sync) && has(oldObject.status.sync.revision) &&
   object.operation.sync.revision == oldObject.status.sync.revision)) &&
(!has(object.operation.sync.revisions) || object.operation.sync.revisions.all(r, r == '') ||
  object.operation.sync.revisions == (has(object.spec.sources) && size(object.spec.sources) > 0 ? object.spec.sources.map(s, has(s.targetRevision) ? s.targetRevision : '') :
                                      [has(object.spec.source) && has(object.spec.source.targetRevision) ? object.spec.source.targetRevision : '']) ||
  (oldObject != null && has(oldObject.status) && has(oldObject.status.sync) && has(oldObject.status.sync.revisions) &&
   object.operation.sync.revisions == oldObject.status.sync.revisions &&
   !(has(object.spec.sources) && object.spec.sources.exists(s, has(s.targetRevision) && s.targetRevision.matches('^[0-9a-f]{40}$'))))))
{{- end -}}
