package org.ton.mylocaltondocker.configupdate;

import com.iwebpp.crypto.TweetNaclFast;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.ton.ton4j.address.Address;
import org.ton.ton4j.adnl.AdnlLiteClient;

@SpringBootApplication
public class Main {

  public static final Address CONFIG_SMART_CONTRACT_ADDRESS =
      Address.of("-1:5555555555555555555555555555555555555555555555555555555555555555");

  public static AdnlLiteClient adnlLiteClient;
  public static TweetNaclFast.Signature.KeyPair configKeyPair;

  public static void main(String[] args) {
    SpringApplication.run(Main.class, args);
  }
}
