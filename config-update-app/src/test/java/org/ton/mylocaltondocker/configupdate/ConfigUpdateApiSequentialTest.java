package org.ton.mylocaltondocker.configupdate;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.BooleanNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.fasterxml.jackson.databind.node.TextNode;
import java.io.IOException;
import java.math.BigInteger;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.junit.Assert;
import org.junit.Test;

public class ConfigUpdateApiSequentialTest {

  private static final ObjectMapper MAPPER = new ObjectMapper();
  private static final HttpClient HTTP =
      HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build();

  private static final String BASE_URL =
      System.getProperty("config.update.base.url", "http://localhost:8084");
  private static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(20);
  private static final Duration SEQNO_WAIT_TIMEOUT = Duration.ofSeconds(60);
  private static final long SEQNO_POLL_MILLIS = 1_500L;
  private static final Set<Integer> SKIPPED_PARAM_IDS = Set.of(0, 9, 10, 18, 33, 34, 35, 36, 37);

  @Test
  public void shouldUpdateAllConfigParamsSequentially() throws Exception {
    List<Integer> paramIds = getSupportedParamIds();
    Assert.assertFalse("No supported params returned by API", paramIds.isEmpty());

    for (int paramId : paramIds) {
      System.out.println("updating param " + paramId);
      long seqnoBefore = getSeqno();

      JsonNode paramResponse = httpGetJson("/api/config/" + paramId);
      Assert.assertTrue("GET /api/config/" + paramId + " failed", paramResponse.path("success").asBoolean(false));

      JsonNode param = paramResponse.path("param");
      JsonNode schema = param.path("schema");
      JsonNode currentValue = param.path("value");

      JsonNode payloadValue;
      if (isEmptyValue(currentValue)) {
        payloadValue = createDummyValue(schema);
      } else {
        payloadValue = currentValue.deepCopy();
      }
      payloadValue = normalizePayloadForParam(paramId, payloadValue);

      ObjectNode updateRequest = MAPPER.createObjectNode();
      updateRequest.set("value", payloadValue);

      JsonNode updateResponse = httpPostJson("/api/config/" + paramId, updateRequest);
      Assert.assertTrue(
          "Update failed for param " + paramId + ": " + updateResponse.path("message").asText(),
          updateResponse.path("success").asBoolean(false));

      long returnedSeqno = updateResponse.path("seqno").asLong(-1L);
      if (returnedSeqno >= 0L) {
        Assert.assertEquals(
            "Unexpected seqno in update response for param " + paramId,
            seqnoBefore,
            returnedSeqno);
      }

      long seqnoAfter = waitForSeqnoChange(seqnoBefore);
      Assert.assertTrue(
          "Seqno did not change after update for param " + paramId + ". Before=" + seqnoBefore + ", after=" + seqnoAfter,
          seqnoAfter > seqnoBefore);
    }
  }

  private List<Integer> getSupportedParamIds() throws Exception {
    JsonNode response = httpGetJson("/api/config/params");
    Assert.assertTrue("GET /api/config/params failed", response.path("success").asBoolean(false));

    List<Integer> ids = new ArrayList<>();
    JsonNode params = response.path("params");
    if (params.isArray()) {
      for (JsonNode item : params) {
        int id = item.path("id").asInt();
        if (SKIPPED_PARAM_IDS.contains(id)) {
          continue;
        }
        ids.add(id);
      }
    }
    ids.sort(Comparator.naturalOrder());
    return ids;
  }

  private long getSeqno() throws Exception {
    JsonNode response = httpGetJson("/api/config/seqno");
    Assert.assertTrue("GET /api/config/seqno failed", response.path("success").asBoolean(false));
    return response.path("seqno").asLong(-1L);
  }

  private long waitForSeqnoChange(long previousSeqno) throws Exception {
    long deadlineNanos = System.nanoTime() + SEQNO_WAIT_TIMEOUT.toNanos();
    long lastSeen = previousSeqno;

    while (System.nanoTime() < deadlineNanos) {
      long current = getSeqno();
      lastSeen = current;
      if (current > previousSeqno) {
        return current;
      }
      Thread.sleep(SEQNO_POLL_MILLIS);
    }
    return lastSeen;
  }

  private JsonNode httpGetJson(String path) throws Exception {
    HttpRequest request =
        HttpRequest.newBuilder()
            .uri(URI.create(BASE_URL + path))
            .timeout(REQUEST_TIMEOUT)
            .GET()
            .build();

    HttpResponse<String> response = HTTP.send(request, HttpResponse.BodyHandlers.ofString());
    Assert.assertEquals(
        "GET " + path + " returned status " + response.statusCode() + " with body: " + response.body(),
        200,
        response.statusCode());
    return parseJson(response.body(), "GET " + path);
  }

