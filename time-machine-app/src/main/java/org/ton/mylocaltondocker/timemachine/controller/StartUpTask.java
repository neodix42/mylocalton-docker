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

  private volatile AdnlLiteClient adnlLiteClient;
  private final Object lock = new Object();

  @EventListener(ApplicationReadyEvent.class)
  public void onApplicationReady() throws InterruptedException {

    System.out.println("Initializing tonlib");

    while (!Files.exists(Paths.get("/usr/share/data/global.config.json"))) {
      System.out.println("time-machine-app is waiting for /usr/share/data/global.config.json");
      Thread.sleep(5000);
    }

    log.info("SERVER_PORT {}", System.getenv("SERVER_PORT"));

    try {
      // Initialize the thread-safe client
      AdnlLiteClient client = getAdnlLiteClient();
      
      // Also set the static field for backward compatibility
      Main.adnlLiteClient = client;

      log.info(client.getMasterchainInfo().getLast().toString());

    } catch (Exception e) {
      log.error("can't get seqno " + e.getMessage());
    }

    log.info("time-machine-app ready");
  }

  /**
   * Thread-safe method to get AdnlLiteClient instance.
   * Uses double-checked locking pattern for lazy initialization.
   * 
   * @return AdnlLiteClient instance
   * @throws RuntimeException if client initialization fails
   */
  public AdnlLiteClient getAdnlLiteClient() {
    if (adnlLiteClient == null) {
      synchronized (lock) {
        if (adnlLiteClient == null) {
          try {
            log.info("Initializing AdnlLiteClient in thread-safe manner");
            
            // Wait for config file to be available
            while (!Files.exists(Paths.get("/usr/share/data/global.config.json"))) {
              log.warn("Waiting for /usr/share/data/global.config.json to be available");
              Thread.sleep(1000);
            }
            
            adnlLiteClient = AdnlLiteClient.builder()
                .configPath("/usr/share/data/global.config.json")
                .queryTimeout(10)
                .build();
                
            log.info("AdnlLiteClient initialized successfully");
            
          } catch (Exception e) {
            log.error("Failed to initialize AdnlLiteClient: {}", e.getMessage(), e);
            throw new RuntimeException("Failed to initialize AdnlLiteClient", e);
          }
        }
      }
    }
    return adnlLiteClient;
  }
}
