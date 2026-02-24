package org.ton.mylocaltondocker.configupdate.controller;

import java.util.LinkedHashMap;
import java.util.Map;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.ton.mylocaltondocker.configupdate.service.ConfigUpdateService;

@RestController
@RequestMapping("/api/config")
@RequiredArgsConstructor
public class MyRestController {

  private final ConfigUpdateService configUpdateService;

  @GetMapping({"/params", "/supported"})
  public Map<String, Object> getSupportedParams() {
    Map<String, Object> response = new LinkedHashMap<>();
    response.put("success", true);
    response.put("params", configUpdateService.getSupportedParams());
    return response;
  }

  @GetMapping("/seqno")
  public Map<String, Object> getConfigSeqno() {
    Map<String, Object> response = new LinkedHashMap<>();
    response.put("success", true);
    response.put("seqno", configUpdateService.getConfigSeqno());
    return response;
  }

  @GetMapping("/{id}")
  public Map<String, Object> getParam(@PathVariable("id") int id) {
    Map<String, Object> response = new LinkedHashMap<>();
    response.put("success", true);
    response.put("param", configUpdateService.getParamDetails(id));
    return response;
  }

  @PostMapping("/{id}")
  public Map<String, Object> updateParam(
      @PathVariable("id") int id, @RequestBody Map<String, Object> request) {
    Object value = request.get("value");
    return configUpdateService.updateParam(id, value);
  }
}
