package org.ton.mylocaltondocker.data.scenarios;

import static org.ton.mylocaltondocker.data.controller.StartUpTask.dataHighloadFaucetAddress;

import java.math.BigInteger;
import lombok.extern.slf4j.Slf4j;
import org.ton.mylocaltondocker.data.db.DB;
import org.ton.ton4j.smartcontract.types.WalletV3Config;
import org.ton.ton4j.smartcontract.wallet.v3.WalletV3R1;
import org.ton.ton4j.tonlib.Tonlib;
import org.ton.ton4j.utils.Utils;

/** to up V3R1 wallet, upload state-init with random wallet-id, send back to faucet 0.08 */
@Slf4j
public class Scenario6 implements Scenario {

  Tonlib tonlib;

  public Scenario6(Tonlib tonlib) {
    this.tonlib = tonlib;
  }

  public void run() {
    log.info("STARTED SCENARIO 6");

    long walletId = Math.abs(Utils.getRandomInt());
    WalletV3R1 contract = WalletV3R1.builder().tonlib(tonlib).walletId(walletId).build();

    String nonBounceableAddress = contract.getAddress().toNonBounceable();
    DB.addRequest(nonBounceableAddress, Utils.toNano(0.1));
    Utils.sleep(15);
    contract.deploy();
    Utils.sleep(3);

    WalletV3Config config =
        WalletV3Config.builder()
            .walletId(walletId)
            .seqno(1)
            .destination(dataHighloadFaucetAddress)
            .amount(Utils.toNano(0.08))
            .comment("mlt-scenario6")
            .build();

    contract.send(config);
    Utils.sleep(3);

    BigInteger balance = contract.getBalance();

    if (balance.longValue() > Utils.toNano(0.02).longValue()) {
      log.error("scenario6 failed");
    }

    log.info("FINISHED SCENARIO 6");
  }
}
