package org.ton.mylocaltondocker.timemachine;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.ton.java.adnl.AdnlLiteClient;

@SpringBootApplication
public class Main {

  public static AdnlLiteClient adnlLiteClient;
  public static void main(String[] args) {
    SpringApplication.run(Main.class, args);
  }
}
