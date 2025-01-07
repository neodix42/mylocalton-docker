package org.ton.mylocaltondocker.controller;

import io.github.bucket4j.Bandwidth;
import io.github.bucket4j.Bucket;
import io.github.bucket4j.Refill;
import jakarta.servlet.http.HttpServletRequest;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.lang3.StringUtils;
import org.springframework.http.*;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.client.RestTemplate;
import org.ton.java.address.Address;
import org.ton.java.smartcontract.wallet.v3.WalletV3R2;
import org.ton.java.tonlib.types.FullAccountState;
import org.ton.java.utils.Utils;
import org.ton.mylocaltondocker.Main;
import org.ton.mylocaltondocker.db.DB;
import org.ton.mylocaltondocker.db.WalletEntity;
import org.ton.mylocaltondocker.db.WalletPk;

import java.time.Duration;
import java.time.Instant;
import java.util.HashMap;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.ConcurrentHashMap;

import static java.util.Objects.nonNull;

@RestController
@Slf4j
public class MyRestController {
  String error;

  private final ConcurrentHashMap<String, Bucket> sessionBuckets = new ConcurrentHashMap<>();

  @PostMapping("/requestTons")
  public Map<String, Object> executeJavaCode(
      @RequestBody Map<String, String> request, HttpServletRequest httpServletRequest) {
    System.out.println("running /requestTons");

    String sessionId = httpServletRequest.getSession().getId();
    sessionBuckets.computeIfAbsent(
        sessionId,
        id -> {
          Refill refill = Refill.intervally(10, Duration.ofMinutes(1));
          Bandwidth limit = Bandwidth.classic(10, refill);
          return Bucket.builder().addLimit(limit).build();
        });

    Bucket bucket = sessionBuckets.get(sessionId);

    if (bucket.tryConsume(1)) {

      String token = request.get("token");

      String userAddress = request.get("userAddress1");
      String remoteIp = httpServletRequest.getRemoteAddr();

      Map<String, Object> response = new HashMap<>();

      if (validateCaptcha(token, remoteIp)) {

        if (!Address.isValid(userAddress)) {
          response.put("success", "false");
          response.put("message", "Wrong wallet format.");
          return response;
        }

        if (addRequest(remoteIp, userAddress)) {
          response.put("success", "true");
          response.put("message", "Request added and will be processed within 1 minute.");
          return response;
        } else {
          response.put("success", "false");
          response.put("message", "Request already processed, wait for the next round.");
          return response;
        }
      } else {
        response.put("success", false);
        response.put("message", "captcha validation failed.");
        return response;
      }
    } else {
      Map<String, Object> response = new HashMap<>();
      log.info("rate limit, session {}", sessionId);
      response.put("success", false);
      response.put("message", "rate limit, 10 requests per minute");
      return response;
    }
  }

  private boolean validateCaptcha(String token, String remoteIp) {
    String url = "https://www.google.com/recaptcha/api/siteverify";
    RestTemplate restTemplate = new RestTemplate();

    String recaptchaSecret = System.getenv("RECAPTCHA_SECRET");
    log.info("remote IP {}", remoteIp);

    if (StringUtils.isEmpty(recaptchaSecret)) {
      error = "Missing recaptcha secret key!";
      return false;
    }

    String postParams =
        String.format("secret=%s&response=%s&remoteip=%s", recaptchaSecret, token, remoteIp);

    HttpHeaders headers = new HttpHeaders();
    headers.setContentType(MediaType.APPLICATION_FORM_URLENCODED);

    HttpEntity<String> entity = new HttpEntity<>(postParams, headers);

    try {
      ResponseEntity<Map> response = restTemplate.exchange(url, HttpMethod.POST, entity, Map.class);

      Map<String, Object> googleResponse = response.getBody();
      if (Boolean.TRUE.equals(googleResponse.get("success"))) {
        return true;
      }
    } catch (Exception e) {
      e.printStackTrace();
    }
    return false;
  }

