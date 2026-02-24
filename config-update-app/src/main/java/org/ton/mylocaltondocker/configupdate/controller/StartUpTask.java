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
    while (!Files.exists(GLOBAL_CONFIG_PATH)) {
      log.info("config-update-app is waiting for {}", GLOBAL_CONFIG_PATH);
      Utils.sleep(3);
    }

    while (!Files.exists(CONFIG_KEY_PATH)) {
      log.info("config-update-app is waiting for {}", CONFIG_KEY_PATH);
      Utils.sleep(3);
    }

    try {
      Main.adnlLiteClient = AdnlLiteClient.builder().configPath(GLOBAL_CONFIG_PATH.toString()).build();

      byte[] privateKeySeed = Files.readAllBytes(CONFIG_KEY_PATH);
      Main.configKeyPair = Utils.generateSignatureKeyPairFromSeed(privateKeySeed);

      long seqno = Main.adnlLiteClient.getSeqno(Main.CONFIG_SMART_CONTRACT_ADDRESS);
      log.info("config-update-app ready, config wallet seqno {}", seqno);
    } catch (Exception e) {
      throw new IllegalStateException("Unable to initialize config-update-app", e);
    }
  }
}
