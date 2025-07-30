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

  // Thread-safe synchronization object for getAdnlLiteClient method
  private static final Object CLIENT_CREATION_LOCK = new Object();
  
  // Volatile flag to track if client creation is in progress
  private static volatile boolean isCreatingClient = false;

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

  /**
   * Thread-safe method to create a new AdnlLiteClient instance.
   * Uses synchronized block to ensure only one thread can create a client at a time.
   * 
   * @return new AdnlLiteClient instance
   * @throws Exception if client creation fails
   */
  public static AdnlLiteClient getAdnlLiteClient() throws Exception {
    synchronized (CLIENT_CREATION_LOCK) {
      // Double-check if another thread is already creating a client
      if (isCreatingClient) {
        log.debug("Another thread is already creating AdnlLiteClient, waiting...");
        // Wait for the other thread to complete
        while (isCreatingClient) {
          try {
            CLIENT_CREATION_LOCK.wait(1000); // Wait with timeout to avoid infinite wait
          } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new Exception("Thread interrupted while waiting for client creation", e);
          }
        }
        log.debug("Client creation by another thread completed");
      }
      
      try {
        isCreatingClient = true;
        log.debug("Creating new AdnlLiteClient instance");
        
        AdnlLiteClient client = AdnlLiteClient.builder()
            .configPath("/usr/share/data/global.config.json")
            .queryTimeout(10)
            .build();
            
        log.debug("AdnlLiteClient instance created successfully");
        return client;
        
      } finally {
        isCreatingClient = false;
        CLIENT_CREATION_LOCK.notifyAll(); // Notify waiting threads
      }
    }
  }
}
