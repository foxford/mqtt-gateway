{{- define "init_app_resources" }}
resources:
  requests:
    cpu: {{ pluck .Values.werf.env .Values.app.init_resources.requests.cpu | first | default .Values.app.init_resources.requests.cpu._default }}
    memory: {{ pluck .Values.werf.env .Values.app.init_resources.requests.memory | first | default .Values.app.init_resources.requests.memory._default }}
  limits:
    memory: {{ pluck .Values.werf.env .Values.app.init_resources.limits.memory | first | default .Values.app.init_resources.limits.memory._default }}
{{- end }}
{{- define "app_resources" }}
resources:
  requests:
    cpu: {{ pluck .Values.werf.env .Values.app.resources.requests.cpu | first | default .Values.app.resources.requests.cpu._default }}
    memory: {{ pluck .Values.werf.env .Values.app.resources.requests.memory | first | default .Values.app.resources.requests.memory._default }}
  limits:
    memory: {{ pluck .Values.werf.env .Values.app.resources.limits.memory | first | default .Values.app.resources.limits.memory._default }}
{{- end }}
