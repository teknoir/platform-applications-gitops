{{- /*
The promotion steps of one pin Stage (stage-pins.yaml), rendered per group by Helm instead of shared as a Kargo
PromotionTask: the number of images and the value style differ per group, which a PromotionTask's string
variables cannot express (plans/cicd/v4/p42-spec.md "Deviations").

Input: (dict "group" <entry of .Values.groups> "root" $).
  - clone the gitops branch;
  - rewrite every image's key from the Freight's image references: one yaml-update step per target file, in order
    of first appearance (an image's `files`, else pins/<group>.yaml; the aliases are update, update2, update3, ...);
  - commit with the component names in the message (plan 7.1 searches commits by image name);
  - push a per-promotion branch, open a pull request, merge it (squash) and wait for the merge;
  - skip push, PR and merge when the commit step made no new commit (the images are already pinned).
Aliases have no hyphens (Kargo expressions address step outputs as outputs.<alias>.<field>).
*/ -}}
{{- define "kargo-config.pinSteps" -}}
{{- $g := .group -}}
{{- $gitops := .root.Values.gitops -}}
{{- $msg := include "kargo-config.pinMessage" $g -}}
{{- /* The distinct target files, in order of first appearance: an image's `files`, else pins/<group>.yaml. */ -}}
{{- $files := list -}}
{{- range $img := $g.images -}}
{{- range $f := ($img.files | default (list (printf "pins/%s.yaml" $g.name))) -}}
{{- if not (has $f $files) -}}
{{- $files = append $files $f -}}
{{- end -}}
{{- end -}}
{{- end -}}
- uses: git-clone
  as: clone
  config:
    repoURL: {{ $gitops.repoURL }}
    author:
      name: {{ $gitops.author.name | quote }}
      email: {{ $gitops.author.email | quote }}
    checkout:
      # The release branch, not the Freight (the Freight is an image tag, and the pins are read from the branch).
      - branch: {{ $gitops.branch }}
        path: ./src
{{- range $i, $f := $files }}
- uses: yaml-update
  as: {{ if eq $i 0 }}update{{ else }}update{{ add $i 1 }}{{ end }}
  config:
    path: ./src/{{ $f }}
    updates:
{{- range $img := $g.images }}
{{- if has $f ($img.files | default (list (printf "pins/%s.yaml" $g.name))) }}
      - key: {{ $img.key | quote }}
        value: {{ include "kargo-config.pinValue" (dict "image" $img) | squote }}
{{- end }}
{{- end }}
{{- end }}
- uses: git-commit
  as: commit
  config:
    path: ./src
    message: {{ $msg | squote }}
# git-commit reports Skipped (output commit = HEAD) when the Freight's images are already pinned. Push, PR and
# merge are then skipped and the Promotion still succeeds: Kargo counts Skipped as Succeeded. An explicit `if`
# drops Kargo's default skip-after-failure, hence success(). git-open-pr is Skipped with no output when the
# branch equals the target, hence the guard on merge.
- uses: git-push
  as: push
  if: {{ include "kargo-config.expr" "success() && status('commit') == 'Succeeded'" | quote }}
  # GitHub sometimes rejects one of several pushes that arrive at once ("remote rejected ... (failed)", 2026-11-25:
  # three groups pinned together and pin-notebook-controller errored). Kargo then never re-promotes that Freight
  # on its own (a non-successful last Promotion stops auto-promotion), so retry here. Re-pushing the same commit
  # to the same per-promotion branch is idempotent. Only push: a retried openpr or merge could act twice.
  retry:
    errorThreshold: 3
  config:
    path: ./src
    # One branch per promotion name: two promotions of one group never race on the same branch.
    targetBranch: {{ printf "%s/%s" $gitops.pinBranchPrefix (include "kargo-config.promotion" "") | squote }}
- uses: git-open-pr
  as: openpr
  if: {{ include "kargo-config.expr" "success() && status('push') == 'Succeeded'" | quote }}
  config:
    repoURL: {{ $gitops.repoURL }}
    provider: github
    sourceBranch: {{ include "kargo-config.output" "push.branch" | squote }}
    targetBranch: {{ $gitops.branch }}
    title: {{ $msg | squote }}
- uses: git-merge-pr
  as: merge
  if: {{ include "kargo-config.expr" "success() && status('openpr') == 'Succeeded'" | quote }}
  # Required checks (render, helm-unittest, ...) gate the merge: wait for them, and give up after 30 minutes.
  retry:
    timeout: 30m
  config:
    repoURL: {{ $gitops.repoURL }}
    provider: github
    prNumber: {{ include "kargo-config.output" "openpr.pr.id" | squote }}
    mergeMethod: squash
    wait: true
    pollInterval: 60s
    deleteSourceBranch: true
{{- end -}}
