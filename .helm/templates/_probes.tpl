{{- define "app_probes" }}
livenessProbe:
  tcpSocket:
    port: https-standart
  initialDelaySeconds: 5
  periodSeconds: 10
readinessProbe:
  tcpSocket:
    port: https-standart
  initialDelaySeconds: 15
  periodSeconds: 20
{{- end }}
