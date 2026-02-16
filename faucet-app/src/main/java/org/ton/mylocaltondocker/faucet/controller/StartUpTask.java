package org.ton.mylocaltondocker.faucet.controller;

import static java.util.Objects.nonNull;

import com.iwebpp.crypto.TweetNaclFast;
import java.io.File;
import java.math.BigInteger;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.io.FileUtils;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.ton.mylocaltondocker.faucet.Main;
import org.ton.mylocaltondocker.faucet.db.DB;
import org.ton.mylocaltondocker.faucet.db.WalletEntity;
import org.ton.mylocaltondocker.faucet.db.WalletPk;
import org.ton.ton4j.provider.SendResponse;
import org.ton.ton4j.smartcontract.highload.HighloadWallet;
import org.ton.ton4j.smartcontract.types.Destination;
import org.ton.ton4j.smartcontract.types.HighloadConfig;
import org.ton.ton4j.tonlib.Tonlib;
import org.ton.ton4j.utils.Utils;

@Component
@Slf4j
public class StartUpTask {

  private static byte[] prvKey;

  @EventListener(ApplicationReadyEvent.class)
  public void onApplicationReady() throws InterruptedException {

    System.out.println("Initializing tonlib");

    while (!Files.exists(Paths.get("/usr/share/data/global.config.json"))) {
      System.out.println("faucet-app is waiting for /usr/share/data/global.config.json");
      Utils.sleep(5);
    }

    log.info("FAUCET_USE_RECAPTCHA {}", System.getenv("FAUCET_USE_RECAPTCHA").strip());
    log.info("RECAPTCHA_SITE_KEY {}", System.getenv("RECAPTCHA_SITE_KEY").strip());
    log.info("RECAPTCHA_SECRET {}", System.getenv("RECAPTCHA_SECRET").strip());
    log.info("SERVER_PORT {}", System.getenv("SERVER_PORT").strip());
    log.info(
        "FAUCET_REQUEST_EXPIRATION_PERIOD {}",
        Integer.parseInt(System.getenv("FAUCET_REQUEST_EXPIRATION_PERIOD").strip()));
    log.info(
        "FAUCET_SINGLE_GIVEAWAY {}",
        Integer.parseInt(System.getenv("FAUCET_SINGLE_GIVEAWAY").strip()));

    try {

      Main.tonlib =
          Tonlib.builder()
              .pathToTonlibSharedLib("/usr/share/data/libtonlibjson.so")
              .pathToGlobalConfig("/usr/share/data/global.config.json")
              .ignoreCache(false)
              .receiveRetryTimes(10)
              .build();

      log.info(Main.tonlib.getLast().toString());

      prvKey = FileUtils.readFileToByteArray(new File("/usr/share/data/faucet-highload.pk"));
      log.info(Utils.bytesToHex(prvKey));
      TweetNaclFast.Signature.KeyPair keyPair = Utils.generateSignatureKeyPairFromSeed(prvKey);

      HighloadWallet highloadFaucet =
          HighloadWallet.builder()
              .tonlib(Main.tonlib)
              .keyPair(keyPair)
              .wc(-1)
              .walletId(42L)
              .queryId(BigInteger.ZERO)
              .build();

      log.info(
          "highload faucet address {}, balance {}",
          highloadFaucet.getAddress().toRaw(),
          Utils.formatNanoValue(highloadFaucet.getBalance()));

      log.info(
          "highload faucet pending queue size {}, total queue size {}",
          DB.getWalletsToSend().size(),
          DB.getTotalWallets());
    } catch (Exception e) {
      log.error("cant read /scripts/web/faucet-highload.pk or " + e.getMessage());
    }

    runFaucetSendScheduler();
    runFaucetCleanQueueScheduler();

    log.info("faucet-app ready");
  }

  public void runFaucetSendScheduler() {

    Executors.newSingleThreadScheduledExecutor()
        .scheduleAtFixedRate(
            () -> {
              Thread.currentThread().setName("SendRequest");

              List<WalletEntity> walletRequests = DB.getWalletsToSend();
              log.info("triggered send to {} wallets", walletRequests.size());
              if (walletRequests.isEmpty()) {
                log.info("queue is empty, nothing to do, was sent {}", DB.getWalletsSent().size());
                return;
              }

              List<Destination> destinations = new ArrayList<>();
              for (WalletEntity wallet : walletRequests) {
                destinations.add(
                    Destination.builder()
                        .bounce(false)
                        .address(wallet.getWalletAddress())
                        .amount(
                            Utils.toNano(
                                Integer.parseInt(System.getenv("FAUCET_SINGLE_GIVEAWAY").strip())))
                        .build());
              }

              //              log.info("generated total destinations {}", destinations.size());

              TweetNaclFast.Signature.KeyPair keyPair =
                  Utils.generateSignatureKeyPairFromSeed(prvKey);

              HighloadWallet highloadFaucet =
                  HighloadWallet.builder()
                      .tonlib(Main.tonlib)
                      .keyPair(keyPair)
                      .wc(-1)
                      .walletId(42L)
                      .queryId(BigInteger.ZERO)
                      .build();

              List<Destination> destinations250 =
                  new ArrayList<>(destinations.subList(0, Math.min(destinations.size(), 250)));
              //              log.info("sending batch {}", destinations250.size());
              destinations.subList(0, Math.min(destinations.size(), 250)).clear();

              HighloadConfig config =
                  HighloadConfig.builder()
                      .walletId(42)
                      .queryId(BigInteger.valueOf(Instant.now().getEpochSecond() + 60L << 32))
                      .destinations(destinations250)
                      .build();

              SendResponse extMessageInfo = highloadFaucet.send(config);
              log.info("contract send result {}", extMessageInfo);
              if (nonNull(extMessageInfo.getMessage())) {
                for (Destination destination : destinations250) {
                  DB.updateWalletStatus(
                      WalletPk.builder().walletAddress(destination.getAddress()).build(), "sent");
                }
              }

              log.info(
                  "faucet address {}, balance {}",
                  highloadFaucet.getAddress().toRaw(),
                  Utils.formatNanoValue(highloadFaucet.getBalance()));
            },
            30,
            30,
            TimeUnit.SECONDS);
  }

  public void runFaucetCleanQueueScheduler() {

    Executors.newSingleThreadScheduledExecutor()
        .scheduleAtFixedRate(
            () -> {
              Thread.currentThread().setName("CleanQueue");
              DB.deleteExpiredWallets(
                  Integer.parseInt(System.getenv("FAUCET_REQUEST_EXPIRATION_PERIOD").strip()));
            },
            2,
            5,
            TimeUnit.MINUTES);
  }
}
