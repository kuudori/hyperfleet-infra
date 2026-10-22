{{/*
Expand the name of the chart.
*/}}
{{- define "hyperfleet-e2e.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by chart label.
*/}}
{{- define "hyperfleet-e2e.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "hyperfleet-e2e.labels" -}}
helm.sh/chart: {{ include "hyperfleet-e2e.chart" . }}
{{ include "hyperfleet-e2e.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "hyperfleet-e2e.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hyperfleet-e2e.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