  private JsonNode httpPostJson(String path, JsonNode body) throws Exception {
    HttpRequest request =
        HttpRequest.newBuilder()
            .uri(URI.create(BASE_URL + path))
            .timeout(REQUEST_TIMEOUT)
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(MAPPER.writeValueAsString(body)))
            .build();

    HttpResponse<String> response = HTTP.send(request, HttpResponse.BodyHandlers.ofString());
    Assert.assertEquals(
        "POST " + path + " returned status " + response.statusCode() + " with body: " + response.body(),
        200,
        response.statusCode());
    return parseJson(response.body(), "POST " + path);
  }

  private JsonNode parseJson(String body, String requestName) throws IOException {
    try {
      return MAPPER.readTree(body);
    } catch (IOException e) {
      throw new IOException("Cannot parse JSON for " + requestName + ". Body: " + body, e);
    }
  }

  private boolean isEmptyValue(JsonNode value) {
    if (value == null || value.isNull() || value.isMissingNode()) {
      return true;
    }
    if (value.isTextual()) {
      return value.asText().trim().isEmpty();
    }
    if (value.isArray()) {
      if (value.size() == 0) {
        return true;
      }
      for (JsonNode item : value) {
        if (!isEmptyValue(item)) {
          return false;
        }
      }
      return true;
    }
    if (value.isObject()) {
      Iterator<Map.Entry<String, JsonNode>> fields = value.fields();
      while (fields.hasNext()) {
        Map.Entry<String, JsonNode> field = fields.next();
        if ("_type".equals(field.getKey())) {
          continue;
        }
        if (!isEmptyValue(field.getValue())) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  private JsonNode createDummyValue(JsonNode schema) {
    String kind = schema.path("kind").asText();
    switch (kind) {
      case "bigint":
      case "long":
      case "int":
        return TextNode.valueOf("1");
      case "boolean":
        return BooleanNode.TRUE;
      case "unit":
        return BooleanNode.TRUE;
      case "dict":
        return createDummyDict(schema);
      case "choice":
        return createDummyChoice(schema);
      case "object":
        return createDummyObject(schema);
      default:
        return TextNode.valueOf("1");
    }
  }

  private JsonNode createDummyDict(JsonNode schema) {
    ArrayNode entries = MAPPER.createArrayNode();
    String typeName = schema.path("typeName").asText("");
    boolean requiredNonEmpty = "TonHashMap".equals(typeName);
    if (!requiredNonEmpty) {
      return entries;
    }

    ObjectNode entry = MAPPER.createObjectNode();
    entry.set("key", createDummyValue(schema.path("key")));
    if (!schema.path("unitValue").asBoolean(false)) {
      entry.set("value", createDummyValue(schema.path("value")));
    } else {
      entry.set("value", BooleanNode.TRUE);
    }
    entries.add(entry);
    return entries;
  }

  private JsonNode createDummyChoice(JsonNode schema) {
    JsonNode options = schema.path("options");
    if (!options.isArray() || options.size() == 0) {
      return MAPPER.nullNode();
    }
    JsonNode selectedOption = options.get(0);
    JsonNode dummy = createDummyObject(selectedOption);
    if (dummy.isObject()) {
      ((ObjectNode) dummy).put("_type", selectedOption.path("typeName").asText());
    }
    return dummy;
  }

  private JsonNode createDummyObject(JsonNode schema) {
    ObjectNode node = MAPPER.createObjectNode();
    node.put("_type", schema.path("typeName").asText());
    JsonNode fields = schema.path("fields");
    if (fields.isArray()) {
      for (JsonNode field : fields) {
        String name = field.path("name").asText();
        node.set(name, createDummyValue(field.path("schema")));
      }
    }
    return node;
  }

  private JsonNode normalizePayloadForParam(int paramId, JsonNode payloadValue) throws Exception {
    if (!(payloadValue instanceof ObjectNode payloadObject)) {
      return payloadValue;
    }

    if (paramId == 5) {
      long feeBurnDenom = parseNodeLong(payloadObject.get("feeBurnDenom"), 0L);
      if (feeBurnDenom < 1L) {
        feeBurnDenom = 1L;
      }

      long feeBurnNum = parseNodeLong(payloadObject.get("feeBurnNum"), 0L);
      if (feeBurnNum < 0L) {
        feeBurnNum = 0L;
      }
      if (feeBurnNum > feeBurnDenom) {
        feeBurnNum = feeBurnDenom;
      }

      payloadObject.put("feeBurnNum", String.valueOf(feeBurnNum));
      payloadObject.put("feeBurnDenom", String.valueOf(feeBurnDenom));
      return payloadObject;
    }

    if (paramId == 7) {
      JsonNode extraCurrenciesNode = payloadObject.get("extraCurrencies");
      ArrayNode extraCurrencies;
      if (extraCurrenciesNode instanceof ArrayNode arrayNode) {
        extraCurrencies = arrayNode;
      } else {
        extraCurrencies = MAPPER.createArrayNode();
        payloadObject.set("extraCurrencies", extraCurrencies);
      }

      if (extraCurrencies.isEmpty()) {
        ObjectNode entry = MAPPER.createObjectNode();
        entry.put("key", "1");
        entry.put("value", "1");
        extraCurrencies.add(entry);
      } else {
        for (JsonNode node : extraCurrencies) {
          if (node instanceof ObjectNode entryNode) {
            entryNode.put("value", "1");
          }
        }
      }
      return payloadObject;
    }

    if (paramId == 8) {
      JsonNode globalVersionNode = payloadObject.get("globalVersion");
      ObjectNode globalVersion;
      if (globalVersionNode instanceof ObjectNode objectNode) {
        globalVersion = objectNode;
      } else {
        globalVersion = MAPPER.createObjectNode();
        globalVersion.put("_type", "GlobalVersion");
        payloadObject.set("globalVersion", globalVersion);
      }

      long version = parseNodeLong(globalVersion.get("version"), 0L);
      if (version < 0L) {
        version = 0L;
      }
      globalVersion.put("version", String.valueOf(version));

      JsonNode capabilitiesNode = globalVersion.get("capabilities");
      if (capabilitiesNode == null || capabilitiesNode.isNull() || capabilitiesNode.asText().trim().isEmpty()) {
        globalVersion.put("capabilities", "0");
      }
      return payloadObject;
    }

    if (paramId == 9) {
      removeOneDictEntry(payloadObject, "mandatoryParams");
      return payloadObject;
    }

    if (paramId == 10) {
      removeOneDictEntry(payloadObject, "criticalParams");
      return payloadObject;
    }

    if (paramId == 29) {
      JsonNode consensusConfigNode = payloadObject.get("consensusConfig");
      if (consensusConfigNode instanceof ObjectNode consensusConfig) {
        long roundCandidates = parseNodeLong(consensusConfig.get("roundCandidates"), 1L);
        if (roundCandidates < 1L) {
          roundCandidates = 1L;
        }
        consensusConfig.put("roundCandidates", String.valueOf(roundCandidates));
      }
      return payloadObject;
    }

    if (paramId == 32) {
      JsonNode param34Response = httpGetJson("/api/config/34");
      JsonNode currValidatorSetNode =
          param34Response.path("param").path("value").path("currValidatorSet");
      if (!isEmptyValue(currValidatorSetNode)) {
        payloadObject.set("prevValidatorSet", currValidatorSetNode.deepCopy());
      }
      enforceValidatorSetRules(payloadObject, "prevValidatorSet");
      return payloadObject;
    }

    if (paramId == 79) {
      JsonNode bridgeNode = payloadObject.get("ethTonTokenBridge");
      ObjectNode bridge;
      if (bridgeNode instanceof ObjectNode objectNode) {
        bridge = objectNode;
      } else {
        bridge = MAPPER.createObjectNode();
        payloadObject.set("ethTonTokenBridge", bridge);
      }

      bridge.put("_type", "JettonBridgeParamsV2");
      ensureBridgeV2Defaults(bridge);
      return payloadObject;
    }

    return payloadObject;
  }

  private void enforceValidatorSetRules(ObjectNode payloadObject, String fieldName) {
    JsonNode validatorSetNode = payloadObject.get(fieldName);
    if (!(validatorSetNode instanceof ObjectNode validatorSet)) {
      return;
    }

    JsonNode listNode = validatorSet.get("list");
    ArrayNode list;
    if (listNode instanceof ArrayNode arrayNode) {
      list = arrayNode;
    } else {
      list = MAPPER.createArrayNode();
      validatorSet.set("list", list);
    }

    if (list.isEmpty()) {
      ObjectNode entry = MAPPER.createObjectNode();
      entry.put("key", "0");

      ObjectNode validatorDescr = MAPPER.createObjectNode();
      validatorDescr.put("_type", "Validator");

      ObjectNode pubKey = MAPPER.createObjectNode();
      pubKey.put("_type", "SigPubKey");
      pubKey.put(
          "pubkey",
          "5555555555555555555555555555555555555555555555555555555555555555");
      validatorDescr.set("publicKey", pubKey);
      validatorDescr.put("weight", "1");

      entry.set("value", validatorDescr);
      list.add(entry);
    }

    long listSize = list.size();
    long total = parseNodeLong(validatorSet.get("total"), listSize > 0 ? listSize : 1L);
    if (total < 1L) {
      total = 1L;
    }
    if (listSize > 0 && total < listSize) {
      total = listSize;
    }

    long main = parseNodeLong(validatorSet.get("main"), 1L);
    if (main < 1L) {
      main = 1L;
    }
    if (main > total) {
      main = total;
    }

    validatorSet.put("total", String.valueOf(total));
    validatorSet.put("main", String.valueOf(main));
  }

  private void ensureBridgeV2Defaults(ObjectNode bridge) {
    ensureTextNumber(bridge, "bridgeAddress", "1");
    ensureTextNumber(bridge, "oracleAddress", "1");
    ensureTextNumber(bridge, "externalChainAddress", "1");
    ensureTextNumber(bridge, "stateFlags", "0");

    JsonNode oraclesNode = bridge.get("oracles");
    ArrayNode oracles;
    if (oraclesNode instanceof ArrayNode arrayNode) {
      oracles = arrayNode;
    } else {
      oracles = MAPPER.createArrayNode();
      bridge.set("oracles", oracles);
    }
    if (oracles.isEmpty()) {
      ObjectNode entry = MAPPER.createObjectNode();
      entry.put("key", "1");
      entry.put("value", "1");
      oracles.add(entry);
    }

    JsonNode pricesNode = bridge.get("prices");
    ObjectNode prices;
    if (pricesNode instanceof ObjectNode objectNode) {
      prices = objectNode;
    } else {
      prices = MAPPER.createObjectNode();
      prices.put("_type", "JettonBridgePrices");
      bridge.set("prices", prices);
    }

    ensureTextNumber(prices, "bridgeBurnFee", "1");
    ensureTextNumber(prices, "bridgeMintFee", "1");
    ensureTextNumber(prices, "walletMinTonsForStorage", "1");
    ensureTextNumber(prices, "walletGasConsumption", "1");
    ensureTextNumber(prices, "minterMinTonsForStorage", "1");
    ensureTextNumber(prices, "discoverGasConsumption", "1");
  }

  private void ensureTextNumber(ObjectNode node, String field, String defaultValue) {
    JsonNode value = node.get(field);
    if (value == null || value.isNull() || value.asText().trim().isEmpty()) {
      node.put(field, defaultValue);
    }
  }

  private void removeOneDictEntry(ObjectNode payloadObject, String fieldName) {
    JsonNode dictNode = payloadObject.get(fieldName);
    if (!(dictNode instanceof ArrayNode dictEntries)) {
      return;
    }
    if (dictEntries.size() <= 1) {
      return;
    }

    int indexToRemove = 0;
    BigInteger maxKey = BigInteger.valueOf(Long.MIN_VALUE);
    for (int i = 0; i < dictEntries.size(); i++) {
      JsonNode entry = dictEntries.get(i);
      BigInteger key = parseNodeBigInteger(entry == null ? null : entry.get("key"));
      if (key.compareTo(maxKey) >= 0) {
        maxKey = key;
        indexToRemove = i;
      }
    }
    dictEntries.remove(indexToRemove);
  }

  private BigInteger parseNodeBigInteger(JsonNode node) {
    if (node == null || node.isNull() || node.isMissingNode()) {
      return BigInteger.ZERO;
    }
    String raw = node.asText().trim();
    if (raw.isEmpty()) {
      return BigInteger.ZERO;
    }
    try {
      return new BigInteger(raw);
    } catch (NumberFormatException ignored) {
      return BigInteger.ZERO;
    }
  }

  private long parseNodeLong(JsonNode node, long fallback) {
    if (node == null || node.isNull() || node.isMissingNode()) {
      return fallback;
    }
    String raw = node.asText().trim();
    if (raw.isEmpty()) {
      return fallback;
    }
    try {
      return Long.parseLong(raw);
    } catch (NumberFormatException ignored) {
      return fallback;
    }
  }
}
