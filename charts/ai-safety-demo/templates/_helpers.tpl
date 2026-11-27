{{/*
Bucket used by the DSPA/garak pipeline. Falls back to the SeaweedFS bucket.
*/}}
{{- define "ai-safety-demo.bucket" -}}
{{- if .Values.dspa.objectStorage.bucket -}}
{{- .Values.dspa.objectStorage.bucket -}}
{{- else -}}
{{- .Values.seaweedfs.bucket -}}
{{- end -}}
{{- end -}}
