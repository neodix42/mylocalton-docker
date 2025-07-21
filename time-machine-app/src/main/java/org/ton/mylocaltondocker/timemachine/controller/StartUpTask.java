package org.ton.mylocaltondocker.timemachine.controller;

import java.nio.file.Files;
import java.nio.file.Paths;

import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.ton.java.tonlib.Tonlib;
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

          Main.tonlib =
              Tonlib.builder()
                  .pathToTonlibSharedLib("/usr/share/data/libtonlibjson.so")
                  .pathToGlobalConfig("/usr/share/data/global.config.json")
                  .ignoreCache(false)
                  .receiveRetryTimes(10)
                  .build();

          log.info(Main.tonlib.getLast().toString());

        } catch (Exception e) {
          log.error("can't get seqno " + e.getMessage());
        }

    log.info("time-machine-app ready");
  }
}
