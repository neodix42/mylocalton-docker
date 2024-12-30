package org.ton.mylocaltondocker.controller;

import com.iwebpp.crypto.TweetNaclFast;
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
      @RequestBody Map<String, String> request) {
    System.out.println("running /validate-captcha");

    String token = request.get("token");
    String userInput = request.get("userInput");

    Map<String, Object> response = new HashMap<>();

    if (token == null || token.isEmpty()) {
      response.put("success", false);
      response.put("message", "CAPTCHA validation failed. Missing token.");
      return response;
    }


    if (validateCaptcha(token)) {

      executeSomeJavaLogic(userInput);

      response.put("success", true);
      response.put("message", "Java code executed successfully." + error);
    } else {
      response.put("success", false);
      response.put("message", "CAPTCHA validation failed. " + error);
    }

    return response;
  }

  private boolean validateCaptcha(String token) {
    String RECAPTCHA_VERIFY_URL = "https://recaptchaenterprise.googleapis.com/v1/projects/{projectId}/assessments?key={apiKey}";
    RestTemplate restTemplate = new RestTemplate();
    HttpHeaders headers = new HttpHeaders();
    headers.setContentType(MediaType.APPLICATION_JSON);

    String siteKey = "6LeObqkqAAAAAEN5U4kr6nCSJwAcvqVO5ulflS2b";
    String expectedAction = "submit";
    String projectId = "mymemory-435017";
    String apiKey = "AIzaSyDGoHNbLzcMkVwwNfBCGZhD0YS2QAo9IbM";

    // Construct the request payload
    Map<String, Object> payload = new HashMap<>();
    Map<String, Object> event = new HashMap<>();
    event.put("token", token);
    event.put("siteKey", siteKey);
    event.put("expectedAction", expectedAction);
    payload.put("event", event);

    // Send the request
    HttpEntity<Map<String, Object>> entity = new HttpEntity<>(payload, headers);
    try {
      ResponseEntity<Map> response = restTemplate.exchange(
              RECAPTCHA_VERIFY_URL,
              HttpMethod.POST,
              entity,
              Map.class,
              projectId,
              apiKey
      );

      Map<String, Object> responseBody = response.getBody();
      // Extract the "tokenProperties" object as a Map
      Map<String, Object> tokenProperties = (Map<String, Object>) responseBody.get("tokenProperties");
      if (tokenProperties != null && Boolean.TRUE.equals(tokenProperties.get("valid"))) {
        return true;
      }
    } catch (Exception e) {
      e.printStackTrace();
    }
    return false;
  }

//
//  private boolean validateCaptcha(String token) {
//    String RECAPTCHA_VERIFY_URL = "https://recaptchaenterprise.googleapis.com/v1/projects/{projectId}/assessments?key={apiKey}";
////    String recaptchaSecret = System.getenv("RECAPTCHA_SECRET");
//
//    RestTemplate restTemplate = new RestTemplate();
//    HttpHeaders headers = new HttpHeaders();
//    headers.setContentType(MediaType.APPLICATION_JSON);
//    HttpEntity<String> entity = new HttpEntity<>("{\"token\":\"" + token + "\"}", headers);
//
//    // Send the request to Google reCAPTCHA Enterprise API
//    ResponseEntity<Map> responseEntity = restTemplate.exchange(
//            RECAPTCHA_VERIFY_URL,
//            HttpMethod.POST,
//            entity,
//            Map.class,
//            "mymemory-435017", // Replace with your Google Cloud project ID
//            "AIzaSyDGoHNbLzcMkVwwNfBCGZhD0YS2QAo9IbM" // Use your reCAPTCHA API key here
//    );
//
//    Map<String, Object> googleResponse = responseEntity.getBody();
//    if (googleResponse != null) {
//      return Boolean.TRUE.equals(googleResponse.get("success"));
//    }
//    return false;
//  }

//  private boolean validateCaptcha(String token) {
//    String url = "https://www.google.com/recaptcha/api/siteverify";
////    String url = "https://www.google.com/recaptcha/enterprise/siteverify";
//    RestTemplate restTemplate = new RestTemplate();
//
//    String recaptchaSecret = System.getenv("RECAPTCHA_SECRET");
//
//    if (recaptchaSecret == null || recaptchaSecret.isEmpty()) {
//      error = "Missing recaptcha secret key!";
//      return false;
//    }
//
//    Map<String, String> body = new HashMap<>();
//    body.put("secret", recaptchaSecret);
//    body.put("response", token);
//
//    Map<String, Object> googleResponse = restTemplate.postForObject(url, body, Map.class);
//
//    error = String.valueOf(googleResponse.get("error-codes"));
//    return Boolean.TRUE.equals(googleResponse.get("success"));
//  }

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
