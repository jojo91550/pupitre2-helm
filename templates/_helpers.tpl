{{/*
Expand the name of the chart.
*/}}
{{- define "pupitre.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "pupitre.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "pupitre.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "pupitre.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "pupitre.api.labels" -}}
{{ include "pupitre.labels" . }}
app.kubernetes.io/component: api
{{- end }}

{{- define "pupitre.frontend.labels" -}}
{{ include "pupitre.labels" . }}
app.kubernetes.io/component: frontend
{{- end }}


{{/*
Selector labels
*/}}
{{- define "pupitre.api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pupitre.name" . }}
app.kubernetes.io/component: api
{{- end }}

{{- define "pupitre.frontend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pupitre.name" . }}
app.kubernetes.io/component: frontend
{{- end }}

{{- define "pupitre.postgresql.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pupitre.name" . }}
app.kubernetes.io/component: postgresql
{{- end }}


{{/*
Value kept from the release Secret on upgrades, so a generated secret is never
rotated unintentionally. Empty when the Secret or the key does not exist yet.
Takes (dict "root" $ "key" "<KEY>").
*/}}
{{- define "pupitre.existingSecretValue" -}}
{{- $secret := lookup "v1" "Secret" .root.Release.Namespace (printf "%s-secrets" (include "pupitre.fullname" .root)) -}}
{{- if and $secret $secret.data (index $secret.data .key) -}}
  {{- index $secret.data .key | b64dec -}}
{{- end -}}
{{- end }}

{{/*
Admin password resolution — priority order:
  1. admin.existingSecret → caller manages the Secret entirely, we do nothing.
  2. admin.password non-empty → use the explicit value from values.yaml.
  3. Secret already exists (upgrade) → reuse ADMIN_PASSWORD from the live Secret
     so we never rotate a previously auto-generated password unintentionally.
  4. First install with no value → generate a cryptographically random 32-char
     alphanumeric password and store it in our platform Secret.
*/}}
{{- define "pupitre.adminPassword" -}}
{{- if not .Values.admin.existingSecret -}}
  {{- if .Values.admin.password -}}
    {{- .Values.admin.password -}}
  {{- else -}}
    {{- $existing := include "pupitre.existingSecretValue" (dict "root" . "key" "ADMIN_PASSWORD") -}}
    {{- $existing | default (randAlphaNum 32) -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
JWT secret resolution, in the same order as the admin password. The API
refuses to start with a secret shorter than 32 characters or with the
placeholder of genesary/pupitre-helm (docs/specs/190-backend-defects.md B4 of
pupitre2), so the chart refuses to render them rather than ship a pod that
crash-loops. A release upgraded from genesary/pupitre-helm keeps that
placeholder in its Secret: it is replaced by a generated secret, not reused.
*/}}
{{- define "pupitre.refusedJwtSecret" -}}
{{- if or (eq . "change-me-in-production-use-a-long-random-string") (lt (len .) 32) -}}
true
{{- end -}}
{{- end }}

{{- define "pupitre.jwtSecret" -}}
{{- if .Values.jwtSecret -}}
  {{- if eq .Values.jwtSecret "change-me-in-production-use-a-long-random-string" -}}
    {{- fail "jwtSecret is the placeholder of genesary/pupitre-helm, which pupitre-api refuses: set a random secret of at least 32 characters, or leave jwtSecret empty to have one generated." -}}
  {{- end -}}
  {{- if lt (len .Values.jwtSecret) 32 -}}
    {{- fail "jwtSecret is shorter than 32 characters, which pupitre-api refuses: set a longer secret, or leave jwtSecret empty to have one generated." -}}
  {{- end -}}
  {{- .Values.jwtSecret -}}
{{- else -}}
  {{- $existing := include "pupitre.existingSecretValue" (dict "root" . "key" "JWT_SECRET") -}}
  {{- if and $existing (ne (include "pupitre.refusedJwtSecret" $existing) "true") -}}
    {{- $existing -}}
  {{- else -}}
    {{- randAlphaNum 64 -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Whether DATABASE_URL is supplied verbatim by a caller-managed Secret.
True only for an external database whose existingSecret exposes a full URL key.
*/}}
{{- define "pupitre.databaseUrlFromExternalSecret" -}}
{{- if and (not .Values.postgresql.enabled) .Values.database.auth.existingSecret .Values.database.auth.urlKey -}}
true
{{- end -}}
{{- end }}

{{/*
DATABASE_URL connection string, assembled from the `database` block.
Bundled PostgreSQL → in-cluster Service; otherwise → database.host/port.
*/}}
{{- define "pupitre.databaseUrl" -}}
{{- if .Values.postgresql.enabled -}}
postgres://{{ .Values.database.auth.username }}:{{ .Values.database.auth.password }}@{{ include "pupitre.fullname" . }}-postgresql.{{ .Release.Namespace }}.svc.{{ .Values.clusterDomain }}:5432/{{ .Values.database.name }}
{{- else -}}
postgres://{{ .Values.database.auth.username }}:{{ .Values.database.auth.password }}@{{ .Values.database.host }}:{{ .Values.database.port }}/{{ .Values.database.name }}
{{- end -}}
{{- end }}

{{/*
Name of the Secret that holds DATABASE_URL.
When the external database exposes its own URL Secret, point directly to it;
otherwise the chart renders DATABASE_URL into its own Secret.
*/}}
{{- define "pupitre.databaseUrlSecretName" -}}
{{- if eq (include "pupitre.databaseUrlFromExternalSecret" .) "true" -}}
{{ .Values.database.auth.existingSecret }}
{{- else -}}
{{ include "pupitre.fullname" . }}-secrets
{{- end -}}
{{- end }}

