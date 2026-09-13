package com.postech.auth.cpf;
import java.util.Objects;
public final class Documento {
 private final String valor;
 private final TipoDocumento tipo;
 public Documento(String original) { if (original == null) throw new IllegalArgumentException("Documento nao pode ser nulo"); String d=original.replaceAll("\\D",""); if(!ValidadorCpf.ehValido(d)) throw new IllegalArgumentException("CPF invalido"); valor=d; tipo=TipoDocumento.CPF; }
 public String getValor(){return valor;} public TipoDocumento getTipo(){return tipo;}
 public String mascarado(){return "***."+valor.substring(3,6)+"."+valor.substring(6,9)+"-**";}
 @Override public boolean equals(Object o){return o instanceof Documento d && valor.equals(d.valor);} @Override public int hashCode(){return Objects.hash(valor);}
}
