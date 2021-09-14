{{- define "app_envs" }}
- name: MY_POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: APP_AGENT_LABEL
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: APP_CONFIG
  value: {{ pluck .Values.werf.env .Values.app.config | first | default .Values.app.config._default }}
- name: APP_AUTHN_ENABLED
  value: {{ pluck .Values.werf.env .Values.app.authn_enabled | first | default .Values.app.authn_enabled._default }}
- name: APP_AUTHZ_ENABLED
  value: {{ pluck .Values.werf.env .Values.app.authz_enabled | first | default .Values.app.authz_enabled._default }}
- name: APP_DYNSUB_ENABLED
  value: {{ pluck .Values.werf.env .Values.app.dynsub_enabled | first | default .Values.app.dynsub_enabled._default }}
- name: APP_STAT_ENABLED
  value: {{ pluck .Values.werf.env .Values.app.stat_enabled | first | default .Values.app.stat_enabled._default }}
- name: APP_RATE_LIMIT_ENABLED
  value: {{ pluck .Values.werf.env .Values.app.rate_limit_enabled | first | default .Values.app.rate_limit_enabled._default }}
- name: DOCKER_VERNEMQ_DISCOVERY_KUBERNETES
  value: {{ pluck .Values.werf.env .Values.app.docker_vernemq_discovery_kubernetes | first | default .Values.app.docker_vernemq_discovery_kubernetes._default }}
- name: DOCKER_VERNEMQ_KUBERNETES_LABEL_SELECTOR
  value: {{ .Chart.Name }}
- name: DOCKER_VERNEMQ_DISTRIBUTED_COOKIE
  value: {{ pluck .Values.werf.env .Values.app.docker_vernemq_distributed_cookie | first | default .Values.app.docker_vernemq_distributed_cookie._default }}
{{- end }}
