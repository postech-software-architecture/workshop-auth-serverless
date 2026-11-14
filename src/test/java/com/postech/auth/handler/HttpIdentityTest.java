package com.postech.auth.handler;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.util.*;
import com.postech.auth.repository.AutenticacaoRepository;
import com.postech.auth.token.EmissorJwt;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
class HttpIdentityTest {
    String identity="{\"id\":\"11111111-1111-4111-8111-111111111111\",\"username\":\"customer\",\"usuarioAtivo\":true,\"bloqueado\":false,\"usuarioRemovido\":false,\"clienteAtivo\":true,\"clienteRemovido\":false,\"roles\":[\"CLIENTE\"]}";
    int run(int status,String body)throws Exception{
        HttpServer server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        server.createContext("/internal/v1/identidade/por-cpf",exchange->{assertEquals("technical-test-key",exchange.getRequestHeaders().getFirst("X-Service-Token"));var bytes=body.getBytes(java.nio.charset.StandardCharsets.UTF_8);exchange.getResponseHeaders().set("Content-Type","application/json");exchange.sendResponseHeaders(status,bytes.length);exchange.getResponseBody().write(bytes);exchange.close();});server.start();
        try{var repository=new AutenticacaoRepository("http://127.0.0.1:"+server.getAddress().getPort(),"technical-test-key");var handler=new AuthHandler(repository,new EmissorJwt("01234567890123456789012345678901"));var event=new APIGatewayV2HTTPEvent();event.setBody("{\"cpf\":\"12345678909\"}");return handler.handleRequest(event,null).getStatusCode();}finally{server.stop(0);}
    }
    @Test void eligibleHttpIdentityProducesTokenWithoutDatabase()throws Exception{assertEquals(200,run(200,identity));}
    @Test void unknownIdentityDoesNotAuthenticate()throws Exception{assertEquals(401,run(404,"{}"));}
    @Test void blockedCurrentIdentityDoesNotAuthenticate()throws Exception{assertEquals(401,run(200,identity.replace("\"bloqueado\":false","\"bloqueado\":true")));}
    @Test void unavailableIdentityServiceReturns503()throws Exception{assertEquals(503,run(503,"{}"));}
    @Test void invalidResponseReturns503()throws Exception{assertEquals(503,run(200,"{}"));}
}
