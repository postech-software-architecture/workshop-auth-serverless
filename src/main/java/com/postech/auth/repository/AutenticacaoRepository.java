package com.postech.auth.repository;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import java.net.http.*;
import java.time.Duration;
import java.sql.SQLException;
import java.util.*;
/** Compatibility port for the existing Lambda. No JDBC connection or database credentials. */
public final class AutenticacaoRepository {
    private final String url,token;private final HttpClient http;private final ObjectMapper json=new ObjectMapper();
    public AutenticacaoRepository(){this(System.getenv("IDENTITY_URL"),System.getenv("AUTH_SERVICE_TOKEN"));}
    public AutenticacaoRepository(String url,String token){this.url=url;this.token=token;this.http=HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).followRedirects(HttpClient.Redirect.NEVER).build();}
    public Optional<Identidade> buscarPorCpf(String cpf)throws SQLException{
        if(url==null || token==null || token.isBlank())throw new SQLException("Identidade nao configurada");
        try{
            var request=HttpRequest.newBuilder(URI.create(url+"/internal/v1/identidade/por-cpf")).timeout(Duration.ofSeconds(5)).header("Content-Type","application/json").header("X-Service-Token",token).POST(HttpRequest.BodyPublishers.ofString(json.writeValueAsString(Map.of("cpf",cpf)))).build();
            var response=http.send(request,HttpResponse.BodyHandlers.ofString());
            if(response.statusCode()==404)return Optional.empty();
            if(response.statusCode()!=200)throw new SQLException("Servico de identidade indisponivel");
            Identidade identity=json.readValue(response.body(),Identidade.class);
            if(identity.id()==null || identity.username()==null || identity.roles()==null)throw new SQLException("Resposta de identidade invalida");
            return Optional.of(identity);
        }catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new SQLException("Identidade interrompida",interrupted);}
        catch(java.io.IOException | IllegalArgumentException invalid){throw new SQLException("Falha no servico de identidade",invalid);}
    }
    public record Identidade(UUID id,String username,boolean usuarioAtivo,boolean bloqueado,boolean usuarioRemovido,boolean clienteAtivo,boolean clienteRemovido,Set<String> roles){
        public Identidade{if(roles!=null)roles=Set.copyOf(roles);}
        public boolean elegivel(){return id!=null && usuarioAtivo && !bloqueado && !usuarioRemovido && clienteAtivo && !clienteRemovido && roles!=null && roles.contains("CLIENTE");}
    }
}
