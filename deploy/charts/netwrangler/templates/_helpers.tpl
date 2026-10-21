{{/*
Expand the name of the chart.
*/}}
{{- define "netwrangler.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "netwrangler.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "netwrangler.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "netwrangler.labels" -}}
helm.sh/chart: {{ include "netwrangler.chart" . }}
{{ include "netwrangler.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "netwrangler.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netwrangler.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Agent selector labels
*/}}
{{- define "netwrangler.agentSelectorLabels" -}}
app.kubernetes.io/name: {{ include "netwrangler.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: agent
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "netwrangler.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "netwrangler.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the agent's service account to use
*/}}
{{- define "netwrangler.agentServiceAccountName" -}}
{{- if .Values.agent.serviceAccount.create }}
{{- default (printf "%s-agent" (include "netwrangler.fullname" .)) .Values.agent.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.agent.serviceAccount.name }}
{{- end }}
{{- end }}
