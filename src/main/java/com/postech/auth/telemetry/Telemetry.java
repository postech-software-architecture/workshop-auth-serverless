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
    private static final LongCounter CPF_ATTEMPTS = counter(CPF_ATTEMPT, "CPF authentication attempts");
    private static final LongCounter CPF_FAILURES = counter(CPF_FAILURE, "CPF authentication failures");
    private static final LongCounter DATABASE_ERRORS = counter(DATABASE_ERROR, "Database errors during authentication");

    private Telemetry() {
    }

    private static LongCounter counter(String name, String description) {
        return METER.counterBuilder(name).setDescription(description).setUnit("{request}").build();
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
