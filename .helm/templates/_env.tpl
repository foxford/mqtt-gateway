{{- define "app_envs" }}
- name: MY_POD_NAME
  value: {{ .Chart.Name }}
- name: APP_AGENT_LABEL
  value: {{ .Chart.Name }}
- name: APP_CONFIG
  value: {{ .Values.app.config }}
- name: APP_AUTHN_ENABLED
  value: {{ .Values.app.authn_enabled }}
- name: APP_AUTHZ_ENABLED
  value: {{ .Values.app.authz_enabled }}
- name: APP_DYNSUB_ENABLED
  value: {{ .Values.app.dynsub_enabled }}
- name: APP_STAT_ENABLED
  value: {{ .Values.app.stat_enabled }}
- name: APP_RATE_LIMIT_ENABLED
  value: {{ .Values.app.rate_limit_enabled }}
- name: DOCKER_VERNEMQ_DISCOVERY_KUBERNETES
  value: {{ .Values.app.docker_vernemq_discovery_kubernetes }}
- name: DOCKER_VERNEMQ_KUBERNETES_LABEL_SELECTOR
  value: {{ .Chart.Name }}
- name: DOCKER_VERNEMQ_DISTRIBUTED_COOKIE
  value: 
{{- end }}