  @PostMapping("/getBalance")
  public Map<String, Object> getBalance(
      @RequestBody Map<String, String> request, HttpServletRequest httpServletRequest) {
    log.info("running /getBalance");

    try {

      Map<String, Object> response = new HashMap<>();

      String sessionId = httpServletRequest.getSession().getId();
      sessionBuckets.computeIfAbsent(
          sessionId,
          id -> {
            Refill refill = Refill.intervally(10, Duration.ofMinutes(1));
            Bandwidth limit = Bandwidth.classic(10, refill);
            return Bucket.builder().addLimit(limit).build();
          });

      Bucket bucket = sessionBuckets.get(sessionId);

      if (bucket.tryConsume(1)) {
        log.info("consumed, session {}", sessionId);
        String userAddress = request.get("userAddress2");

        FullAccountState fullAccountState = Main.tonlib.getAccountState(Address.of(userAddress));
        log.info("account state {}", fullAccountState);

        response.put("success", true);
        response.put("message", Utils.formatNanoValue(fullAccountState.getBalance()));

        return response;
      } else {
        log.info("rate limit, session {}", sessionId);
        response.put("success", false);
        response.put("message", "rate limit, 10 requests per minute");
        return response;
      }
    } catch (Error e) {
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Something went wrong. Maybe address does not exist?");
      return response;
    }
  }

  @PostMapping("/generateWallet")
  public Map<String, Object> generateWallet(
      @RequestBody Map<String, String> request, HttpServletRequest httpServletRequest) {
    log.info("running /generateWallet");

    String sessionId = httpServletRequest.getSession().getId();
    sessionBuckets.computeIfAbsent(
        sessionId,
        id -> {
          Refill refill = Refill.intervally(10, Duration.ofMinutes(1));
          Bandwidth limit = Bandwidth.classic(10, refill);
          return Bucket.builder().addLimit(limit).build();
        });

    Bucket bucket = sessionBuckets.get(sessionId);

    if (bucket.tryConsume(1)) {
      String token = request.get("token");

      String remoteIp = httpServletRequest.getRemoteAddr();

      Map<String, Object> response = new HashMap<>();

      if (validateCaptcha(token, remoteIp)) {
        try {
          String MASTERCHAIN_ONLY = System.getenv("MASTERCHAIN_ONLY");
          log.info("MASTERCHAIN_ONLY {}", MASTERCHAIN_ONLY); // if true create wallets only in masterchain

          long walletId = Math.abs(Utils.getRandomInt());
          WalletV3R2 walletV3R2 =
              WalletV3R2.builder()
                  .wc((Objects.equals(MASTERCHAIN_ONLY, "true")) ? -1 : 0)
                  .walletId(walletId)
                  .build();

          response.put("success", true);
          response.put(
              "prvKey", Utils.bytesToHex(walletV3R2.getKeyPair().getSecretKey()).substring(0, 64));
          response.put("pubKey", Utils.bytesToHex(walletV3R2.getKeyPair().getPublicKey()));
          response.put("walletId", walletId);
          response.put("rawAddress", walletV3R2.getAddress().toRaw());
          log.info("generated wallet {}", walletV3R2.getAddress().toRaw());

          return response;
        } catch (Error e) {
          response.put("success", false);
          response.put("message", "cannot generate wallet");
          return response;
        }
      } else {
        response.put("success", false);
        response.put("message", "captcha validation failed.");
        return response;
      }
    } else {
      Map<String, Object> response = new HashMap<>();

      log.info("rate limit, session {}", sessionId);
      response.put("success", false);
      response.put("message", "rate limit, 10 requests per minute");
      return response;
    }
  }

  private boolean addRequest(String remoteIp, String walletAddr) {
    if (DB.findRemoteIp(remoteIp).size() > 0) { // this ip already requested
      log.error("cant add request - ip {} found", remoteIp);
      return false;
    }

    if (nonNull(
        DB.findWallet(
            WalletPk.builder()
                .walletAddress(walletAddr)
                .build()))) { // this wallet already requested
      log.error("cant add request - wallet {} found", walletAddr);
      return false;
    }

    return DB.insertWallet(
        WalletEntity.builder()
            .walletAddress(walletAddr)
            .createdAt(Instant.now().getEpochSecond())
            .remoteIp(remoteIp)
            .build());
  }
}
