package org.ton.mylocaltondocker.data.controller;

import io.github.bucket4j.Bandwidth;
import io.github.bucket4j.Bucket;
import io.github.bucket4j.Refill;
import jakarta.servlet.http.HttpServletRequest;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import lombok.extern.slf4j.Slf4j;
import org.springframework.web.bind.annotation.*;
import org.ton.mylocaltondocker.data.Main;

@RestController
@Slf4j
public class MyRestController {
  private final ConcurrentHashMap<String, Bucket> sessionBuckets = new ConcurrentHashMap<>();
  String error;

  @PostMapping("/getTps")
  public Map<String, Object> getTps(
      @RequestBody Map<String, String> request, HttpServletRequest httpServletRequest) {
    log.info("running /getTps");

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
        long tps = Main.tonlib.getTpsOneBlock();
        log.info("calculated tps {}", tps);
        response.put("success", true);
        response.put("message", "Block TPS " + tps);
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
      response.put("message", "Something went wrong.");
      return response;
    }
  }

  @PostMapping("/getTps1")
  public Map<String, Object> getTps1(
      @RequestBody Map<String, String> request, HttpServletRequest httpServletRequest) {
    log.info("running /getTps1");

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
        long tps = Main.tonlib.getTps(1);
        log.info("calculated tps {}", tps);
        response.put("success", true);
        response.put("message", "1 minute TPS " + tps);
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
      response.put("message", "Something went wrong.");
      return response;
    }
  }

  @PostMapping("/getTps5")
  public Map<String, Object> getTps5(
      @RequestBody Map<String, String> request, HttpServletRequest httpServletRequest) {
    log.info("running /getTps5");

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
        long tps = Main.tonlib.getTps(5);
        log.info("calculated tps {}", tps);
        response.put("success", true);
        response.put("message", "5 minute TPS " + tps);
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
      response.put("message", "Something went wrong.");
      return response;
    }
  }
}
