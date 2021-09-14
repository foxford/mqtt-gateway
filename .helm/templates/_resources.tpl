{{- define "init_app_resources" }}
resources:
  requests:
    cpu: {{ pluck .Values.werf.env (index .Values.app.init_resources.cpu .Values.global.org .Values.global.app) | first | default (index .Values.app.init_resources.cpu .Values.global.org .Values.global.app)._default }}
    memory: {{ pluck .Values.werf.env (index .Values.app.init_resources.memory .Values.global.org .Values.global.app) | first | default (index .Values.app.init_resources.memory .Values.global.org .Values.global.app)._default }}
  limits:
    memory: {{ pluck .Values.werf.env (index .Values.app.init_resources.memory .Values.global.org .Values.global.app) | first | default (index .Values.app.init_resources.memory .Values.global.org .Values.global.app)._default }}
{{- end }}
{{- define "app_resources" }}
resources:
  requests:
    cpu: {{ pluck .Values.werf.env (index .Values.app.resources.cpu .Values.global.org .Values.global.app) | first | default (index .Values.app.resources.cpu .Values.global.org .Values.global.app)._default }}
    memory: {{ pluck .Values.werf.env (index .Values.app.resources.memory .Values.global.org .Values.global.app) | first | default (index .Values.app.resources.memory .Values.global.org .Values.global.app)._default }}
  limits:
    memory: {{ pluck .Values.werf.env (index .Values.app.resources.memory .Values.global.org .Values.global.app) | first | default (index .Values.app.resources.memory .Values.global.org .Values.global.app)._default }}
{{- end }}
