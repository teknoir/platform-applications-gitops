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