{{- define "pupitre.databaseUrlSecretKey" -}}
{{- if eq (include "pupitre.databaseUrlFromExternalSecret" .) "true" -}}
{{ .Values.database.auth.urlKey }}
{{- else -}}
DATABASE_URL
{{- end -}}
{{- end }}

{{/*
Name of the Secret that holds GIT_TOKEN.
*/}}
{{- define "pupitre.gitTokenSecretName" -}}
{{- if .Values.api.gitTokenExistingSecret -}}
{{ .Values.api.gitTokenExistingSecret }}
{{- else -}}
{{ include "pupitre.fullname" . }}-secrets
{{- end -}}
{{- end }}

{{- define "pupitre.gitTokenSecretKey" -}}
{{- if .Values.api.gitTokenExistingSecret -}}
{{ .Values.api.gitTokenExistingSecretKey }}
{{- else -}}
GIT_TOKEN
{{- end -}}
{{- end }}

{{/*
Whether GIT_TOKEN should be injected as an env var (true when a token is configured).
*/}}
{{- define "pupitre.gitTokenEnabled" -}}
{{- if or .Values.api.gitToken .Values.api.gitTokenExistingSecret -}}
true
{{- end -}}
{{- end }}

{{/*
Name of the Secret that holds JWT_SECRET.
*/}}
{{- define "pupitre.jwtSecretName" -}}
{{- if .Values.jwtExistingSecret -}}
{{ .Values.jwtExistingSecret }}
{{- else -}}
{{ include "pupitre.fullname" . }}-secrets
{{- end -}}
{{- end }}

{{- define "pupitre.jwtSecretKey" -}}
{{- if .Values.jwtExistingSecret -}}
{{ .Values.jwtExistingSecretKey }}
{{- else -}}
JWT_SECRET
{{- end -}}
{{- end }}

{{/*
Name of the PersistentVolumeClaim of the uploads.
*/}}
{{- define "pupitre.uploadsClaimName" -}}
{{- if .Values.api.uploads.persistence.existingClaim -}}
{{ .Values.api.uploads.persistence.existingClaim }}
{{- else -}}
{{ include "pupitre.fullname" . }}-uploads
{{- end -}}
{{- end }}

{{/*
The routing table, in one place.

Both the Ingress and the HTTPRoute render from this list, so the two cannot
drift apart.

genesary/pupitre-helm split /api between user-service and course-service by
prefix. pupitre-api serves every one of those routes, so /api is one prefix
again, with /uploads (the media), /metrics and /health. /metrics is routed
as in the reference (pupitre2 docs/specs/190-backend-defects.md B15, "Kept as
the reference"); Prometheus may also scrape the pod (prometheus.io/*).

Every rule is a plain prefix (or one exact path), which is Gateway API *Core*
conformance and the common denominator of every Ingress controller.
*/}}
{{- define "pupitre.routeTable" -}}
routes:
  # ── api ────────────────────────────────────────────────────────────────────
  - path: /api
    match: prefix
    service: api
  - path: /uploads
    match: prefix
    service: api
  - path: /metrics
    match: prefix
    service: api
  - path: /health
    match: exact
    service: api

  # ── frontend (catch-all) ───────────────────────────────────────────────────
  - path: /
    match: prefix
    service: frontend
{{- end }}

{{/*
Numeric Service port for a route's target, which HTTPRoute backendRefs
require (an Ingress may use the port name, a Gateway API route may not).
*/}}
{{- define "pupitre.routeServicePort" -}}
{{- $svc := .service -}}
{{- $root := .root -}}
{{- if eq $svc "api" -}}{{ $root.Values.api.service.port }}
{{- else -}}{{ $root.Values.frontend.service.port }}
{{- end -}}
{{- end }}

{{/*
Hostnames an HTTPRoute attaches to: httpRoute.hostnames when set, otherwise
the Ingress host, so a single-host deployment configures it in one place.
*/}}
{{- define "pupitre.httpRouteHostnames" -}}
{{- if .Values.httpRoute.hostnames -}}
{{ toYaml .Values.httpRoute.hostnames }}
{{- else if .Values.ingress.host -}}
- {{ .Values.ingress.host | quote }}
{{- end -}}
{{- end }}

{{/*
Public scheme (http or https).

TLS is terminated at the Ingress when `ingress.tls` is set, and at the Gateway
listener — which this chart does not own — when the HTTPRoute is used. The
latter is why `httpRoute.tls` exists: it tells the chart how to spell the
public URL it hands to CORS and the OAuth redirect base, nothing more.
*/}}
{{- define "pupitre.scheme" -}}
{{- if or .Values.ingress.tls .Values.httpRoute.tls }}https{{- else }}http{{- end }}
{{- end }}

{{/*
Public host of the app. The HTTPRoute's first hostname when it overrides the
Ingress host, otherwise the Ingress host.
*/}}
{{- define "pupitre.publicHost" -}}
{{- if and .Values.httpRoute.enabled .Values.httpRoute.hostnames -}}
{{ first .Values.httpRoute.hostnames }}
{{- else -}}
{{ .Values.ingress.host }}
{{- end -}}
{{- end }}

{{/*
Public base URL of the app (used for CORS and the OAuth redirect base)
*/}}
{{- define "pupitre.publicUrl" -}}
{{ include "pupitre.scheme" . }}://{{ include "pupitre.publicHost" . }}
{{- end }}

{{/*
Restrictive container security context. The API image runs as 1000:1000,
the frontend image (nginx-unprivileged) as 101:101.
Takes (dict "uid" <uid>).
*/}}
{{- define "pupitre.securityContext" -}}
runAsNonRoot: true
runAsUser: {{ .uid }}
runAsGroup: {{ .uid }}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
seccompProfile:
  type: RuntimeDefault
{{- end }}
