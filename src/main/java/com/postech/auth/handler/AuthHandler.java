package com.postech.auth.handler;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.postech.auth.cpf.Documento;
import com.postech.auth.repository.AutenticacaoRepository;
import com.postech.auth.telemetry.Telemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.context.Scope;
import com.postech.auth.token.EmissorJwt;

import java.sql.SQLException;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

public final class AuthHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {
    private static final ObjectMapper JSON = new ObjectMapper();
    private final AutenticacaoRepository repository;
    private final EmissorJwt emissor;

    public AuthHandler() { this(new AutenticacaoRepository(), new EmissorJwt(System.getenv("JWT_SECRET"))); }
    AuthHandler(AutenticacaoRepository repository, EmissorJwt emissor) { this.repository = repository; this.emissor = emissor; }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        APIGatewayV2HTTPEvent.RequestContext requestContext = event.getRequestContext();
        APIGatewayV2HTTPEvent.RequestContext.Http http = requestContext == null ? null : requestContext.getHttp();
        String method = http == null ? null : http.getMethod();
        String route = requestContext == null ? null : requestContext.getRouteKey();
        String spanName = method != null && route != null ? method + " " + route
                : context == null ? Telemetry.SERVICE_NAME : context.getFunctionName();
        Span span = Telemetry.startInvocation(spanName, event.getHeaders(), correlation(event),
                context == null ? null : context.getAwsRequestId(), method, route);
        try (Scope scope = Telemetry.activate(span)) {
            APIGatewayV2HTTPResponse response = authenticate(event, context);
            Telemetry.endInvocation(span, response.getStatusCode());
            return response;
        }
        catch (RuntimeException | Error failure) {
            Telemetry.failInvocation(span, failure);
            throw failure;
        }
    }

    private APIGatewayV2HTTPResponse authenticate(APIGatewayV2HTTPEvent event, Context context) {
        String correlationId = correlation(event);
        Telemetry.log("request", correlationId, Map.of("operation", "authenticate_cpf"));
        Telemetry.cpfAttempt("received");
        try {
            Map<String, Object> body = JSON.readValue(Optional.ofNullable(event.getBody()).orElse(""), new TypeReference<>() {});
            Object rawCpf = body.get("cpf");
            if (!(rawCpf instanceof String cpf) || !cpf.matches("[0-9.\\- ]+")) {
                Telemetry.cpfFailure("invalid_format"); return response(422, "CPF invalido", correlationId);
            }
            Documento documento;
            try { documento = new Documento(cpf); }
            catch (IllegalArgumentException invalidCpf) {
                Telemetry.cpfFailure("invalid_document"); return response(422, "CPF invalido", correlationId);
            }
            var found = repository.buscarPorCpf(documento.getValor());
            if (found.isEmpty() || !found.get().elegivel()) {
                Telemetry.cpfFailure("not_eligible"); return response(401, "Nao foi possivel autenticar", correlationId);
            }
            var user = found.get();
            String token = emissor.emitir(user.id().toString(), user.username(), user.roles());
            Telemetry.log("authentication_success", correlationId, Map.of("operation", "authenticate_cpf", "outcome", "success"));
            return jsonResponse(200, Map.of("accessToken", token, "tokenType", "Bearer", "expiresIn", emissor.getValidadeSegundos()), correlationId);
        } catch (SQLException databaseFailure) {
            Telemetry.cpfFailure("database"); Telemetry.databaseError();
            Telemetry.log("database_error", correlationId, Map.of("operation", "authenticate_cpf", "outcome", "unavailable"));
            return response(503, "Servico temporariamente indisponivel", correlationId);
        } catch (Exception invalidRequest) {
            Telemetry.cpfFailure("error");
            Telemetry.log("request_error", correlationId, Map.of("operation", "authenticate_cpf", "outcome", "invalid_request"));
            return response(500, "Erro interno", correlationId);
        }
    }

    private static String correlation(APIGatewayV2HTTPEvent event) {
        String id = null;
        if (event != null && event.getHeaders() != null) for (var header : event.getHeaders().entrySet()) {
            if (header.getKey().equalsIgnoreCase("X-Correlation-ID")) { id = header.getValue(); break; }
        }
        if (id == null || id.isBlank()) return UUID.randomUUID().toString();
        String sanitized = id.replaceAll("[^A-Za-z0-9._-]", "");
        return sanitized.isBlank() ? UUID.randomUUID().toString() : sanitized.substring(0, Math.min(64, sanitized.length()));
    }

    private static APIGatewayV2HTTPResponse response(int status, String message, String correlationId) {
        try { return jsonResponse(status, Map.of("message", message), correlationId); }
        catch (Exception ignored) {
            return APIGatewayV2HTTPResponse.builder().withStatusCode(status)
                    .withHeaders(Map.of("Content-Type", "application/json", "X-Correlation-ID", correlationId))
                    .withBody("{\"message\":\"Erro interno\"}").build();
        }
    }

    static APIGatewayV2HTTPResponse jsonResponse(int status, Map<String, Object> body, String correlationId) throws Exception {
        return APIGatewayV2HTTPResponse.builder().withStatusCode(status)
                .withHeaders(Map.of("Content-Type", "application/json", "X-Correlation-ID", correlationId))
                .withBody(JSON.writeValueAsString(body)).build();
    }
}
