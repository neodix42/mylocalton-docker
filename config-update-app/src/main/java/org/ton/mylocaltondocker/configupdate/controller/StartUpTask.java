package org.ton.mylocaltondocker.configupdate.controller;

import com.iwebpp.crypto.TweetNaclFast;
import java.nio.file.Files;
import java.nio.file.Path;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.ton.mylocaltondocker.configupdate.Main;
import org.ton.ton4j.adnl.AdnlLiteClient;
import org.ton.ton4j.utils.Utils;

@Component
@Slf4j
public class StartUpTask {

  private static final Path GLOBAL_CONFIG_PATH = Path.of("/usr/share/data/global.config.json");
  private static final Path CONFIG_KEY_PATH = Path.of("/usr/share/data/config-master.pk");

  @EventListener(ApplicationReadyEvent.class)
  public void onApplicationReady() {
    Path globalConfigPath = resolvePathFromEnv("GLOBAL_CONFIG_PATH", GLOBAL_CONFIG_PATH);
    Path configKeyPath = resolvePathFromEnv("CONFIG_KEY_PATH", CONFIG_KEY_PATH);

    log.info("config-update-app paths: GLOBAL_CONFIG_PATH={}, CONFIG_KEY_PATH={}", globalConfigPath, configKeyPath);

    while (!Files.exists(globalConfigPath)) {
      log.info("config-update-app is waiting for {}", globalConfigPath);
      Utils.sleep(3);
    }

    while (!Files.exists(configKeyPath)) {
      log.info("config-update-app is waiting for {}", configKeyPath);
      Utils.sleep(3);
    }

    try {
      Main.adnlLiteClient = AdnlLiteClient.builder().configPath(globalConfigPath.toString()).build();

      byte[] privateKeySeed = Files.readAllBytes(configKeyPath);
      Main.configKeyPair = Utils.generateSignatureKeyPairFromSeed(privateKeySeed);

      long seqno = Main.adnlLiteClient.getSeqno(Main.CONFIG_SMART_CONTRACT_ADDRESS);
      log.info("config-update-app ready, config wallet seqno {}", seqno);
    } catch (Exception e) {
      throw new IllegalStateException("Unable to initialize config-update-app", e);
    }
  }

  private Path resolvePathFromEnv(String envName, Path defaultPath) {
    String value = System.getenv(envName);
    if (value == null || value.isBlank()) {
      return defaultPath;
    }
    return Path.of(value);
  }
}
