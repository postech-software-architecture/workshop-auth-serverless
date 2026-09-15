package com.postech.auth.telemetry;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.common.AttributeKey;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.Meter;
import io.opentelemetry.api.logs.Logger;
import io.opentelemetry.api.logs.Severity;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;
import io.opentelemetry.context.propagation.TextMapGetter;

import java.util.LinkedHashMap;
import java.util.Map;

/** Lambda telemetry facade. The ADOT/New Relic runtime supplies the SDK at deploy time. */
public final class Telemetry {
    public static final String SERVICE_NAME = "workshop-auth-serverless";
    public static final String ENVIRONMENT = "prod";
    public static final String CPF_ATTEMPT = "workshop.auth.cpf.attempt.count";
    public static final String CPF_FAILURE = "workshop.auth.cpf.failure.count";
    public static final String DATABASE_ERROR = "workshop.auth.database.error.count";

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final AttributeKey<String> OUTCOME = AttributeKey.stringKey("outcome");
    private static final AttributeKey<String> OPERATION = AttributeKey.stringKey("operation");
    private static final Meter METER = GlobalOpenTelemetry.getMeter(SERVICE_NAME);
    private static final Logger LOGGER = GlobalOpenTelemetry.get().getLogsBridge()
            .loggerBuilder(SERVICE_NAME)
            .build();
    private static final Tracer TRACER = GlobalOpenTelemetry.getTracer(SERVICE_NAME);
    private static final AttributeKey<String> FAAS_INVOCATION_ID = AttributeKey.stringKey("faas.invocation_id");
    private static final AttributeKey<String> FAAS_TRIGGER = AttributeKey.stringKey("faas.trigger");
    private static final AttributeKey<String> HTTP_METHOD = AttributeKey.stringKey("http.request.method");
    private static final AttributeKey<String> HTTP_ROUTE = AttributeKey.stringKey("http.route");
    private static final AttributeKey<Long> HTTP_STATUS = AttributeKey.longKey("http.response.status_code");
    private static final AttributeKey<String> CORRELATION_ID = AttributeKey.stringKey("correlationId");

    /** Lookup case-insensitive: o propagador pede a chave em minusculas e o API Gateway varia o casing. */
    private static final TextMapGetter<Map<String, String>> HEADER_GETTER = new TextMapGetter<>() {
        @Override
        public Iterable<String> keys(Map<String, String> carrier) {
            return carrier.keySet();
        }

        @Override
        public String get(Map<String, String> carrier, String key) {
            if (carrier == null) {
                return null;
            }
            for (Map.Entry<String, String> entry : carrier.entrySet()) {
                if (entry.getKey() != null && entry.getKey().equalsIgnoreCase(key)) {
                    return entry.getValue();
                }
            }
            return null;
        }
    };
    private static final LongCounter CPF_ATTEMPTS = counter(CPF_ATTEMPT, "CPF authentication attempts");
    private static final LongCounter CPF_FAILURES = counter(CPF_FAILURE, "CPF authentication failures");
    private static final LongCounter DATABASE_ERRORS = counter(DATABASE_ERROR, "Database errors during authentication");

    private Telemetry() {
    }

    private static LongCounter counter(String name, String description) {
        return METER.counterBuilder(name).setDescription(description).setUnit("{request}").build();
    }

    /**
     * Abre o span raiz da invocacao. A camada ADOT instrumenta handlers cujo evento ela
     * reconhece, o que nao acontece com APIGatewayV2HTTPEvent nesta versao: as metricas e
     * os logs chegavam normalmente e nenhum span era produzido. Criar o span aqui mantem a
     * fachada como unico ponto de telemetria e permite herdar o traceparent do cabecalho,
     * que e o que liga a Lambda a aplicacao pelo mesmo trace.
     */
    public static Span startInvocation(String spanName, Map<String, String> headers,
            String correlationId, String invocationId, String method, String route) {
        Context parent = GlobalOpenTelemetry.get().getPropagators().getTextMapPropagator()
                .extract(Context.root(), headers == null ? Map.of() : headers, HEADER_GETTER);
        return TRACER.spanBuilder(spanName)
                .setParent(parent)
                .setSpanKind(SpanKind.SERVER)
                .setAttribute(FAAS_INVOCATION_ID, safeTag(invocationId))
                .setAttribute(FAAS_TRIGGER, "http")
                .setAttribute(HTTP_METHOD, safeTag(method))
                .setAttribute(HTTP_ROUTE, safeTag(route))
                .setAttribute(CORRELATION_ID, safeTag(correlationId))
                .startSpan();
    }

    public static Scope activate(Span span) {
        return span.makeCurrent();
    }

    public static void endInvocation(Span span, int status) {
        span.setAttribute(HTTP_STATUS, status);
        if (status >= 500) {
            span.setStatus(StatusCode.ERROR);
        }
        span.end();
    }

    public static void failInvocation(Span span, Throwable error) {
        span.setStatus(StatusCode.ERROR, error.getMessage() == null ? "" : error.getMessage());
        span.recordException(error);
        span.end();
    }

    public static void cpfAttempt(String outcome) {
        CPF_ATTEMPTS.add(1, Attributes.of(OUTCOME, safeTag(outcome)));
    }

    public static void cpfFailure(String outcome) {
        CPF_FAILURES.add(1, Attributes.of(OUTCOME, safeTag(outcome)));
    }

    public static void databaseError() {
        DATABASE_ERRORS.add(1, Attributes.of(OPERATION, "authenticate_cpf"));
    }

    public static void log(String event, String correlationId, Map<String, ?> fields) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("service.name", SERVICE_NAME);
        payload.put("deployment.environment", ENVIRONMENT);
        payload.put("event", safeTag(event));
        payload.put("correlationId", safeTag(correlationId));
        SpanContext context = Span.current().getSpanContext();
        if (context.isValid()) {
            payload.put("trace.id", context.getTraceId());
            payload.put("span.id", context.getSpanId());
        }
        if (fields != null) {
            fields.forEach((key, value) -> {
                if (!isSensitiveKey(key)) {
                    payload.put(safeTag(key), safeField(value));
                }
            });
        }
        try {
            String body = JSON.writeValueAsString(payload);
            // Keep the structured CloudWatch copy and explicitly emit an OTLP LogRecord.
            // The collector's OTLP receiver does not consume System.out by itself.
            System.out.println(body);
            LOGGER.logRecordBuilder()
                    .setSeverity(Severity.INFO)
                    .setBody(body)
                    .setAttribute(AttributeKey.stringKey("event.name"), safeTag(event))
                    .setAttribute(AttributeKey.stringKey("correlation.id"), safeTag(correlationId))
                    .emit();
        } catch (JsonProcessingException ignored) {
            System.out.println("{\"service.name\":\"" + SERVICE_NAME + "\",\"event\":\"log_error\"}");
        }
    }

    private static boolean isSensitiveKey(String key) {
        String normalized = key == null ? "" : key.toLowerCase();
        return normalized.contains("cpf") || normalized.contains("jwt") || normalized.contains("token")
                || normalized.contains("password") || normalized.contains("secret") || normalized.contains("authorization");
    }

    private static String safeTag(String value) {
        if (value == null || value.isBlank()) {
            return "unknown";
        }
        String sanitized = value.replaceAll("[^A-Za-z0-9._-]", "_");
        return sanitized.substring(0, Math.min(64, sanitized.length()));
    }

    private static Object safeField(Object value) {
        if (value == null || value instanceof Number || value instanceof Boolean) {
            return value;
        }
        return safeTag(String.valueOf(value));
    }
}
