#!/usr/bin/env bash
set -Eeuo pipefail

for variable in OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS; do
  [[ -n "${!variable:-}" ]] || {
    echo "ERRO: variavel obrigatoria ausente: $variable" >&2
    exit 2
  }
done
for command in curl openssl python3; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "ERRO: comando obrigatorio ausente: $command" >&2
    exit 2
  }
done

endpoint="${OTEL_EXPORTER_OTLP_ENDPOINT%/}"
[[ "$endpoint" == */v1/traces ]] || endpoint="$endpoint/v1/traces"
trace_id="$(openssl rand -hex 16)"
span_id="$(openssl rand -hex 8)"
now_ns="$(python3 -c 'import time; print(time.time_ns())')"
end_ns="$((now_ns + 1000000))"
payload="$(mktemp)"
response="${payload}.response"
trap 'rm -f -- "$payload" "$response"' EXIT

cat >"$payload" <<JSON
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"workshop-w0-otlp-spike"}},{"key":"deployment.environment","value":{"stringValue":"prod"}}]},"scopeSpans":[{"scope":{"name":"w0-spike"},"spans":[{"traceId":"${trace_id}","spanId":"${span_id}","name":"otlp-ingestion-check","kind":1,"startTimeUnixNano":"${now_ns}","endTimeUnixNano":"${end_ns}","status":{"code":1}}]}]}]}
JSON

# Formato padrao OTel: "chave=valor,chave2=valor2". Os valores nao sao exibidos.
IFS=',' read -r -a raw_headers <<<"$OTEL_EXPORTER_OTLP_HEADERS"
curl_headers=()
for entry in "${raw_headers[@]}"; do
  key="${entry%%=*}"
  value="${entry#*=}"
  [[ -n "$key" && "$value" != "$entry" ]] || {
    echo "ERRO: OTEL_EXPORTER_OTLP_HEADERS deve usar chave=valor[,chave=valor]." >&2
    exit 2
  }
  curl_headers+=(--header "$key: $value")
done

echo "Enviando um trace OTLP/HTTP sem dados de negocio..."
if ! http_status="$(curl --silent --show-error \
  --output "$response" \
  --write-out '%{http_code}' \
  --header 'Content-Type: application/json' \
  "${curl_headers[@]}" \
  --request POST \
  --data-binary "@$payload" \
  "$endpoint")"; then
  http_status="000"
fi

if [[ "$http_status" != 2* ]]; then
  echo "VEREDITO: REPROVADO — o backend OTLP respondeu HTTP $http_status." >&2
  head -c 1000 "$response" >&2 || true
  echo >&2
  exit 1
fi

echo "VEREDITO: APROVADO — o backend OTLP aceitou o trace com HTTP $http_status."
echo "Trace ID para conferencia no backend: $trace_id"
echo "Service name: workshop-w0-otlp-spike"
