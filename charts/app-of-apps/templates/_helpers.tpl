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
"true" when the kargo Application renders (templates/kargo.yaml: teknoir-cloud only, argoRollouts.enabled and
kargo.enabled), else "". templates/auth.yaml passes it to charts/auth as kargo.enabled: the Keycloak clients
kargo and kargo-cli and the edge-login bypass for kargo.<domain> exist only while Kargo does.
*/}}
{{- define "app-of-apps.kargoEnabled" -}}
{{- if and (has .Values.project (list "teknoir-cloud")) (.Values.argoRollouts).enabled (.Values.kargo).enabled -}}true{{- end -}}
{{- end -}}

{{/*
targetRevision of every Application that reads this repository (gitops release gate).

  teknoir-cloud (staging): .Values.release (a full 40-hex commit SHA). Kargo sets the root
                           Application's targetRevision to the main commit it verified and passes
                           release=$ARGOCD_APP_REVISION as a helm parameter, so every child follows
                           that commit too; while release is unset (a local render) it falls back to
                           `main`, the gitops branch.
  any other project:       .Values.project (the branch: teknoir-online, teknoir-local).

The project allowlist is here, not in values, for the same reason as app-of-apps.ztnaEnabled: the
environment branches are kept in step by cherry-pick, and a cherry-pick of this file together with a
release value onto teknoir-online (production) or teknoir-local (airgapped) must still follow the
branch there. There is deliberately NO `required` anywhere: a failed render of the root would stop
every Application of the environment from syncing. The lint (scripts/check-pins.py) checks the
release only when --release is given (CI always gives it); the template does not enforce it.
*/}}
{{- define "app-of-apps.revision" -}}
{{- $releaseProjects := list "teknoir-cloud" -}}
{{- if has .Values.project $releaseProjects -}}
{{- .Values.release | default "main" -}}
{{- else -}}
{{- .Values.project -}}
{{- end -}}
{{- end -}}

{{/*
TeknoirBot agent API gate (plans/teknoirbot/design/agent-mvp-design.md D3, WP13). Renders "true" or "".
All required: teknoirbot.enabled, teknoirbot.agent.enabled, the ZTNA gate (bots are reached over Tunneling and their
VMs use the public gateway's egress rules) and the teknoir-cloud allowlist. One switch passes:
  - teknoirbotApi.enabled to istio (Gateway tb-api.<domain>:8085 + ClusterIP Service), virtual-devices (CoreDNS
    rewrite) and device-controller (VM egress to 8085);
  - teknoirBots.agent.enabled to backstage (bot routes, VirtualService, AuthorizationPolicy rules).
*/}}
{{- define "app-of-apps.botAgentEnabled" -}}
{{- $allowedProjects := list "teknoir-cloud" -}}
{{- if and (.Values.teknoirbot).enabled ((.Values.teknoirbot).agent).enabled (include "app-of-apps.ztnaEnabled" .) (has .Values.project $allowedProjects) -}}true{{- end -}}
{{- end -}}

{{/*
Plugin git mode gate (CI v4 P9.1): renders "true" or "". Both required:
  - profileController.pluginGit.enabled is true in this environment's values (a missing key, false or the string
    "false" is off; only true or "true" is on);
  - the environment (.Values.project) is in the allowlist below.
When it is true, templates/controllers.yaml passes config.pluginGit.repoURL (this repository) and
config.pluginGit.revision (app-of-apps.revision, the root's verified commit) to the profile-controller Application,
and profile-controller renders every profile-plugin-<x> Application from plugins/charts/profile-plugin-<x> instead of
the pluginChartVersion chart (charts/profile-controller values.yaml, plugins/charts/README.md).
The allowlist lives here, not in values, for the same reason as in app-of-apps.ztnaEnabled: a cherry-pick of this file
and an enabled flag onto teknoir-online (production) or teknoir-local (airgapped) must still render nothing there.
*/}}
{{- define "app-of-apps.pluginGitEnabled" -}}
{{- $allowedProjects := list "teknoir-cloud" -}}
{{- if and (eq (toString ((.Values.profileController).pluginGit).enabled) "true") (has .Values.project $allowedProjects) -}}true{{- end -}}
{{- end -}}

{{/*
The device-controller retainedConfigRepublish value of this environment (plans/teknoirbot/root-in-vm.md R0, D13):
app-of-apps values deviceController.retainedConfigRepublish, passed to the device-controller Application as a helm
parameter by templates/controllers.yaml, inside its teknoir-cloud allowlist. Renders "off", "log", "on" or the raw
value: an absent or empty value and a bare off (YAML 1.1 boolean false) are "off", a bare on (true) is "on". No
validation here, because a failed render of the root would stop every Application of the environment from syncing:
charts/device-controller fails its own render for any other value, which stops only that child (and the CI render).
*/}}
{{- define "app-of-apps.retainedConfigRepublish" -}}
{{- $raw := (.Values.deviceController).retainedConfigRepublish -}}
{{- $v := ternary "" (toString $raw) (kindIs "invalid" $raw) -}}
{{- if or (eq $v "false") (eq $v "") -}}off{{- else if eq $v "true" -}}on{{- else -}}{{ $v }}{{- end -}}
{{- end -}}
