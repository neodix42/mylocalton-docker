package org.ton.mylocaltondocker;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.ton.java.tonlib.Tonlib;

@SpringBootApplication
public class Main {

  public static Tonlib tonlib;

  public static void main(String[] args) {
    System.out.println("staring spring boot");
    SpringApplication.run(Main.class, args);
  }
}
