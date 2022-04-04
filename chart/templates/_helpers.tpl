{{/*
Expand the name of the chart.
*/}}
{{- define "mqtt-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Service name.
*/}}
{{- define "mqtt-gateway.serviceName" -}}
{{- list (default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-") "loadbalancer-internal" | join "-" }}
{{- end }}


{{/*
Short namespace.
*/}}
{{- define "mqtt-gateway.shortNamespace" -}}
{{- $shortns := regexSplit "-" .Release.Namespace -1 | first }}
{{- if has $shortns (list "production" "p") }}
{{- else }}
{{- $shortns }}
{{- end }}
{{- end }}

{{/*
Namespace in ingress path.
converts as follows:
- testing01 -> t01
- staging01-classroom-ng -> s01/classroom-ng
- producion-webinar-ng -> webinar-ng
*/}}
{{- define "mqtt-gateway.ingressPathNamespace" -}}
{{- $ns_head := regexSplit "-" .Release.Namespace -1 | first }}
{{- $ns_tail := regexSplit "-" .Release.Namespace -1 | rest | join "-" }}
{{- if eq $ns_head "production" }}
{{- $ns_tail }}
{{- else }}
{{- list (regexReplaceAll "(.)[^\\d]*(.+)" $ns_head "${1}${2}") $ns_tail | compact | join "/" }}
{{- end }}
{{- end }}

{{/*
Ingress path.
*/}}
{{- define "mqtt-gateway.ingressPath" -}}
{{- $shortns := regexSplit "-" .Release.Namespace -1 | first }}
{{- list "" (include "mqtt-gateway.ingressPathNamespace" .) (include "mqtt-gateway.name" .) | join "/" }}
{{- end }}

{{/*
Ingress host with dev prefix if its a non production ns
*/}}
{{- define "mqtt-gateway.ingressHost" -}}
{{- $shortns := regexSplit "-" .Release.Namespace -1 | first }}
{{- if eq $shortns "production" }}
{{- .Values.ingress.base_host }}
{{- else }}
{{- list .Values.ingress.dev_prefix .Values.ingress.base_host | join "." }}
{{- end }}
{{- end }}


{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "mqtt-gateway.fullname" -}}
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
{{- define "mqtt-gateway.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mqtt-gateway.labels" -}}
helm.sh/chart: {{ include "mqtt-gateway.chart" . }}
app.kubernetes.io/name: {{ include "mqtt-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
k8s-app: {{ include "mqtt-gateway.name" . }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mqtt-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mqtt-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: {{ include "mqtt-gateway.name" . }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "mqtt-gateway.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mqtt-gateway.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
