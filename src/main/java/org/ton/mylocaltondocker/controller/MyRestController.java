package org.ton.mylocaltondocker.controller;

import com.iwebpp.crypto.TweetNaclFast;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.*;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.client.RestTemplate;
import org.ton.java.address.Address;
import org.ton.java.smartcontract.types.WalletV3Config;
import org.ton.java.smartcontract.wallet.v3.WalletV3R2;
import org.ton.java.tonlib.types.ExtMessageInfo;
import org.ton.java.tonlib.types.FullAccountState;
import org.ton.java.utils.Utils;
import org.ton.mylocaltondocker.Main;

import java.util.HashMap;
import java.util.Map;

@RestController
public class MyRestController {
  String error;

  @PostMapping("/validateCaptcha")
  public Map<String, Object> executeJavaCode(
      @RequestBody Map<String, String> request,  HttpServletRequest requestr ) {
    System.out.println("running /validate-captcha");

    String token = request.get("token");
    String userInput = request.get("userInput");

    Map<String, Object> response = new HashMap<>();

    if (token == null || token.isEmpty()) {
      response.put("success", false);
      response.put("message", "CAPTCHA validation failed. Missing token.");
      return response;
    }


    if (validateCaptcha(token,requestr.getRemoteAddr())) {

      executeSomeJavaLogic(userInput);

      response.put("success", true);
      response.put("message", "Java code executed successfully." + error);
    } else {
      response.put("success", false);
      response.put("message", "CAPTCHA validation failed. " + error);
    }

    return response;
  }

  private boolean validateCaptcha(String token, String remoteIp) {
    String url = "https://www.google.com/recaptcha/api/siteverify";
    RestTemplate restTemplate = new RestTemplate();

    String recaptchaSecret = System.getenv("RECAPTCHA_SECRET");
    System.out.println("remote IP "+remoteIp);

    if (recaptchaSecret == null || recaptchaSecret.isEmpty()) {
      error = "Missing recaptcha secret key!";
      return false;
    }

    String postParams = String.format("secret=%s&response=%s&remoteip=%s",
            recaptchaSecret,
            token,
            remoteIp);

    HttpHeaders headers = new HttpHeaders();
    headers.setContentType(MediaType.APPLICATION_FORM_URLENCODED);

    HttpEntity<String> entity = new HttpEntity<>(postParams, headers);

    try {
      ResponseEntity<Map> response = restTemplate.exchange(
              url,
              HttpMethod.POST,
              entity,
              Map.class
      );

      Map<String, Object> googleResponse = response.getBody();
      if (Boolean.TRUE.equals(googleResponse.get("success"))) {
        return true;
      }
    } catch (Exception e) {
      e.printStackTrace();
    }
    return false;
  }

  private void executeSomeJavaLogic(String userInput) {

    byte[] prvKey =
        Utils.hexToSignedBytes("249489b5c1bfa6f62451be3714679581ee04cc8f82a8e3f74b432a58f3e4fedf");
    TweetNaclFast.Signature.KeyPair keyPair = Utils.generateSignatureKeyPairFromSeed(prvKey);

    WalletV3R2 contract =
        WalletV3R2.builder().tonlib(Main.tonlib).wc(-1).keyPair(keyPair).walletId(42).build();
    System.out.println("WalletV3R2 address " + contract.getAddress().toRaw());

    WalletV3Config walletConfig =
        WalletV3Config.builder()
            .walletId(42)
            .seqno(contract.getSeqno())
            .destination(Address.of(userInput))
            .amount(Utils.toNano(10))
            .build();
    ExtMessageInfo extMessageInfo = contract.send(walletConfig);
    error = extMessageInfo.toString();
  }

  @PostMapping("/getBalance")
  public Map<String, Object> getBalance(@RequestBody Map<String, String> request) {
    System.out.println("running /getBalance");

    String userAddress = request.get("userAddress");

    try {
      FullAccountState fullAccountState = Main.tonlib.getAccountState(Address.of(userAddress));
      System.out.println("account state " + fullAccountState);

      Map<String, Object> response = new HashMap<>();
      response.put(
          "balance", "Account balance for " + Utils.formatNanoValue(fullAccountState.getBalance()));
      return response;
    } catch (Error e) {
      Map<String, Object> response = new HashMap<>();
      response.put("balance", "-1");
      return response;
    }
  }
}
