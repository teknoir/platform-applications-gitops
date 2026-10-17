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

{{/* the operation is a plain sync of the Application's own spec: no own source(s), no manifests, revision(s) empty
     or the Application's own targetRevision. Nothing is read from oldObject: a status (the CRD has no status
     subresource, so anyone can write it) must not be able to widen what counts as plain. For a symbolic
     targetRevision (a branch) argocd-server writes the resolved SHA, which is therefore NOT plain: the guard is
     enabled only after the cutover, when every gitops child is pinned to a SHA and every plugin app to a chart
     version. */}}
{{- define "release-guard.opOk" -}}
!has(object.operation) || !has(object.operation.sync) || (
(!has(object.operation.sync.source) || (has(object.spec.source) && object.operation.sync.source == object.spec.source)) &&
(!has(object.operation.sync.sources) || size(object.operation.sync.sources) == 0 || (has(object.spec.sources) && object.operation.sync.sources == object.spec.sources)) &&
(!has(object.operation.sync.manifests) || size(object.operation.sync.manifests) == 0) &&
(!has(object.operation.sync.revision) || object.operation.sync.revision == '' ||
  object.operation.sync.revision == (has(object.spec.source) && has(object.spec.source.targetRevision) ? object.spec.source.targetRevision : '')) &&
(!has(object.operation.sync.revisions) || object.operation.sync.revisions.all(r, r == '') ||
  object.operation.sync.revisions == (has(object.spec.sources) && size(object.spec.sources) > 0 ? object.spec.sources.map(s, has(s.targetRevision) ? s.targetRevision : '') :
                                      [has(object.spec.source) && has(object.spec.source.targetRevision) ? object.spec.source.targetRevision : ''])))
{{- end -}}

{{/* the root's release annotations (teknoir.org/release, teknoir.org/previous-release) differ between oldObject and
     object: they name the live release (scripts/staging-status and staging-release read them, rule (c) ties
     releaseName to the first), so only the releaser (or break-glass) may change them */}}
{{- define "release-guard.releaseAnnotationChanged" -}}
object.metadata.name == '{{ .Values.guard.rootApplication }}' && (
(has(object.metadata.annotations) && 'teknoir.org/release' in object.metadata.annotations ? object.metadata.annotations['teknoir.org/release'] : '') !=
(has(oldObject.metadata.annotations) && 'teknoir.org/release' in oldObject.metadata.annotations ? oldObject.metadata.annotations['teknoir.org/release'] : '') ||
(has(object.metadata.annotations) && 'teknoir.org/previous-release' in object.metadata.annotations ? object.metadata.annotations['teknoir.org/previous-release'] : '') !=
(has(oldObject.metadata.annotations) && 'teknoir.org/previous-release' in oldObject.metadata.annotations ? oldObject.metadata.annotations['teknoir.org/previous-release'] : ''))
{{- end -}}
