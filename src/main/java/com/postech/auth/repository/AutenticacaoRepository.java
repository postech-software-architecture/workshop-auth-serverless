package com.postech.auth.repository;
import java.sql.*; import java.util.*;
public final class AutenticacaoRepository {
 private static final String SQL="SELECT u.id,u.username,u.ativo usuario_ativo,u.bloqueado,u.data_remocao usuario_removido,c.ativo cliente_ativo,c.data_remocao cliente_removido,array_agg(ur.role) roles FROM clientes c JOIN usuarios u ON u.cliente_id=c.id JOIN usuarios_roles ur ON ur.usuario_id=u.id WHERE c.documento=? GROUP BY u.id,c.id";
 private final String url,user,password; private Connection connection;
 public AutenticacaoRepository(){this(System.getenv("DB_URL"),System.getenv("DB_USER"),System.getenv("DB_PASSWORD"));}
 public AutenticacaoRepository(String url,String user,String password){this.url=url;this.user=user;this.password=password;}
 public Optional<Identidade> buscarPorCpf(String cpf)throws SQLException{try(PreparedStatement p=conexao().prepareStatement(SQL)){p.setString(1,cpf);try(ResultSet r=p.executeQuery()){if(!r.next())return Optional.empty();Set<String> roles=new LinkedHashSet<>();Array a=r.getArray("roles");if(a!=null)for(Object x:(Object[])a.getArray())roles.add(String.valueOf(x));return Optional.of(new Identidade(UUID.fromString(r.getString("id")),r.getString("username"),r.getBoolean("usuario_ativo"),r.getBoolean("bloqueado"),r.getTimestamp("usuario_removido")!=null,r.getBoolean("cliente_ativo"),r.getTimestamp("cliente_removido")!=null,roles));}}}
 private Connection conexao()throws SQLException{if(connection==null||connection.isClosed()){if(url==null||user==null||password==null)throw new SQLException("Banco nao configurado");connection=DriverManager.getConnection(url,user,password);}return connection;}
 public record Identidade(UUID id,String username,boolean usuarioAtivo,boolean bloqueado,boolean usuarioRemovido,boolean clienteAtivo,boolean clienteRemovido,Set<String> roles){public boolean elegivel(){return usuarioAtivo&&!bloqueado&&!usuarioRemovido&&clienteAtivo&&!clienteRemovido&&roles.contains("CLIENTE");}}
}
