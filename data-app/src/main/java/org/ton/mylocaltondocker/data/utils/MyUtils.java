package org.ton.mylocaltondocker.data.utils;


import java.math.BigInteger;
import lombok.extern.slf4j.Slf4j;
import org.ton.mylocaltondocker.data.db.DB;
import org.ton.ton4j.address.Address;
import org.ton.ton4j.smartcontract.wallet.Contract;
import org.ton.ton4j.smartcontract.wallet.v3.WalletV3R2;
import org.ton.ton4j.tonlib.Tonlib;
import org.ton.ton4j.utils.Utils;

@Slf4j
public class MyUtils {
  public BigInteger getBalance(Tonlib tonlib, Address address) {
    return new BigInteger(tonlib.getRawAccountState(address).getBalance());
  }

  /**
   * returns if balance has changed by tolerateNanoCoins either side within timeoutSeconds,
   * otherwise throws an error.
   *
   * @param timeoutSeconds timeout in seconds
   * @param tolerateNanoCoins tolerate value
   */
  public void waitForBalanceChangeWithTolerance(
      Tonlib tonlib, Address address, int timeoutSeconds, BigInteger tolerateNanoCoins) {

    BigInteger initialBalance = getBalance(tonlib, address);
    long diff;
    int i = 0;
    do {
      if (++i * 2 >= timeoutSeconds) {
        break;
      }
      Utils.sleep(2);
      BigInteger currentBalance = getBalance(tonlib, address);

      diff =
          Math.max(currentBalance.longValue(), initialBalance.longValue())
              - Math.min(currentBalance.longValue(), initialBalance.longValue());
    } while (diff < tolerateNanoCoins.longValue());
  }

  public Contract deploy(Tonlib tonlib, BigInteger topUpAmount) {
    long walletId = Math.abs(Utils.getRandomInt());
    WalletV3R2 contract = WalletV3R2.builder().tonlib(tonlib).walletId(walletId).build();

    String nonBounceableAddress = contract.getAddress().toNonBounceable();
    DB.addRequest(nonBounceableAddress, topUpAmount);
    Utils.sleep(3);
    contract.deploy();
    Utils.sleep(3);

    return contract;
  }
}
