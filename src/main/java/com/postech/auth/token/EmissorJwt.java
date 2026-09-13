package com.postech.auth.token;
import io.jsonwebtoken.Jwts; import io.jsonwebtoken.security.Keys; import javax.crypto.SecretKey; import java.nio.charset.StandardCharsets; import java.time.Instant; import java.util.*;
public final class EmissorJwt {
 public static final String ISSUER="workshop-auth", AUDIENCE="workshop-service"; private final SecretKey key; private final long validade;
 public EmissorJwt(String secret){this(secret,3600);}
 public EmissorJwt(String secret,long validadeSegundos){if(secret==null||secret.trim().getBytes(StandardCharsets.UTF_8).length<32)throw new IllegalArgumentException("JWT_SECRET deve possuir ao menos 32 bytes"); if(validadeSegundos<=0)throw new IllegalArgumentException("Validade invalida"); key=Keys.hmacShaKeyFor(secret.trim().getBytes(StandardCharsets.UTF_8)); validade=validadeSegundos;}
 public String emitir(String subject,String username,Collection<String> roles){Instant now=Instant.now(); return Jwts.builder().subject(Objects.requireNonNull(subject)).claim("username",username).claim("roles",roles==null?List.of():List.copyOf(roles)).issuer(ISSUER).audience().add(AUDIENCE).and().id(UUID.randomUUID().toString()).issuedAt(Date.from(now)).expiration(Date.from(now.plusSeconds(validade))).signWith(key, Jwts.SIG.HS256).compact();}
 public long getValidadeSegundos(){return validade;}
}
