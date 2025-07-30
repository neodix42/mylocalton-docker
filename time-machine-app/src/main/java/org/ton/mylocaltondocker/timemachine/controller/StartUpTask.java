package org.ton.mylocaltondocker.timemachine.controller;

import java.nio.file.Files;
import java.nio.file.Paths;

import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.ton.java.adnl.AdnlLiteClient;
import org.ton.mylocaltondocker.timemachine.Main;

@Component
@Slf4j
public class StartUpTask {

  @EventListener(ApplicationReadyEvent.class)
  public void onApplicationReady() throws InterruptedException {

    System.out.println("Initializing tonlib");

    while (!Files.exists(Paths.get("/usr/share/data/global.config.json"))) {
      System.out.println("time-machine-app is waiting for /usr/share/data/global.config.json");
      Thread.sleep(5000);
    }

    log.info("SERVER_PORT {}", System.getenv("SERVER_PORT"));

    try {

      Main.adnlLiteClient = getAdnlLiteClient();

      log.info(Main.adnlLiteClient.getMasterchainInfo().getLast().toString());

    } catch (Exception e) {
      log.error("can't get seqno " + e.getMessage());
    }

    log.info("time-machine-app ready");
  }

  public static AdnlLiteClient getAdnlLiteClient() throws Exception {
    return AdnlLiteClient.builder()
        .configPath("/usr/share/data/global.config.json")
        .queryTimeout(10)
        .build();
  }
}
