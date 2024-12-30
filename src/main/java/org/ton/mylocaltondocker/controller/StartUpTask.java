package org.ton.mylocaltondocker.controller;

import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.ton.java.tonlib.Tonlib;
import org.ton.mylocaltondocker.Main;

import java.net.URI;
import java.net.URISyntaxException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

@Component
public class StartUpTask {

  @EventListener(ApplicationReadyEvent.class)
  public void onApplicationReady() throws InterruptedException {
    System.out.println("Web Faucet has started. Sleep 30 seconds till blockchain is ready...");
    Thread.sleep(30 * 1000);
    System.out.println("Initializing tonlib");

    while (!Files.exists(Paths.get("/var/ton-work/db/global.config.json"))) {
      System.out.println("faucet is waiting for /var/ton-work/db/global.config.json");
      Thread.sleep(5000);
    }

    Main.tonlib =
        Tonlib.builder()
            .pathToTonlibSharedLib("/usr/share/data/libtonlibjson.so")
            .pathToGlobalConfig("/var/ton-work/db/global.config.json")
            .ignoreCache(false)
            .build();

  }
}
