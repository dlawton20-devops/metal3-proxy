{{/*
Expand the name of the chart.
*/}}
{{- define "metal3-ironic.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "metal3-ironic.fullname" -}}
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
Common labels
*/}}
{{- define "metal3-ironic.labels" -}}
helm.sh/chart: {{ include "metal3-ironic.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{/*
Envoy component labels
*/}}
{{- define "metal3-ironic.envoy.labels" -}}
{{ include "metal3-ironic.labels" . }}
app.kubernetes.io/name: envoy-proxy
app.kubernetes.io/component: forward-proxy
{{- end }}

{{/*
Envoy selector labels
*/}}
{{- define "metal3-ironic.envoy.selectorLabels" -}}
app.kubernetes.io/name: envoy-proxy
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
The in-cluster DNS name of the Envoy proxy service.
Used when configuring the SUSE Edge Metal3 chart's ironicExtraEnv.
*/}}
{{- define "metal3-ironic.envoy.serviceName" -}}
{{ include "metal3-ironic.fullname" . }}-envoy
{{- end }}

{{/*
Envoy proxy URL for Ironic to use (printed in NOTES.txt).
*/}}
{{- define "metal3-ironic.envoy.proxyUrl" -}}
http://{{ include "metal3-ironic.envoy.serviceName" . }}.{{ .Release.Namespace }}.svc:{{ .Values.envoy.service.port }}
{{- end }}
