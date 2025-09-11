package org.ton.mylocaltondocker.data.controller;

import com.iwebpp.crypto.TweetNaclFast;
import java.lang.reflect.Constructor;
import java.math.BigInteger;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.ton.mylocaltondocker.data.Main;
import org.ton.mylocaltondocker.data.db.DB;
import org.ton.mylocaltondocker.data.db.WalletEntity;
import org.ton.mylocaltondocker.data.db.WalletPk;
import org.ton.mylocaltondocker.data.scenarios.*;
import org.ton.ton4j.address.Address;
import org.ton.ton4j.smartcontract.highload.HighloadWallet;
import org.ton.ton4j.smartcontract.types.Destination;
import org.ton.ton4j.smartcontract.types.HighloadConfig;
import org.ton.ton4j.tonlib.Tonlib;
import org.ton.ton4j.tonlib.types.*;
import org.ton.ton4j.utils.Utils;

@Component
@Slf4j
public class StartUpTask {

  private static final byte[] dataFaucetHighLoadPrvKey =
      Utils.hexToSignedBytes("e1480435871753a968ef08edabb24f5532dab4cd904dbdc683b8576fb45fa697");
  public static Address dataHighloadFaucetAddress;
  private final List<String> scenarios = new ArrayList<>();
  private HighloadWallet dataHighloadFaucet;

  private long period;

  private static Runnable errorHandlingWrapper(Runnable action) {
    return () -> {
      try {
        action.run();
      } catch (Throwable e) {
        e.printStackTrace();
      }
    };
  }

  @EventListener(ApplicationReadyEvent.class)
  public void onApplicationReady() {

    while (!Files.exists(Paths.get("/usr/share/data/global.config.json"))) {
      System.out.println("data-app is waiting for /usr/share/data/global.config.json");
      Utils.sleep(5);
    }

    try {
      log.info("Initializing tonlib");

      log.info("SERVER_PORT {}", System.getenv("SERVER_PORT").strip());
      log.info("PERIOD {}", System.getenv("PERIOD").strip());
      period = Long.parseLong(System.getenv("PERIOD").strip());

      Main.tonlib =
          Tonlib.builder()
              .pathToTonlibSharedLib("/usr/share/data/libtonlibjson.so")
              .pathToGlobalConfig("/usr/share/data/global.config.json")
              .ignoreCache(false)
              .receiveRetryTimes(10)
              .build();

      log.info(Utils.bytesToHex(dataFaucetHighLoadPrvKey));
      TweetNaclFast.Signature.KeyPair keyPair =
          Utils.generateSignatureKeyPairFromSeed(dataFaucetHighLoadPrvKey);

      dataHighloadFaucet =
          HighloadWallet.builder()
              .tonlib(Main.tonlib)
              .keyPair(keyPair)
              .wc(-1)
              .walletId(42)
              .queryId(BigInteger.ZERO)
              .build();

      dataHighloadFaucetAddress = dataHighloadFaucet.getAddress();
      log.info(
          "highload faucet address {}, balance {}",
          dataHighloadFaucet.getAddress().toRaw(),
          Utils.formatNanoValue(dataHighloadFaucet.getBalance()));

      log.info(
          "highload faucet pending queue size {}, total queue size {}",
          DB.getWalletsToSend().size(),
          DB.getTotalWallets());
    } catch (Exception e) {
      log.error("Error: " + e.getMessage());
    }

    runTopUpQueueScheduler();

    scenarios.add("Scenario1");
    scenarios.add("Scenario2");
    scenarios.add("Scenario3");
    scenarios.add("Scenario4");
    scenarios.add("Scenario5");
    scenarios.add("Scenario6");
    scenarios.add("Scenario7");
    scenarios.add("Scenario8");
    scenarios.add("Scenario9");
    scenarios.add("Scenario10");
    scenarios.add("Scenario11");
    scenarios.add("Scenario12");
    scenarios.add("Scenario13");

    //    scenarios.add(
    //        "Scenario14"); // works only when workchain enabled, order contract created at
    // workchain=0

    scenarios.add("Scenario15");
    scenarios.add("Scenario16");
    runScenariosScheduler();

    runCleanQueueScheduler();

    log.info("data-app ready");
  }

  public void runTopUpQueueScheduler() {

    ScheduledExecutorService executor = Executors.newSingleThreadScheduledExecutor();
    Runnable topUpTask =
        errorHandlingWrapper(
            () -> {
              try {
                Thread.currentThread().setName("SendRequest");

                List<WalletEntity> walletRequests = DB.getWalletsToSend();
                log.info("triggered send to {} wallets", walletRequests.size());
                if (walletRequests.size() == 0) {
                  //                  log.info("queue is empty, nothing to do, was sent {}",
                  // DB.getWalletsSent().size());
                  return;
                }

                if (dataHighloadFaucet.getBalance().longValue() <= 0) {
                  log.error("dataHighloadFaucet has no funds");
                  return;
                }

                List<Destination> destinations = new ArrayList<>();
                for (WalletEntity wallet : walletRequests) {
                  destinations.add(
                      Destination.builder()
                          .bounce(false)
                          .address(wallet.getWalletAddress())
                          .amount(wallet.getBalance())
                          .build());
                }

                List<Destination> destinations250 =
                    new ArrayList<>(destinations.subList(0, Math.min(destinations.size(), 250)));
                destinations.subList(0, Math.min(destinations.size(), 250)).clear();

                HighloadConfig config =
                    HighloadConfig.builder()
                        .walletId(42)
                        .queryId(BigInteger.valueOf(Instant.now().getEpochSecond() + 60L << 32))
                        .destinations(destinations250)
                        .build();

                dataHighloadFaucet.send(config);

                for (Destination destination : destinations250) {
                  DB.updateWalletStatus(
                      WalletPk.builder().walletAddress(destination.getAddress()).build(), "sent");
                }
                log.info("data-app faucet updated");
              } catch (Throwable e) {
                log.info("error in data-app " + e.getMessage());
              }
            });

    executor.scheduleAtFixedRate(topUpTask, 30, 15, TimeUnit.SECONDS);
  }

  public void runScenariosScheduler() {

    for (String scenario : scenarios) {

      Executors.newSingleThreadScheduledExecutor()
          .scheduleAtFixedRate(
              () -> {
                Thread.currentThread().setName(scenario);
                Executors.newSingleThreadExecutor()
                    .submit(
                        () -> {
                          Class<?> clazz;
                          try {

                            if (dataHighloadFaucet.getBalance().longValue() <= 0) {
                              log.error("dataHighloadFaucet has no funds");
                              return;
                            }
                            clazz =
                                Class.forName(
                                    "org.ton.mylocaltondocker.data.scenarios." + scenario);
                            Constructor<?> constructor = clazz.getConstructor(Tonlib.class);
                            Object instance = constructor.newInstance(Main.tonlib);
                            ((Scenario) instance).run();

                          } catch (Throwable e) {
                            log.info("error {}", e.getMessage());
                          }
                        });
              },
              1,
              period,
              TimeUnit.MINUTES);
    }
  }

  public void runCleanQueueScheduler() {

    Executors.newSingleThreadScheduledExecutor()
        .scheduleAtFixedRate(
            () -> {
              Thread.currentThread().setName("CleanQueue");
              DB.deleteExpiredWallets(60 * 10);
            },
            2,
            5,
            TimeUnit.MINUTES);
  }
}
