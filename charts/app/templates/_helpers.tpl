{{/*
Nome curto do app (app.name preenchido em apps/<app>/values.yaml).
Cai pra .Chart.Name caso o usuário não preencha.
*/}}
{{- define "app.name" -}}
{{- default .Chart.Name .Values.app.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fullname: usado como nome de Deployment/Service/Ingress.
Mantém .Release.Name implicitamente se o chamador passar .fullnameOverride.
*/}}
{{- define "app.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "app.name" . | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{- define "app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels (usado em metadata.labels).
*/}}
{{- define "app.labels" -}}
helm.sh/chart: {{ include "app.chart" . }}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Values.app.environment }}
app.kubernetes.io/environment: {{ .Values.app.environment | quote }}
{{- end }}
{{- end }}

{{/*
Selector labels (precisa ser estável – não muda entre releases).
*/}}
{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Renderiza .Values.env (map) como lista de {name, value}.
Aplica tpl em cada value para suportar {{ .Values.app.environment }} etc.
*/}}
{{- define "app.envVars" -}}
{{- range $k, $v := .Values.env }}
- name: {{ $k }}
  value: {{ tpl (printf "%v" $v) $ | quote }}
{{- end }}
{{- end }}

{{/*
Host do Ingress. Usa .Values.ingress.host se definido; senão deriva
<env>.<app>.<project>.local (mesma regra do scripts/lib-project.sh, que
registra esses hosts no /etc/hosts).
*/}}
{{- define "app.ingressHost" -}}
{{- if .Values.ingress.host -}}
{{- .Values.ingress.host -}}
{{- else if and .Values.app.project .Values.app.environment -}}
{{- printf "%s.%s.%s.local" .Values.app.environment (include "app.name" .) .Values.app.project -}}
{{- end -}}
{{- end }}
