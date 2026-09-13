package com.postech.auth.handler;
import static org.junit.jupiter.api.Assertions.*;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.postech.auth.token.EmissorJwt;
import org.junit.jupiter.api.Test;
class AuthHandlerTest {
 @Test void cpfInvalidoNaoConsultaBanco(){var e=new APIGatewayV2HTTPEvent();e.setBody("{\"cpf\":\"11111111111\"}");var response=new AuthHandler(null,new EmissorJwt("12345678901234567890123456789012")).handleRequest(e,null);assertEquals(422,response.getStatusCode());}
 @Test void correlationIdEhPropagated(){var e=new APIGatewayV2HTTPEvent();e.setBody("{\"cpf\":\"11111111111\"}");e.setHeaders(java.util.Map.of("X-Correlation-ID","corr-1"));assertEquals("corr-1",new AuthHandler(null,new EmissorJwt("12345678901234567890123456789012")).handleRequest(e,null).getHeaders().get("X-Correlation-ID"));}
 @Test void respostaDeSucessoEhJsonValido()throws Exception{var response=AuthHandler.jsonResponse(200,java.util.Map.of("accessToken","token","tokenType","Bearer","expiresIn",3600),"corr-1");var body=new ObjectMapper().readTree(response.getBody());assertEquals("token",body.get("accessToken").asText());assertEquals("Bearer",body.get("tokenType").asText());assertEquals(3600,body.get("expiresIn").asInt());}
}
