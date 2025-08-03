package org.ton.mylocaltondocker.timemachine.controller;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.ton.java.adnl.AdnlLiteClient;
import org.ton.mylocaltondocker.timemachine.Main;

import static java.util.Objects.nonNull;

@Component
@Slf4j
public class StartUpTask {

  // Atomic flag to track if client creation is in progress
  private static final AtomicBoolean isCreatingClient = new AtomicBoolean(false);

  // Track the last successful reinitialization time to avoid too frequent reinits
  private static final AtomicLong lastReinitTime = new AtomicLong(0);

  // Minimum time between reinitializations (in milliseconds)
  private static final long MIN_REINIT_INTERVAL = 5000; // 5 seconds

  @EventListener(ApplicationReadyEvent.class)
  public void onApplicationReady() throws InterruptedException {

    System.out.println("Initializing tonlib");

    while (!Files.exists(Paths.get("/usr/share/data/global.config.json"))) {
      System.out.println("time-machine-app is waiting for /usr/share/data/global.config.json");
      Thread.sleep(5000);
    }

    log.info("SERVER_PORT {}", System.getenv("SERVER_PORT"));

    try {

      Main.adnlLiteClient =
          AdnlLiteClient.builder()
              .configPath("/usr/share/data/global.config.json")
              .queryTimeout(10)
              .build();

//      log.info(Main.adnlLiteClient.getMasterchainInfo().getLast().toString());

    } catch (Exception e) {
      log.error("can't get seqno " + e.getMessage());
    }

    log.info("time-machine-app ready");
  }

  /**
   * Simple thread-safe method to reinitialize AdnlLiteClient. Tries once, if it fails - exits and
   * will try again on next request. Uses minimum interval to prevent too frequent attempts.
   */
  public static void reinitializeAdnlLiteClient() throws Exception {
    long currentTime = System.currentTimeMillis();
    long lastReinit = lastReinitTime.get();

    // Check if we're within the minimum interval since last reinitialization
    if (currentTime - lastReinit < MIN_REINIT_INTERVAL) {
      log.debug(
          "Skipping reinitialization - too soon since last attempt ({}ms ago)",
          currentTime - lastReinit);
      return;
    }

    // Try to acquire the reinitialization lock
    if (!isCreatingClient.compareAndSet(false, true)) {
      log.debug("Another thread is already reinitializing client, skipping this request");
      return;
    }

    try {
      log.info("Starting AdnlLiteClient reinitialization");

      // Close existing client with proper cleanup
      AdnlLiteClient oldClient = Main.adnlLiteClient;
      if (nonNull(oldClient)) {
        try {
          log.debug("Closing existing AdnlLiteClient");
          oldClient.close();
          // Give some time for cleanup
          Thread.sleep(100);
        } catch (Exception e) {
          log.warn("Error closing old AdnlLiteClient: {}", e.getMessage());
        }
      }

      // Create new client - single attempt
      log.debug("Creating new AdnlLiteClient");
      AdnlLiteClient newClient =
          AdnlLiteClient.builder()
              .configPath("/usr/share/data/global.config.json")
              .queryTimeout(5)
              .maxRetries(1)
              .build();

      // Test the connection
      //      newClient.getMasterchainInfo();

      // Assign the new client
      Main.adnlLiteClient = newClient;
      lastReinitTime.set(System.currentTimeMillis());
      log.info("AdnlLiteClient reinitialization completed successfully");

    } catch (Exception e) {
      log.error("AdnlLiteClient reinitialization failed: {}", e.getMessage());
      throw new Exception("AdnlLiteClient reinitialization failed", e);
    } finally {
      // Always release the lock
      isCreatingClient.set(false);
    }
  }
}
