package org.ton.mylocaltondocker.faucet;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.ton.ton4j.tonlib.Tonlib;

@SpringBootApplication
public class Main {

  public static Tonlib tonlib;

  public static void main(String[] args) {
    SpringApplication.run(Main.class, args);
  }
}
