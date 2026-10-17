{{/*
ZTNA (WireGuard over STUNner) gate. Renders "true" or "" (use with `if include`).

Two gates, both required:
  1. ztna.enabled: true in this environment's values (a missing key is off);
  2. the environment (.Values.project) is in the allowlist below.

The allowlist lives here, not in values, for the same reason as in
virtual-devices.yaml: the environment branches are kept in step by cherry-pick,
and a cherry-pick that brings this file and an enabled flag onto teknoir-online
(production) or teknoir-local (airgapped) must still render nothing there. An
environment that is not listed renders nothing instead of failing, because a
failed render of the root app-of-apps would stop every Application of that
environment from syncing. Add an environment only in its own reviewed commit.
*/}}
{{- define "app-of-apps.ztnaEnabled" -}}
{{- $allowedProjects := list "teknoir-cloud" -}}
{{- if and (.Values.ztna).enabled (has .Values.project $allowedProjects) -}}true{{- end -}}
{{- end -}}

{{/*
targetRevision of every Application that reads this repository (gitops release gate).

  teknoir-cloud (staging): .Values.release (a full 40-hex commit SHA, passed by
                           scripts/staging-release as a helm parameter of the root Application);
                           falls back to the branch name while release is unset (before the cutover
                           and when rendered locally), so the render is the same as before.
  any other project:       .Values.project (the branch), exactly as before.

The project allowlist is here, not in values, for the same reason as app-of-apps.ztnaEnabled: the
environment branches are kept in step by cherry-pick, and a cherry-pick of this file together with a
release value onto teknoir-online (production) or teknoir-local (airgapped) must still follow the
branch there. There is deliberately NO `required` anywhere: a failed render of the root would stop
every Application of the environment from syncing. The release lint (scripts/check-pins.py) enforces
that staging has `release` set, not the template.
*/}}
{{- define "app-of-apps.revision" -}}
{{- $releaseProjects := list "teknoir-cloud" -}}
{{- if has .Values.project $releaseProjects -}}
{{- .Values.release | default .Values.project -}}
{{- else -}}
{{- .Values.project -}}
{{- end -}}
{{- end -}}

{{/*
Release guard gate (charts/release-guard: ValidatingAdmissionPolicy + releaser ServiceAccount). Renders
"true" or "" (use with `if include`). Two gates, both required: releaseGuard.enabled: true AND the
project is in the allowlist (teknoir-cloud only, staging). Add an environment only in its own reviewed
commit.
*/}}
{{- define "app-of-apps.releaseGuardEnabled" -}}
{{- $allowedProjects := list "teknoir-cloud" -}}
{{- if and (.Values.releaseGuard).enabled (has .Values.project $allowedProjects) -}}true{{- end -}}
{{- end -}}
