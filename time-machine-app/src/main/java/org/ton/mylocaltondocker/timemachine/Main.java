package org.ton.mylocaltondocker.timemachine;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.ton.java.tonlib.Tonlib;

@SpringBootApplication
public class Main {

  public static Tonlib tonlib;
  public static void main(String[] args) {
    SpringApplication.run(Main.class, args);
  }
}
