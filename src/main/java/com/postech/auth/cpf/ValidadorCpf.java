package com.postech.auth.cpf;
public final class ValidadorCpf {
 private ValidadorCpf() {}
 public static boolean ehValido(String cpf) { if(cpf==null)return false; String d=cpf.replaceAll("\\D",""); if(d.length()!=11||d.matches("(\\d)\\1{10}"))return false; int s=0; for(int i=0;i<9;i++)s+=(d.charAt(i)-'0')*(10-i); int r=s%11; int a=r<2?0:11-r; s=0; for(int i=0;i<10;i++)s+=(d.charAt(i)-'0')*(11-i); r=s%11; int b=r<2?0:11-r; return d.charAt(9)-'0'==a&&d.charAt(10)-'0'==b; }
}
