package com.postech.auth.telemetry;

import org.junit.jupiter.api.Test;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class TelemetryTest {
    @Test
    void logIsJsonAndDoesNotExposeSensitiveFields() {
        PrintStream original = System.out;
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        System.setOut(new PrintStream(output, true, StandardCharsets.UTF_8));
        try {
            Telemetry.log("request", "w5-test", Map.of(
                    "operation", "authenticate_cpf",
                    "cpf", "12345678909",
                    "authorization", "Bearer jwt-value",
                    "password", "secret-value"));
        } finally {
            System.setOut(original);
        }
        String line = output.toString(StandardCharsets.UTF_8);
        assertTrue(line.startsWith("{\"service.name\":\"workshop-auth-serverless\""));
        assertTrue(line.contains("\"correlationId\":\"w5-test\""));
        assertTrue(line.contains("\"operation\":\"authenticate_cpf\""));
        assertFalse(line.contains("12345678909"));
        assertFalse(line.contains("jwt-value"));
        assertFalse(line.contains("secret-value"));
    }

}
