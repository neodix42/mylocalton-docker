package org.ton.mylocaltondocker.adminportal.controller;

import static org.ton.mylocaltondocker.adminportal.controller.StartUpTask.dockerClient;

import com.github.dockerjava.api.model.Container;
import com.github.dockerjava.api.model.ExposedPort;
import com.github.dockerjava.api.model.Ports;
import java.io.File;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/admin")
@Slf4j
public class MyRestController {

  private static final Pattern VALIDATOR_INDEX_PATTERN = Pattern.compile("^validator-(\\d+)$");
  private static final Pattern LITE_CLIENT_SEQNO_PATTERN =
      Pattern.compile("\\(-1,8000000000000000,(\\d+)\\)");
  private static final Pattern LITE_CLIENT_SYNCED_AGO_PATTERN =
      Pattern.compile("created at \\d+ \\(([^)]+ ago)\\)");
  private static final int MAX_VALIDATORS = 5;
  private static final List<TonCenterV3Component> TON_CENTER_V3_COMPONENTS =
      List.of(
          new TonCenterV3Component("run-migrations", "run-migrations", "run-migrations", true),
          new TonCenterV3Component("event-cache", "event-cache", "index-event-cache", false),
          new TonCenterV3Component(
              "event-classifier", "event-classifier", "index-event-classifier", false),
          new TonCenterV3Component("index-api", "index-api", "index-api", false),
          new TonCenterV3Component("index-worker", "index-worker", "index-worker", false),
          new TonCenterV3Component("postgres", "postgres", "index-postgres", false));
  private static final String DEFAULT_SHARED_DATA_VOLUME = "mylocaltondocker_shared-data";
  private static final List<String> KNOWN_AUX_CONTAINER_NAMES =
      List.of(
          "lite-server",
          "explorer-restarter",
          "index-event-cache",
          "index-event-classifier",
          "run-migrations",
          "index-worker",
          "index-postgres");
  private static final List<String> KNOWN_VOLUME_PREFIXES =
      List.of("ton-db-val", "ton_index", "postgres_data");
  private static final List<String> KNOWN_VOLUME_KEYS =
      List.of(
          "shared-data",
          "postgres_data",
          "ton_index_workdir",
          "event_cache",
          "ton-db-val0",
          "ton-db-val1",
          "ton-db-val2",
          "ton-db-val3",
          "ton-db-val4",
          "ton-db-val5");
  private static final List<String> START_OVER_ENV_LINES =
      List.of(
          "TON_BRANCH=latest",
          "NEXT_BLOCK_GENERATION_DELAY=2",
          "HEALTHCHECK_INTERVAL=15s",
          "EXTERNAL_IP=",
          "VALIDATION_PERIOD=1200",
          "MASTERCHAIN_ONLY=false",
          "GENESIS_VERBOSITY=1",
          "VALIDATOR_VERBOSITY=1",
          "EMBEDDED_FILE_HTTP_SERVER=false",
          "EMBEDDED_FILE_HTTP_SERVER_PORT=8888",
          "CUSTOM_PARAMETERS=\"--state-ttl 315360000 --archive-ttl 315360000 -f /usr/share/ton/smartcont/\"",
          "CUSTOM_CONFIG_SMC_URL=",
          "VERSION_CAPABILITIES=11",
          "GLOBAL_ID=-217",
          "MAX_VALIDATORS=1000",
          "MAX_MAIN_VALIDATORS=100",
          "MIN_VALIDATORS=1",
          "MIN_STAKE=1000000",
          "MAX_STAKE=1000000000",
          "MAX_FACTOR=10",
          "MIN_TOTAL_STAKE=10000",
          "ELECTION_START_BEFORE=900",
          "ELECTION_END_BEFORE=300",
          "ELECTION_STAKE_FROZEN=180",
          "ORIGINAL_VALIDATOR_SET_VALID_FOR=120",
          "ACTUAL_MIN_SPLIT=0",
          "MIN_SPLIT=0",
          "MAX_SPLIT=4",
          "CELL_PRICE=100000",
          "CELL_PRICE_MC=1000000",
          "GAS_PRICE=1000",
          "GAS_PRICE_MC=10000",
          "SIMPLE_FAUCET_INITIAL_BALANCE=1000000",
          "HIGHLOAD_FAUCET_INITIAL_BALANCE=1000000",
          "DATA_FAUCET_INITIAL_BALANCE=1000000",
          "VALIDATOR_0_INITIAL_BALANCE=500000000",
          "VALIDATOR_1_INITIAL_BALANCE=500000000",
          "VALIDATOR_2_INITIAL_BALANCE=500000000",
          "VALIDATOR_3_INITIAL_BALANCE=500000000",
          "VALIDATOR_4_INITIAL_BALANCE=500000000",
          "VALIDATOR_5_INITIAL_BALANCE=500000000",
          "BIT_PRICE_PER_SECOND=1",
          "CELL_PRICE_PER_SECOND=500",
          "BIT_PRICE_PER_SECOND_MC=1000",
          "CELL_PRICE_PER_SECOND_MC=500000",
          "CRITICAL_PARAM_MIN_WINS=4",
          "CRITICAL_PARAM_MAX_LOSSES=2",
          "PROTO_VERSION=5",
          "VALIDATORS_MASTERCHAIN_NUM=1",
          "VALIDATORS_PER_SHARD=1",
          "BLOCK_LIMIT_MULTIPLIER=1",
          "BLOCK_SIZE_UNDERLOAD_KB=256",
          "BLOCK_SIZE_SOFT_KB=1024",
          "BLOCK_SIZE_HARD_KB=2048",
          "BLOCK_GAS_LIMIT_UNDERLOAD=2000000",
          "BLOCK_GAS_LIMIT_SOFT=10000000",
          "BLOCK_GAS_LIMIT_HARD=20000000",
          "SPAM_RUN=0",
          "SPAM_CHAINS=10",
          "SPAM_HOPS=65535",
          "SPAM_SPLIT_HOPS=7",
          "SPAM_DURATION_MINUTES=300");
  private static final Map<String, String> START_OVER_ENV_DEFAULTS = createStartOverEnvDefaults();
  private static final Map<String, String> START_OVER_ENV_DESCRIPTIONS = createStartOverEnvDescriptions();

  private static Map<String, String> createStartOverEnvDefaults() {
    Map<String, String> defaults = new LinkedHashMap<>();
    for (String envLine : START_OVER_ENV_LINES) {
      int separatorIndex = envLine.indexOf('=');
      if (separatorIndex <= 0) {
        continue;
      }
      String key = envLine.substring(0, separatorIndex).trim();
      String value = envLine.substring(separatorIndex + 1);
      defaults.put(key, value);
    }
    return defaults;
  }

  private static Map<String, String> createStartOverEnvDescriptions() {
    Map<String, String> descriptions = new LinkedHashMap<>();

    descriptions.put(
        "TON_BRANCH",
        "By default MyLocalTon is built based on the latest TON blockchain code base master branch.\n"
            + "You can set it to testnet in order to run MyLocalTon based on TON testnet code base.\n"
            + "You can set any other branch too, but check if this branch exists in the main repo ton-blockchain/ton.");
    descriptions.put("NEXT_BLOCK_GENERATION_DELAY", "Delay between blocks generation (deprecated). ");
    descriptions.put("HEALTHCHECK_INTERVAL", "Healthcheck interval for service containers.");
    descriptions.put(
        "EXTERNAL_IP",
        "Used to generate external.global.config.json that allows remote users to connect to lite-server via public IP.");
    descriptions.put("VALIDATION_PERIOD", "Validation period.");
    descriptions.put(
        "MASTERCHAIN_ONLY", "If true, only the masterchain (-1 workchain) is generated.");
    descriptions.put(
        "GENESIS_VERBOSITY",
        "Verbosity level for genesis validator-engine. Allowed values: 0, 1, 2, 3, 4.");
    descriptions.put(
        "VALIDATOR_VERBOSITY",
        "Verbosity level for validator validator-engine. Allowed values: 0, 1, 2, 3, 4.");
    descriptions.put(
        "EMBEDDED_FILE_HTTP_SERVER", "Enable embedded HTTP file server inside blockchain containers.");
    descriptions.put("EMBEDDED_FILE_HTTP_SERVER_PORT", "Port for embedded HTTP file server.");
    descriptions.put(
        "CUSTOM_PARAMETERS", "Used to specify validator command line parameters.");
    descriptions.put(
        "CUSTOM_CONFIG_SMC_URL",
        "URL to a plain-text config-code.fif smart-contract that overrides default TON blockchain configuration during genesis creation.");
    descriptions.put("VERSION_CAPABILITIES", "Blockchain version capabilities.");
    descriptions.put(
        "GLOBAL_ID", "Negative value means a test instance of the blockchain.");
    descriptions.put("MAX_VALIDATORS", "Maximum number of validators in this blockchain.");
    descriptions.put(
        "MAX_MAIN_VALIDATORS", "Maximum number of main validators in this blockchain.");
    descriptions.put("MIN_VALIDATORS", "Minimum number of validators in this blockchain.");
    descriptions.put("MIN_STAKE", "Minimum validator stake in TON coins.");
    descriptions.put("MAX_STAKE", "Maximum validator stake in TON coins.");
    descriptions.put(
        "MAX_FACTOR",
        "Ratio between max and min stake used to cap effective stake.");
    descriptions.put(
        "MIN_TOTAL_STAKE", "Minimum total stake required for all validators.");
    descriptions.put(
        "ELECTION_START_BEFORE",
        "Election starts X minutes before validation round ends.");
    descriptions.put(
        "ELECTION_END_BEFORE",
        "Election ends X minutes before validation round ends.");
    descriptions.put(
        "ELECTION_STAKE_FROZEN",
        "Period of time validator stake is frozen after selection.");
    descriptions.put(
        "ORIGINAL_VALIDATOR_SET_VALID_FOR",
        "Period of time original validator set is valid.");
    descriptions.put(
        "ACTUAL_MIN_SPLIT",
        "Config 12: actual number of shardchains basechain can be split to.");
    descriptions.put(
        "MIN_SPLIT",
        "Config 12: initial and minimum number of shardchains basechain can be split to.");
    descriptions.put(
        "MAX_SPLIT", "Config 12: maximum number of shardchains basechain can be split to.");
    descriptions.put("CELL_PRICE", "Cell price in non-masterchain (nano coins).");
    descriptions.put("CELL_PRICE_MC", "Cell price in masterchain (nano coins).");
    descriptions.put("GAS_PRICE", "Gas price in non-masterchain (nano coins).");
    descriptions.put("GAS_PRICE_MC", "Gas price in masterchain (nano coins).");
    descriptions.put(
        "SIMPLE_FAUCET_INITIAL_BALANCE",
        "Initial balance for common faucet based on Wallet V3R2 (faucet.pk).");
    descriptions.put(
        "HIGHLOAD_FAUCET_INITIAL_BALANCE",
        "Initial balance for highload faucet based on Highload Wallet V2 (faucet-highload.pk).");
    descriptions.put(
        "DATA_FAUCET_INITIAL_BALANCE",
        "Initial balance for data highload faucet (data-highload.pk) used by the data container.");
    descriptions.put(
        "VALIDATOR_0_INITIAL_BALANCE",
        "Initial genesis validator wallet balance in TON coins (validator.pk).");
    descriptions.put(
        "VALIDATOR_1_INITIAL_BALANCE",
        "Initial optional validator-1 wallet balance in TON coins (validator-1.pk).");
    descriptions.put(
        "VALIDATOR_2_INITIAL_BALANCE",
        "Initial optional validator-2 wallet balance in TON coins (validator-2.pk).");
    descriptions.put(
        "VALIDATOR_3_INITIAL_BALANCE",
        "Initial optional validator-3 wallet balance in TON coins (validator-3.pk).");
    descriptions.put(
        "VALIDATOR_4_INITIAL_BALANCE",
        "Initial optional validator-4 wallet balance in TON coins (validator-4.pk).");
    descriptions.put(
        "VALIDATOR_5_INITIAL_BALANCE",
        "Initial optional validator-5 wallet balance in TON coins (validator-5.pk).");
    descriptions.put("BIT_PRICE_PER_SECOND", "Bit price per second in nano coins.");
    descriptions.put("CELL_PRICE_PER_SECOND", "Cell price per second in nano coins.");
    descriptions.put(
        "BIT_PRICE_PER_SECOND_MC", "Bit price per second in nano coins in masterchain.");
    descriptions.put(
        "CELL_PRICE_PER_SECOND_MC", "Cell price per second in nano coins in masterchain.");
    descriptions.put(
        "CRITICAL_PARAM_MIN_WINS", "Config voting: minimum wins required for critical parameters.");
    descriptions.put(
        "CRITICAL_PARAM_MAX_LOSSES",
        "Config voting: maximum losses allowed for critical parameters.");
    descriptions.put("PROTO_VERSION", "TON protocol version.");
    descriptions.put(
        "VALIDATORS_MASTERCHAIN_NUM", "Maximum number of validators per masterchain.");
    descriptions.put(
        "VALIDATORS_PER_SHARD",
        "Maximum number of validators that can validate a single shard.");
    descriptions.put(
        "BLOCK_LIMIT_MULTIPLIER",
        "Multiplier applied to block size and gas limit parameters below.");
    descriptions.put("BLOCK_SIZE_UNDERLOAD_KB", "Block size underload limit.");
    descriptions.put("BLOCK_SIZE_SOFT_KB", "Block size soft limit.");
    descriptions.put("BLOCK_SIZE_HARD_KB", "Block size hard limit.");
    descriptions.put("BLOCK_GAS_LIMIT_UNDERLOAD", "Block gas underload limit.");
    descriptions.put("BLOCK_GAS_LIMIT_SOFT", "Block gas soft limit.");
    descriptions.put("BLOCK_GAS_LIMIT_HARD", "Block gas hard limit.");
    descriptions.put(
        "SPAM_RUN", "Enable network spam traffic generation (~250 TPS load).");
    descriptions.put("SPAM_CHAINS", "Number of parallel chains in retranslator.fc.");
    descriptions.put("SPAM_HOPS", "Number of hops to perform in retranslator.fc.");
    descriptions.put("SPAM_SPLIT_HOPS", "Number of splits in retranslator.fc.");
    descriptions.put("SPAM_DURATION_MINUTES", "Duration of spam process after start.");

    for (String envKey : START_OVER_ENV_DEFAULTS.keySet()) {
      descriptions.putIfAbsent(
          envKey,
          "Read about this parameter here: https://github.com/neodix42/mylocalton-docker/wiki/Genesis-setup-parameters");
    }

    return descriptions;
  }

  @GetMapping("/services")
  public ResponseEntity<Map<String, Object>> getServices() {
    if (dockerClient == null) {
      return buildErrorResponse(HttpStatus.SERVICE_UNAVAILABLE, "Docker client is not initialized yet");
    }

    List<Container> containers = getAllContainers();
    List<Map<String, Object>> services =
        Arrays.stream(ManagedService.values())
            .map(service -> createServiceResponse(service, containers))
            .toList();

    Map<String, Object> response = new LinkedHashMap<>();
    response.put("success", true);
    response.put("services", services);

    return ResponseEntity.ok(response);
  }

  @GetMapping("/blockchain-nodes")
  public ResponseEntity<Map<String, Object>> getBlockchainNodes() {
    if (dockerClient == null) {
      return buildErrorResponse(HttpStatus.SERVICE_UNAVAILABLE, "Docker client is not initialized yet");
    }

    List<Container> containers = getAllContainers();
    List<String> nodeNames = getExpectedBlockchainNodes(containers);
    List<Map<String, Object>> nodes =
        nodeNames.stream()
            .map(nodeName -> createBlockchainNodeResponse(nodeName, containers))
            .toList();

    Map<String, Object> response = new LinkedHashMap<>();
    response.put("success", true);
    response.put("nodes", nodes);

    return ResponseEntity.ok(response);
  }

  @GetMapping("/blockchain-nodes/genesis/build-info")
  public ResponseEntity<Map<String, Object>> getGenesisBuildInfo() {
    if (dockerClient == null) {
      return buildErrorResponse(HttpStatus.SERVICE_UNAVAILABLE, "Docker client is not initialized yet");
    }

    try {
      List<Container> containers = getAllContainers();
      Optional<Container> containerOptional = AdminPortalUtils.findContainerByName(containers, "genesis");
      String buildInfo;

      if (containerOptional.isEmpty()) {
        buildInfo = "validator-engine build information: genesis container is not created.";
      } else {
        Container genesisContainer = containerOptional.get();
        if (!isContainerRunning(genesisContainer.getId())) {
          buildInfo = "validator-engine build information: genesis container is not running.";
        } else {
          String commandOutput =
              runCommandCapture(
                  List.of("docker", "exec", genesisContainer.getId(), "validator-engine", "-V"),
                  getComposeProjectDir());
          buildInfo =
              commandOutput == null || commandOutput.isBlank()
                  ? "validator-engine build information: unavailable."
                  : commandOutput.trim();
        }
      }

      Map<String, Object> response = new LinkedHashMap<>();
      response.put("success", true);
      response.put("buildInfo", buildInfo);
      return ResponseEntity.ok(response);
    } catch (Exception e) {
      log.error("Failed to fetch genesis validator-engine build information", e);
      return buildErrorResponse(
          HttpStatus.INTERNAL_SERVER_ERROR,
          "Failed to fetch validator-engine build information: " + e.getMessage());
    }
  }

  @GetMapping("/blockchain-nodes/genesis/latest-seqno")
  public ResponseEntity<Map<String, Object>> getGenesisLatestSeqno() {
    if (dockerClient == null) {
      return buildErrorResponse(HttpStatus.SERVICE_UNAVAILABLE, "Docker client is not initialized yet");
    }

    Map<String, Object> response = new LinkedHashMap<>();
    response.put("success", true);

    try {
      List<Container> containers = getAllContainers();
      Optional<Container> containerOptional = AdminPortalUtils.findContainerByName(containers, "genesis");
      if (containerOptional.isEmpty()) {
        response.put("available", false);
        return ResponseEntity.ok(response);
      }

      Container genesisContainer = containerOptional.get();
      if (!isContainerRunning(genesisContainer.getId())) {
        response.put("available", false);
        return ResponseEntity.ok(response);
      }

      ParsedSeqnoSync parsed = fetchLatestSeqnoWithRetry(genesisContainer.getId());
      if (parsed == null) {
        response.put("available", false);
        return ResponseEntity.ok(response);
      }

      response.put("available", true);
      response.put("seqno", parsed.seqno());
      response.put("syncedAgo", parsed.syncedAgo());
      response.put("subtitle", "Latest seqno " + parsed.seqno() + ", synced " + parsed.syncedAgo());
      return ResponseEntity.ok(response);
    } catch (Exception e) {
      log.warn("Failed to fetch latest seqno from genesis: {}", e.getMessage());
      response.put("available", false);
      return ResponseEntity.ok(response);
    }
  }

  @PostMapping("/blockchain-nodes/add-validator")
  public ResponseEntity<Map<String, Object>> addValidatorNode() {
    if (dockerClient == null) {
      return buildErrorResponse(HttpStatus.SERVICE_UNAVAILABLE, "Docker client is not initialized yet");
    }

    try {
      List<Container> containers = getAllContainers();
      if (!isNodeRunning("genesis", containers)) {
        return buildErrorResponse(HttpStatus.BAD_REQUEST, "Genesis must be running before adding validators");
      }

      int runningValidators = countRunningValidators(containers);
      int nextValidatorIndex = runningValidators + 1;

      if (nextValidatorIndex > MAX_VALIDATORS) {
        return buildErrorResponse(
            HttpStatus.BAD_REQUEST, "Maximum number of validators reached (" + MAX_VALIDATORS + ")");
      }

      String validatorName = "validator-" + nextValidatorIndex;
      String validatorProfile = "validators-" + nextValidatorIndex;

      runComposeCommand(
          getComposeProjectDir(), validatorProfile, List.of("up", "-d", "--no-deps", validatorName));

      Map<String, Object> response = new LinkedHashMap<>();
      response.put("success", true);
      response.put("message", "Validator added: " + validatorName);
      response.put("validator", validatorName);
      return ResponseEntity.ok(response);
    } catch (Exception e) {
      log.error("Failed to add validator node", e);
      return buildErrorResponse(HttpStatus.INTERNAL_SERVER_ERROR, "Failed to add validator: " + e.getMessage());
    }
  }

  @PostMapping("/blockchain-nodes/{nodeId}/remove-validator")
  public ResponseEntity<Map<String, Object>> removeValidatorNode(@PathVariable("nodeId") String nodeId) {
    if (dockerClient == null) {
      return buildErrorResponse(HttpStatus.SERVICE_UNAVAILABLE, "Docker client is not initialized yet");
    }

    if ("genesis".equals(nodeId)) {
      try {
        runComposeCommand(getComposeProjectDir(), null, List.of("stop", nodeId));

        List<Container> containers = getAllContainers();
        Optional<Container> containerOptional = AdminPortalUtils.findContainerByName(containers, nodeId);
        if (containerOptional.isPresent()) {
          try {
            if (isContainerRunning(containerOptional.get().getId())) {
              dockerClient.stopContainerCmd(containerOptional.get().getId()).withTimeout(10).exec();
            }
          } catch (Exception stopFallbackError) {
            log.debug("Genesis fallback stop was not required or container changed", stopFallbackError);
          }
        }

        Map<String, Object> response = new LinkedHashMap<>();
        response.put("success", true);
        response.put("message", "Genesis stopped");
        response.put("nodeId", nodeId);
        return ResponseEntity.ok(response);
      } catch (Exception e) {
        log.error("Failed to stop genesis", e);
        return buildErrorResponse(
            HttpStatus.INTERNAL_SERVER_ERROR, "Failed to stop genesis: " + e.getMessage());
      }
    }

    Matcher validatorMatcher = VALIDATOR_INDEX_PATTERN.matcher(nodeId);
    if (!validatorMatcher.matches()) {
      return buildErrorResponse(HttpStatus.BAD_REQUEST, "Only validator nodes can be removed");
    }

    int validatorIndex;
    try {
      validatorIndex = Integer.parseInt(validatorMatcher.group(1));
    } catch (Exception e) {
      return buildErrorResponse(HttpStatus.BAD_REQUEST, "Invalid validator id: " + nodeId);
    }

    if (validatorIndex < 1 || validatorIndex > MAX_VALIDATORS) {
      return buildErrorResponse(HttpStatus.BAD_REQUEST, "Validator id out of range: " + nodeId);
    }

    String profile = "validators-" + validatorIndex;

    try {
      runComposeCommand(getComposeProjectDir(), profile, List.of("stop", nodeId));

      // Fallback direct stop if compose command did not stop an existing running container.
      List<Container> containers = getAllContainers();
      Optional<Container> containerOptional = AdminPortalUtils.findContainerByName(containers, nodeId);
      if (containerOptional.isPresent()) {
        try {
          if (isContainerRunning(containerOptional.get().getId())) {
            dockerClient.stopContainerCmd(containerOptional.get().getId()).withTimeout(10).exec();
          }
        } catch (Exception stopFallbackError) {
          log.debug("Validator fallback stop was not required or container changed: {}", nodeId, stopFallbackError);
        }
      }

      Map<String, Object> response = new LinkedHashMap<>();
      response.put("success", true);
      response.put("message", "Validator stopped: " + nodeId);
      response.put("validator", nodeId);
      return ResponseEntity.ok(response);
    } catch (Exception e) {
      log.error("Failed to remove validator {}", nodeId, e);
      return buildErrorResponse(
          HttpStatus.INTERNAL_SERVER_ERROR, "Failed to stop validator " + nodeId + ": " + e.getMessage());
    }
  }

  @PostMapping("/blockchain-nodes/{nodeId}/start-validator")
  public ResponseEntity<Map<String, Object>> startValidatorNode(@PathVariable("nodeId") String nodeId) {
    if (dockerClient == null) {
      return buildErrorResponse(HttpStatus.SERVICE_UNAVAILABLE, "Docker client is not initialized yet");
    }

    if ("genesis".equals(nodeId)) {
      try {
        if (startExistingContainerIfPresent(nodeId)) {
          Map<String, Object> response = new LinkedHashMap<>();
          response.put("success", true);
          response.put("message", "Genesis started");
          response.put("nodeId", nodeId);
          return ResponseEntity.ok(response);
        }

        runComposeCommand(getComposeProjectDir(), null, List.of("up", "-d", "--no-deps", nodeId));

        Map<String, Object> response = new LinkedHashMap<>();
        response.put("success", true);
        response.put("message", "Genesis started");
        response.put("nodeId", nodeId);
        return ResponseEntity.ok(response);
      } catch (Exception e) {
        log.error("Failed to start genesis", e);
        return buildErrorResponse(
            HttpStatus.INTERNAL_SERVER_ERROR, "Failed to start genesis: " + e.getMessage());
      }
    }

    Matcher validatorMatcher = VALIDATOR_INDEX_PATTERN.matcher(nodeId);
    if (!validatorMatcher.matches()) {
      return buildErrorResponse(HttpStatus.BAD_REQUEST, "Only validator nodes can be started");
    }

    int validatorIndex;
    try {
      validatorIndex = Integer.parseInt(validatorMatcher.group(1));
    } catch (Exception e) {
      return buildErrorResponse(HttpStatus.BAD_REQUEST, "Invalid validator id: " + nodeId);
    }

    if (validatorIndex < 1 || validatorIndex > MAX_VALIDATORS) {
      return buildErrorResponse(HttpStatus.BAD_REQUEST, "Validator id out of range: " + nodeId);
    }

    String profile = "validators-" + validatorIndex;

    try {
      if (startExistingContainerIfPresent(nodeId)) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("success", true);
        response.put("message", "Validator started: " + nodeId);
        response.put("validator", nodeId);
        return ResponseEntity.ok(response);
      }

      runComposeCommand(getComposeProjectDir(), profile, List.of("up", "-d", "--no-deps", nodeId));

      Map<String, Object> response = new LinkedHashMap<>();
      response.put("success", true);
      response.put("message", "Validator started: " + nodeId);
      response.put("validator", nodeId);
      return ResponseEntity.ok(response);
    } catch (Exception e) {
      log.error("Failed to start validator {}", nodeId, e);
      return buildErrorResponse(
          HttpStatus.INTERNAL_SERVER_ERROR, "Failed to start validator " + nodeId + ": " + e.getMessage());
    }
  }

  @GetMapping("/blockchain-nodes/{nodeId}/logs")
  public ResponseEntity<Map<String, Object>> getBlockchainNodeLogs(
      @PathVariable("nodeId") String nodeId, @RequestParam(value = "lines", required = false) Integer lines) {
    if (dockerClient == null) {
      return buildErrorResponse(HttpStatus.SERVICE_UNAVAILABLE, "Docker client is not initialized yet");
    }

    if (!isSupportedBlockchainNodeId(nodeId)) {
      return buildErrorResponse(HttpStatus.BAD_REQUEST, "Unsupported blockchain node id: " + nodeId);
    }

    List<Container> containers = getAllContainers();
    Optional<Container> containerOptional = AdminPortalUtils.findContainerByName(containers, nodeId);
    if (containerOptional.isEmpty()) {
      return buildErrorResponse(HttpStatus.NOT_FOUND, "Container not created: " + nodeId);
    }

    try {
      int linesToLoad = lines == null ? 100 : Math.max(1, Math.min(lines, 10000));
      String logs = getContainerLogs(containerOptional.get().getId(), linesToLoad);

      Map<String, Object> response = new LinkedHashMap<>();
      response.put("success", true);
      response.put("nodeId", nodeId);
      response.put("lines", linesToLoad);
      response.put("logs", logs);
      return ResponseEntity.ok(response);
    } catch (Exception e) {
      log.error("Failed to fetch logs for node {}", nodeId, e);
      return buildErrorResponse(
          HttpStatus.INTERNAL_SERVER_ERROR, "Failed to fetch logs for " + nodeId + ": " + e.getMessage());
    }
  }

  @PostMapping("/blockchain-nodes/{nodeId}/restart")
  public ResponseEntity<Map<String, Object>> restartBlockchainNode(@PathVariable("nodeId") String nodeId) {
    if (dockerClient == null) {
      return buildErrorResponse(HttpStatus.SERVICE_UNAVAILABLE, "Docker client is not initialized yet");
    }

    if (!isSupportedBlockchainNodeId(nodeId)) {
      return buildErrorResponse(HttpStatus.BAD_REQUEST, "Unsupported blockchain node id: " + nodeId);
    }

    try {
      restartBlockchainNodeViaCompose(nodeId);

      List<Container> refreshedContainers = getAllContainers();
      Map<String, Object> response = new LinkedHashMap<>();
      response.put("success", true);
      response.put("message", "Node restarted: " + nodeId);
      response.put("node", createBlockchainNodeResponse(nodeId, refreshedContainers));
      return ResponseEntity.ok(response);
    } catch (Exception e) {
      log.error("Failed to restart blockchain node {}", nodeId, e);
      return buildErrorResponse(
          HttpStatus.INTERNAL_SERVER_ERROR, "Failed to restart node " + nodeId + ": " + e.getMessage());
    }
  }

  @PostMapping("/blockchain-nodes/cleanup")
  public ResponseEntity<Map<String, Object>> cleanupBlockchainEnvironment() {
    if (dockerClient == null) {
      return buildErrorResponse(HttpStatus.SERVICE_UNAVAILABLE, "Docker client is not initialized yet");
    }

    List<String> warnings = new ArrayList<>();
    String projectDir = getComposeProjectDir();

    cleanupComposeServicesExceptAdmin(projectDir, warnings);

    forceRemoveKnownContainers(warnings);
    forceRemoveKnownVolumes(warnings);

    Map<String, Object> response = new LinkedHashMap<>();
    response.put("success", true);
    response.put("warnings", warnings);
    if (warnings.isEmpty()) {
      response.put("message", "Cleanup finished");
    } else {
      response.put("message", "Cleanup finished with warnings");
    }
    return ResponseEntity.ok(response);
  }

  @GetMapping("/blockchain-nodes/start-over/variables")
  public ResponseEntity<Map<String, Object>> getStartOverVariables() {
    if (dockerClient == null) {
      return buildErrorResponse(HttpStatus.SERVICE_UNAVAILABLE, "Docker client is not initialized yet");
    }

    try {
      Map<String, String> envValues = readEnvFileValues(getEnvFilePath(getComposeProjectDir()));
      List<Map<String, Object>> variables = new ArrayList<>();
      for (Map.Entry<String, String> entry : START_OVER_ENV_DEFAULTS.entrySet()) {
        Map<String, Object> variable = new LinkedHashMap<>();
        variable.put("name", entry.getKey());
        String envValue = envValues.get(entry.getKey());
        variable.put("value", envValue == null || envValue.isBlank() ? entry.getValue() : envValue);
        variable.put(
            "description",
            START_OVER_ENV_DESCRIPTIONS.getOrDefault(
                entry.getKey(),
                "Read about this parameter here: https://github.com/neodix42/mylocalton-docker/wiki/Genesis-setup-parameters"));
        variables.add(variable);
      }

      Map<String, Object> response = new LinkedHashMap<>();
      response.put("success", true);
      response.put("variables", variables);
      return ResponseEntity.ok(response);
    } catch (Exception e) {
      log.error("Failed to load start-over variables", e);
      return buildErrorResponse(
          HttpStatus.INTERNAL_SERVER_ERROR,
          "Failed to load start-over variables: " + e.getMessage());
    }
  }

  @PostMapping("/blockchain-nodes/start-over")
  public ResponseEntity<Map<String, Object>> startOverBlockchain(
      @RequestBody(required = false) Map<String, String> inputValues) {
    if (dockerClient == null) {
      return buildErrorResponse(HttpStatus.SERVICE_UNAVAILABLE, "Docker client is not initialized yet");
    }

    String projectDir = getComposeProjectDir();
    List<String> warnings = new ArrayList<>();

    try {
      Map<String, String> valuesToApply = mergeStartOverValues(inputValues);
      List<String> relaunchServices = resolveServicesForStartOverRelaunch(projectDir);

      writeEnvFileValues(getEnvFilePath(projectDir), valuesToApply);
      cleanupComposeServicesExceptAdmin(projectDir, warnings);
      forceRemoveKnownContainers(warnings);
      forceRemoveKnownVolumes(warnings);
      relaunchServicesAfterStartOver(projectDir, relaunchServices);

      Map<String, Object> response = new LinkedHashMap<>();
      response.put("success", true);
      response.put("warnings", warnings);
      response.put("message", warnings.isEmpty() ? "Start over finished" : "Start over finished with warnings");
      response.put("services", relaunchServices);
      return ResponseEntity.ok(response);
    } catch (Exception e) {
      log.error("Failed to start over blockchain", e);
      return buildErrorResponse(
          HttpStatus.INTERNAL_SERVER_ERROR, "Failed to start over blockchain: " + e.getMessage());
    }
  }

  @PostMapping("/services/{serviceId}/start")
  public ResponseEntity<Map<String, Object>> startService(
      @PathVariable("serviceId") String serviceId) {
    return changeServiceState(serviceId, true);
  }

  @PostMapping("/services/{serviceId}/stop")
  public ResponseEntity<Map<String, Object>> stopService(@PathVariable("serviceId") String serviceId) {
    return changeServiceState(serviceId, false);
  }

  private ResponseEntity<Map<String, Object>> changeServiceState(String serviceId, boolean start) {
    if (dockerClient == null) {
      return buildErrorResponse(HttpStatus.SERVICE_UNAVAILABLE, "Docker client is not initialized yet");
    }

    ManagedService service = ManagedService.fromId(serviceId);
    if (service == null) {
      return buildErrorResponse(HttpStatus.NOT_FOUND, "Unknown service id: " + serviceId);
    }

    try {
      if (ManagedService.TON_CENTER_V3.equals(service)) {
        return changeTonCenterV3StackState(start);
      }

      List<Container> containers = getAllContainers();
      Optional<Container> containerOptional =
          AdminPortalUtils.findContainerByName(containers, service.getContainerName());

      if (containerOptional.isEmpty()) {
        if (!start) {
          return buildActionResponse(service, "Service is already stopped");
        }

        startMissingServiceViaCompose(service);
        return buildActionResponse(service, "Service started via docker compose");
      }

      String containerId = containerOptional.get().getId();
      boolean running = isContainerRunning(containerId);

      if (start) {
        if (running) {
          int hostPort = resolveHostPort(service, containerId);
          if (isEndpointHealthy(service, hostPort)) {
            return buildActionResponse(service, "Service is already running");
          }

          dockerClient.stopContainerCmd(containerId).withTimeout(10).exec();
          dockerClient.startContainerCmd(containerId).exec();
          return buildActionResponse(service, "Service endpoint was down, container restarted");
        }

        dockerClient.startContainerCmd(containerId).exec();
        return buildActionResponse(service, "Service started");
      }

      if (!running) {
        return buildActionResponse(service, "Service is already stopped");
      }

      dockerClient.stopContainerCmd(containerId).withTimeout(10).exec();
      return buildActionResponse(service, "Service stopped");

    } catch (Exception e) {
      log.error("Failed to change state for {}", service.getContainerName(), e);
      return buildErrorResponse(
          HttpStatus.INTERNAL_SERVER_ERROR,
          "Failed to "
              + (start ? "start" : "stop")
              + " service "
              + service.getName()
              + ": "
              + e.getMessage());
    }
  }

  private ResponseEntity<Map<String, Object>> changeTonCenterV3StackState(boolean start) {
    if (start) {
      startTonCenterV3Stack();
    } else {
      stopTonCenterV3Stack();
    }
    return buildActionResponse(
        ManagedService.TON_CENTER_V3,
        start ? "TON Center V3 stack started" : "TON Center V3 stack stopped");
  }

  private void startTonCenterV3Stack() {
    List<String> failures = new ArrayList<>();
    for (TonCenterV3Component component : TON_CENTER_V3_COMPONENTS) {
      startTonCenterV3Component(component, failures);
    }
    if (!failures.isEmpty()) {
      throw new IllegalStateException(String.join("; ", failures));
    }
  }

  private void stopTonCenterV3Stack() {
    for (TonCenterV3Component component : TON_CENTER_V3_COMPONENTS) {
      stopTonCenterV3Component(component);
    }
  }

  private void startTonCenterV3Component(
      TonCenterV3Component component, List<String> failures) {
    Optional<Container> containerOptional =
        AdminPortalUtils.findContainerByName(getAllContainers(), component.containerName());
    if (containerOptional.isPresent()) {
      String containerId = containerOptional.get().getId();
      if (isContainerRunning(containerId)) {
        return;
      }
      try {
        dockerClient.startContainerCmd(containerId).exec();
      } catch (Exception e) {
        failures.add("Failed to start " + component.displayName() + ": " + e.getMessage());
      }
      return;
    }

    try {
      runComposeCommand(
          getComposeProjectDir(),
          "indexer",
          List.of("up", "-d", "--no-deps", component.composeService()));
    } catch (Exception e) {
      if (component.optionalIfMissing()) {
        log.warn(
            "TON Center V3 component {} is optional and could not be started: {}",
            component.displayName(),
            e.getMessage());
        return;
      }
      failures.add(
          "Failed to start "
              + component.displayName()
              + " (container and compose fallback): "
              + e.getMessage());
    }
  }

  private void stopTonCenterV3Component(TonCenterV3Component component) {
    Optional<Container> containerOptional =
        AdminPortalUtils.findContainerByName(getAllContainers(), component.containerName());
    if (containerOptional.isPresent()) {
      String containerId = containerOptional.get().getId();
      if (!isContainerRunning(containerId)) {
        return;
      }
      try {
        dockerClient.stopContainerCmd(containerId).withTimeout(10).exec();
      } catch (Exception e) {
        log.warn("Failed to stop {} fallback container", component.containerName(), e);
      }
      return;
    }

    try {
      runComposeCommand(getComposeProjectDir(), "indexer", List.of("stop", component.composeService()));
    } catch (Exception e) {
      log.warn(
          "Failed to stop TON Center V3 component {} via compose fallback",
          component.composeService(),
          e);
    }
  }

  private void startMissingServiceViaCompose(ManagedService service) {
    runComposeCommand(getComposeProjectDir(), null, List.of("up", "-d", service.getComposeService()));
  }

  private void runComposeCommand(
      String projectDir, String profile, List<String> composeArgs) {
    runComposeCommand(projectDir, profile, composeArgs, Map.of());
  }

  private void runComposeCommand(
      String projectDir, String profile, List<String> composeArgs, Map<String, String> envOverrides) {
    String composeFile = projectDir + "/docker-compose.yaml";
    String projectName = getComposeProjectName();

    List<String> command =
        new ArrayList<>(List.of("docker", "compose", "-p", projectName, "-f", composeFile));
    if (profile != null && !profile.isBlank()) {
      command.add("--profile");
      command.add(profile);
    }
    command.addAll(composeArgs);

    try {
      runCommand(command, projectDir, envOverrides);
    } catch (Exception e) {
      throw new IllegalStateException(
          "Compose command failed: "
              + String.join(" ", composeArgs)
              + ", profile="
              + (profile == null ? "<none>" : profile)
              + ", project="
              + projectName
              + ". "
              + e.getMessage());
    }
  }

  private void runCommand(List<String> command, String workDir) throws Exception {
    runCommand(command, workDir, Map.of());
  }

  private void runCommand(List<String> command, String workDir, Map<String, String> envOverrides)
      throws Exception {
    String output = runCommandCapture(command, workDir, envOverrides);
    if (output != null && !output.isBlank()) {
      log.info("Command output: {}", output);
    }
  }

  private String runCommandCapture(List<String> command, String workDir) throws Exception {
    return runCommandCapture(command, workDir, Map.of());
  }

  private String runCommandCapture(
      List<String> command, String workDir, Map<String, String> envOverrides) throws Exception {
    CommandResult result = runCommandCaptureAllowFailure(command, workDir, envOverrides);
    if (result.exitCode() != 0) {
      throw new IllegalStateException(
          "command failed ("
              + result.exitCode()
              + "): "
              + String.join(" ", command)
              + (result.output() == null || result.output().isBlank() ? "" : "\n" + result.output()));
    }
    return result.output();
  }

  private CommandResult runCommandCaptureAllowFailure(
      List<String> command, String workDir, Map<String, String> envOverrides) throws Exception {
    ProcessBuilder processBuilder = new ProcessBuilder(command);
    processBuilder.directory(new File(workDir));
    processBuilder.redirectErrorStream(true);
    if (envOverrides != null && !envOverrides.isEmpty()) {
      processBuilder.environment().putAll(envOverrides);
    }

    Process process = processBuilder.start();
    String output;

    try (InputStream inputStream = process.getInputStream()) {
      output = new String(inputStream.readAllBytes(), StandardCharsets.UTF_8);
    }

    int exitCode = process.waitFor();
    return new CommandResult(exitCode, output);
  }

  private String getComposeProjectDir() {
    String envValue = System.getenv("COMPOSE_PROJECT_DIR");
    if (envValue == null || envValue.isBlank()) {
      return "/workspace";
    }
    return envValue;
  }

  private String getComposeProjectName() {
    String envValue = System.getenv("COMPOSE_PROJECT_NAME");
    if (envValue == null || envValue.isBlank()) {
      return "mylocaltondocker";
    }
    return envValue;
  }

  private Path getEnvFilePath(String projectDir) {
    return Path.of(projectDir, ".env");
  }

  private Map<String, String> readEnvFileValues(Path envFile) throws Exception {
    Map<String, String> values = new LinkedHashMap<>();
    if (!Files.exists(envFile)) {
      return values;
    }

    List<String> lines = Files.readAllLines(envFile, StandardCharsets.UTF_8);
    for (String line : lines) {
      String trimmed = line.trim();
      if (trimmed.isEmpty() || trimmed.startsWith("#")) {
        continue;
      }
      int separatorIndex = line.indexOf('=');
      if (separatorIndex <= 0) {
        continue;
      }
      String key = line.substring(0, separatorIndex).trim();
      String value = line.substring(separatorIndex + 1);
      values.put(key, value);
    }
    return values;
  }

  private void writeEnvFileValues(Path envFile, Map<String, String> newValues) throws Exception {
    List<String> existingLines =
        Files.exists(envFile)
            ? new ArrayList<>(Files.readAllLines(envFile, StandardCharsets.UTF_8))
            : new ArrayList<>();
    Set<String> remainingKeys = new LinkedHashSet<>(newValues.keySet());
    List<String> updatedLines = new ArrayList<>();

    for (String line : existingLines) {
      int separatorIndex = line.indexOf('=');
      if (separatorIndex <= 0) {
        updatedLines.add(line);
        continue;
      }

      String key = line.substring(0, separatorIndex).trim();
      if (!newValues.containsKey(key)) {
        updatedLines.add(line);
        continue;
      }

      updatedLines.add(key + "=" + Optional.ofNullable(newValues.get(key)).orElse(""));
      remainingKeys.remove(key);
    }

    if (!remainingKeys.isEmpty()) {
      if (!updatedLines.isEmpty() && !updatedLines.get(updatedLines.size() - 1).isBlank()) {
        updatedLines.add("");
      }
      for (String key : remainingKeys) {
        updatedLines.add(key + "=" + Optional.ofNullable(newValues.get(key)).orElse(""));
      }
    }

    Files.write(envFile, updatedLines, StandardCharsets.UTF_8);
  }

  private Map<String, String> mergeStartOverValues(Map<String, String> inputValues) {
    Map<String, String> values = new LinkedHashMap<>();
    for (Map.Entry<String, String> entry : START_OVER_ENV_DEFAULTS.entrySet()) {
      String key = entry.getKey();
      String defaultValue = entry.getValue();
      String value = inputValues == null ? null : inputValues.get(key);
      values.put(key, value == null ? defaultValue : value);
    }
    return values;
  }

  private List<String> resolveServicesForStartOverRelaunch(String projectDir) {
    Set<String> allowedServices = new LinkedHashSet<>();
    try {
      allowedServices.addAll(getComposeServiceNames(projectDir));
    } catch (Exception e) {
      log.warn("Failed to resolve compose service names for start-over relaunch", e);
    }

    Set<String> selectedServices = new LinkedHashSet<>();
    for (Container container : getAllContainers()) {
      if (isAdminPortalContainer(container)) {
        continue;
      }

      String serviceName = null;
      Map<String, String> labels = container.getLabels();
      if (labels != null) {
        serviceName = labels.get("com.docker.compose.service");
      }
      if (serviceName == null || serviceName.isBlank()) {
        serviceName = mapContainerNameToComposeService(extractManagedName(container));
      }
      if (serviceName == null || serviceName.isBlank()) {
        continue;
      }
      if (!allowedServices.isEmpty() && !allowedServices.contains(serviceName)) {
        continue;
      }
      if ("admin-portal".equals(serviceName)) {
        continue;
      }
      selectedServices.add(serviceName);
    }

    if (selectedServices.isEmpty()) {
      selectedServices.add("genesis");
    }

    return new ArrayList<>(selectedServices);
  }

  private String mapContainerNameToComposeService(String containerName) {
    if (containerName == null || containerName.isBlank()) {
      return null;
    }

    for (ManagedService service : ManagedService.values()) {
      if (service.getContainerName().equals(containerName)) {
        return service.getComposeService();
      }
    }

    return switch (containerName) {
      case "index-event-cache" -> "event-cache";
      case "index-event-classifier" -> "event-classifier";
      case "index-postgres" -> "postgres";
      default -> containerName;
    };
  }

  private void relaunchServicesAfterStartOver(String projectDir, List<String> services) {
    if (services == null || services.isEmpty()) {
      return;
    }

    List<String> composeArgs = new ArrayList<>(List.of("up", "-d"));
    composeArgs.addAll(services);
    runComposeCommand(projectDir, null, composeArgs);
  }

  private ResponseEntity<Map<String, Object>> buildActionResponse(ManagedService service, String message) {
    List<Container> refreshedContainers = getAllContainers();

    Map<String, Object> response = new LinkedHashMap<>();
    response.put("success", true);
    response.put("message", message);
    response.put("service", createServiceResponse(service, refreshedContainers));

    return ResponseEntity.ok(response);
  }

  private List<Container> getAllContainers() {
    return dockerClient.listContainersCmd().withShowAll(true).exec();
  }

  private boolean isNodeRunning(String nodeName, List<Container> containers) {
    Optional<Container> containerOptional = AdminPortalUtils.findContainerByName(containers, nodeName);
    return containerOptional.isPresent() && isContainerRunning(containerOptional.get().getId());
  }

  private boolean startExistingContainerIfPresent(String nodeName) {
    List<Container> containers = getAllContainers();
    Optional<Container> containerOptional = AdminPortalUtils.findContainerByName(containers, nodeName);
    if (containerOptional.isEmpty()) {
      return false;
    }

    Container container = containerOptional.get();
    if (!isContainerRunning(container.getId())) {
      dockerClient.startContainerCmd(container.getId()).exec();
    }
    return true;
  }

  private int countRunningValidators(List<Container> containers) {
    int runningCount = 0;
    for (Container container : containers) {
      String containerName = extractManagedName(container);
      Matcher matcher = VALIDATOR_INDEX_PATTERN.matcher(containerName);
      if (!matcher.matches()) {
        continue;
      }
      if (isContainerRunning(container.getId())) {
        runningCount++;
      }
    }
    return runningCount;
  }

  private void forceRemoveKnownContainers(List<String> warnings) {
    String projectName = getComposeProjectName();
    List<Container> containers = getAllContainers();

    Set<String> targetNames = new LinkedHashSet<>();
    for (ManagedService service : ManagedService.values()) {
      targetNames.add(service.getContainerName());
    }
    targetNames.addAll(KNOWN_AUX_CONTAINER_NAMES);
    targetNames.add("genesis");
    for (int i = 1; i <= MAX_VALIDATORS; i++) {
      targetNames.add("validator-" + i);
    }

    for (Container container : containers) {
      Map<String, String> labels = container.getLabels();
      if (labels != null && projectName.equals(labels.get("com.docker.compose.project"))) {
        String containerName = extractManagedName(container);
        if (!containerName.isBlank()) {
          targetNames.add(containerName);
        }
      }
    }

    for (String targetName : targetNames) {
      try {
        List<Container> refreshed = getAllContainers();
        Optional<Container> containerOptional = AdminPortalUtils.findContainerByName(refreshed, targetName);
        if (containerOptional.isEmpty()) {
          continue;
        }
        Container container = containerOptional.get();
        if (isAdminPortalContainer(container)) {
          // Keep the admin panel alive to return cleanup status to UI.
          continue;
        }
        dockerClient
            .removeContainerCmd(container.getId())
            .withForce(true)
            .withRemoveVolumes(true)
            .exec();
      } catch (Exception e) {
        String warning = "Failed to remove container " + targetName + ": " + e.getMessage();
        warnings.add(warning);
        log.warn(warning, e);
      }
    }
  }

  private void cleanupComposeServicesExceptAdmin(String projectDir, List<String> warnings) {
    List<String> composeServices;
    try {
      composeServices = new ArrayList<>(getComposeServiceNames(projectDir));
    } catch (Exception e) {
      String warning = "Failed to read compose services: " + e.getMessage();
      warnings.add(warning);
      log.warn(warning, e);
      return;
    }

    composeServices.removeIf("admin-portal"::equals);
    if (composeServices.isEmpty()) {
      return;
    }

    List<String> stopArgs = new ArrayList<>();
    stopArgs.add("stop");
    stopArgs.addAll(composeServices);
    try {
      runComposeCommand(projectDir, null, stopArgs);
    } catch (Exception e) {
      String warning = "Failed to stop compose services: " + e.getMessage();
      warnings.add(warning);
      log.warn(warning, e);
    }

    List<String> removeArgs = new ArrayList<>(List.of("rm", "-f", "-s", "-v"));
    removeArgs.addAll(composeServices);
    try {
      runComposeCommand(projectDir, null, removeArgs);
    } catch (Exception e) {
      String warning = "Failed to remove compose services: " + e.getMessage();
      warnings.add(warning);
      log.warn(warning, e);
    }
  }

  private List<String> getComposeServiceNames(String projectDir) throws Exception {
    String composeFile = projectDir + "/docker-compose.yaml";
    String projectName = getComposeProjectName();
    String output =
        runCommandCapture(
            List.of(
                "docker",
                "compose",
                "-p",
                projectName,
                "-f",
                composeFile,
                "config",
                "--services"),
            projectDir);

    if (output == null || output.isBlank()) {
      return List.of();
    }

    return Arrays.stream(output.split("\\R"))
        .map(String::trim)
        .filter(name -> !name.isBlank())
        .toList();
  }

  private void forceRemoveKnownVolumes(List<String> warnings) {
    String projectName = getComposeProjectName();
    String projectDir = getComposeProjectDir();

    Set<String> volumeNames = new LinkedHashSet<>();
    volumeNames.add(DEFAULT_SHARED_DATA_VOLUME);
    for (String volumeKey : KNOWN_VOLUME_KEYS) {
      volumeNames.add(projectName + "_" + volumeKey);
      volumeNames.add(volumeKey);
    }

    try {
      String byLabel =
          runCommandCapture(
              List.of(
                  "sh",
                  "-lc",
                  "docker volume ls -q --filter label=com.docker.compose.project="
                      + escapeForShell(projectName)),
              projectDir);
      if (byLabel != null && !byLabel.isBlank()) {
        Arrays.stream(byLabel.split("\\R"))
            .map(String::trim)
            .filter(name -> !name.isBlank())
            .forEach(volumeNames::add);
      }
    } catch (Exception e) {
      String warning = "Failed to list project volumes: " + e.getMessage();
      warnings.add(warning);
      log.warn(warning, e);
    }

    try {
      String allVolumes = runCommandCapture(List.of("docker", "volume", "ls", "-q"), projectDir);
      if (allVolumes != null && !allVolumes.isBlank()) {
        Arrays.stream(allVolumes.split("\\R"))
            .map(String::trim)
            .filter(name -> !name.isBlank())
            .filter(this::hasKnownVolumePrefix)
            .forEach(volumeNames::add);
      }
    } catch (Exception e) {
      String warning = "Failed to list all docker volumes: " + e.getMessage();
      warnings.add(warning);
      log.warn(warning, e);
    }

    for (String volumeName : volumeNames) {
      try {
        runCommand(List.of("docker", "volume", "rm", "-f", volumeName), projectDir);
      } catch (Exception e) {
        String message = e.getMessage() == null ? "" : e.getMessage();
        if (message.contains("No such volume")) {
          continue;
        }
        String warning = "Failed to remove volume " + volumeName + ": " + message;
        warnings.add(warning);
        log.warn(warning, e);
      }
    }
  }

  private String escapeForShell(String value) {
    if (value == null) {
      return "";
    }
    return value.replace("'", "'\"'\"'");
  }

  private boolean hasKnownVolumePrefix(String volumeName) {
    for (String prefix : KNOWN_VOLUME_PREFIXES) {
      if (volumeName.startsWith(prefix)) {
        return true;
      }
      if (volumeName.startsWith(getComposeProjectName() + "_" + prefix)) {
        return true;
      }
    }
    return false;
  }

  private void restartBlockchainNodeViaCompose(String nodeId) {
    Map<String, String> envOverrides = new LinkedHashMap<>();
    String profile = null;

    if ("genesis".equals(nodeId)) {
      envOverrides.put("GENESIS_VERBOSITY", "3");
    } else {
      Integer validatorIndex = extractValidatorIndex(nodeId);
      if (validatorIndex == null || validatorIndex < 1 || validatorIndex > MAX_VALIDATORS) {
        throw new IllegalArgumentException("Unsupported validator id: " + nodeId);
      }
      profile = "validators-" + validatorIndex;
      envOverrides.put("VALIDATOR_VERBOSITY", "3");
    }

    removeExistingContainerIfPresent(nodeId);

    runComposeCommand(
        getComposeProjectDir(),
        profile,
        List.of("up", "-d", "--no-deps", nodeId),
        envOverrides);
  }

  private void removeExistingContainerIfPresent(String nodeId) {
    List<Container> containers = getAllContainers();
    Optional<Container> containerOptional = AdminPortalUtils.findContainerByName(containers, nodeId);
    if (containerOptional.isEmpty()) {
      return;
    }

    String containerId = containerOptional.get().getId();
    try {
      dockerClient.removeContainerCmd(containerId).withForce(true).exec();
    } catch (Exception e) {
      throw new IllegalStateException("Failed to remove existing container " + nodeId + ": " + e.getMessage(), e);
    }
  }

  private boolean isSupportedBlockchainNodeId(String nodeId) {
    if ("genesis".equals(nodeId)) {
      return true;
    }

    Matcher validatorMatcher = VALIDATOR_INDEX_PATTERN.matcher(nodeId);
    if (!validatorMatcher.matches()) {
      return false;
    }

    try {
      int validatorIndex = Integer.parseInt(validatorMatcher.group(1));
      return validatorIndex >= 1 && validatorIndex <= MAX_VALIDATORS;
    } catch (NumberFormatException e) {
      return false;
    }
  }

  private String getContainerLogs(String containerId, int tailLines) throws Exception {
    int safeTailLines = Math.max(1, tailLines);
    String logs =
        runCommandCapture(
            List.of("docker", "logs", "--tail", String.valueOf(safeTailLines), containerId),
            getComposeProjectDir());
    if (logs == null || logs.isBlank()) {
      return "No logs available.";
    }
    return logs;
  }

  private ParsedSeqnoSync fetchLatestSeqnoWithRetry(String containerId) throws Exception {
    String firstOutput = runLiteClientLast(containerId, 3);
    ParsedSeqnoSync parsed = parseLiteClientSeqno(firstOutput);
    if (parsed != null) {
      return parsed;
    }

    String secondOutput = runLiteClientLast(containerId, 5);
    return parseLiteClientSeqno(secondOutput);
  }

  private String runLiteClientLast(String containerId, int timeoutSeconds) throws Exception {
    CommandResult result =
        runCommandCaptureAllowFailure(
            List.of(
                "docker",
                "exec",
                containerId,
                "/usr/local/bin/lite-client",
                "-a",
                "127.0.0.1:40004",
                "-p",
                "/var/ton-work/db/liteserver.pub",
                "-t",
                String.valueOf(timeoutSeconds),
                "-c",
                "last"),
            getComposeProjectDir(),
            Map.of());

    if (result.exitCode() != 0) {
      log.debug("lite-client returned non-zero exit code: {}", result.exitCode());
    }
    return result.output();
  }

  private ParsedSeqnoSync parseLiteClientSeqno(String output) {
    if (output == null || output.isBlank()) {
      return null;
    }

    String seqno = null;
    Matcher seqnoMatcher = LITE_CLIENT_SEQNO_PATTERN.matcher(output);
    while (seqnoMatcher.find()) {
      seqno = seqnoMatcher.group(1);
    }

    String syncedAgo = null;
    Matcher syncedAgoMatcher = LITE_CLIENT_SYNCED_AGO_PATTERN.matcher(output);
    while (syncedAgoMatcher.find()) {
      syncedAgo = syncedAgoMatcher.group(1);
    }

    if (seqno == null || syncedAgo == null) {
      return null;
    }
    return new ParsedSeqnoSync(seqno, syncedAgo);
  }

  private List<String> getExpectedBlockchainNodes(List<Container> containers) {
    Set<String> nodeNames = new LinkedHashSet<>();
    nodeNames.add("genesis");

    int configuredValidators = getConfiguredValidatorsCount();
    for (int i = 1; i <= configuredValidators; i++) {
      nodeNames.add("validator-" + i);
    }

    for (Container container : containers) {
      String containerName = extractManagedName(container);
      if ("genesis".equals(containerName) || isValidatorName(containerName)) {
        nodeNames.add(containerName);
      }
    }

    return nodeNames.stream().sorted(this::compareNodeNames).toList();
  }

  private int compareNodeNames(String left, String right) {
    if ("genesis".equals(left) && "genesis".equals(right)) {
      return 0;
    }
    if ("genesis".equals(left)) {
      return -1;
    }
    if ("genesis".equals(right)) {
      return 1;
    }

    Integer leftValidatorIndex = extractValidatorIndex(left);
    Integer rightValidatorIndex = extractValidatorIndex(right);

    if (leftValidatorIndex != null && rightValidatorIndex != null) {
      return Integer.compare(leftValidatorIndex, rightValidatorIndex);
    }
    if (leftValidatorIndex != null) {
      return -1;
    }
    if (rightValidatorIndex != null) {
      return 1;
    }

    return left.compareTo(right);
  }

  private Integer extractValidatorIndex(String nodeName) {
    Matcher matcher = VALIDATOR_INDEX_PATTERN.matcher(nodeName);
    if (!matcher.matches()) {
      return null;
    }
    try {
      return Integer.parseInt(matcher.group(1));
    } catch (NumberFormatException e) {
      return null;
    }
  }

  private int getConfiguredValidatorsCount() {
    String profiles = System.getenv("COMPOSE_PROFILES");
    if (profiles == null || profiles.isBlank()) {
      return 0;
    }

    int maxValidators = 0;
    String[] profileTokens = profiles.split(",");
    for (String token : profileTokens) {
      String profile = token.trim();
      if (profile.startsWith("validators-")) {
        try {
          int count = Integer.parseInt(profile.substring("validators-".length()));
          maxValidators = Math.max(maxValidators, count);
        } catch (NumberFormatException ignored) {
        }
      }
    }
    return Math.min(Math.max(maxValidators, 0), MAX_VALIDATORS);
  }

  private Map<String, Object> createBlockchainNodeResponse(
      String nodeName, List<Container> containers) {
    Optional<Container> containerOptional = AdminPortalUtils.findContainerByName(containers, nodeName);

    boolean exists = containerOptional.isPresent();
    boolean running = false;
    String health = "n/a";
    String detail = exists ? containerOptional.get().getStatus() : "Container not created";

    if (exists) {
      String containerId = containerOptional.get().getId();
      var state = dockerClient.inspectContainerCmd(containerId).exec().getState();
      running = Boolean.TRUE.equals(state.getRunning());
      if (state.getHealth() != null && state.getHealth().getStatus() != null) {
        health = state.getHealth().getStatus();
      }
    }

    String status;
    if (!exists) {
      status = "not-created";
    } else if (running) {
      status = "running";
    } else {
      status = "stopped";
    }

    Map<String, Object> response = new LinkedHashMap<>();
    response.put("id", nodeName);
    response.put("name", toDisplayName(nodeName));
    response.put("status", status);
    response.put("running", running);
    response.put("exists", exists);
    response.put("health", health);
    response.put("detail", detail);
    return response;
  }

  private String extractManagedName(Container container) {
    if (container.getNames() == null) {
      return "";
    }
    return Arrays.stream(container.getNames())
        .map(name -> name.startsWith("/") ? name.substring(1) : name)
        .findFirst()
        .orElse("");
  }

  private boolean isAdminPortalContainer(Container container) {
    if ("admin-portal".equals(extractManagedName(container))) {
      return true;
    }
    Map<String, String> labels = container.getLabels();
    if (labels == null) {
      return false;
    }
    return "admin-portal".equals(labels.get("com.docker.compose.service"));
  }

  private boolean isValidatorName(String name) {
    return VALIDATOR_INDEX_PATTERN.matcher(name).matches();
  }

  private String toDisplayName(String nodeName) {
    if ("genesis".equals(nodeName)) {
      return "Genesis";
    }
    Matcher matcher = VALIDATOR_INDEX_PATTERN.matcher(nodeName);
    if (matcher.matches()) {
      return "Validator " + matcher.group(1);
    }
    return nodeName;
  }

  private boolean isContainerRunning(String containerId) {
    return Boolean.TRUE.equals(
        dockerClient.inspectContainerCmd(containerId).exec().getState().getRunning());
  }

  private Map<String, Object> createServiceResponse(ManagedService service, List<Container> containers) {
    Optional<Container> containerOptional =
        AdminPortalUtils.findContainerByName(containers, service.getContainerName());

    boolean exists = containerOptional.isPresent();
    String containerId = exists ? containerOptional.get().getId() : null;
    boolean running = exists && isContainerRunning(containerId);
    int hostPort = exists ? resolveHostPort(service, containerId) : service.getDefaultHostPort();
    boolean endpointUp = running && isEndpointHealthy(service, hostPort);

    Map<String, Object> response = new LinkedHashMap<>();
    response.put("id", service.getId());
    response.put("name", service.getName());
    response.put("composeService", service.getComposeService());
    response.put("containerName", service.getContainerName());
    response.put("url", service.buildUrl(hostPort));
    response.put("hostPort", hostPort);
    response.put("running", running);
    response.put("endpointUp", endpointUp);
    response.put("exists", exists);

    return response;
  }

  private boolean isEndpointHealthy(ManagedService service, int hostPort) {
    for (String url : buildEndpointCandidateUrls(service, hostPort)) {
      if (checkSingleLinkHealth(url)) {
        return true;
      }
    }
    return false;
  }

  private List<String> buildEndpointCandidateUrls(ManagedService service, int hostPort) {
    Set<String> urls = new LinkedHashSet<>();
    String healthPath = service.getHealthPath();

    // Prefer Docker network reachability between compose siblings.
    urls.add("http://" + service.getComposeService() + ":" + service.getContainerPort() + healthPath);
    urls.add("http://" + service.getContainerName() + ":" + service.getContainerPort() + healthPath);

    // Keep host-oriented probing as a fallback (for local runs/non-compose environments).
    urls.add("http://host.docker.internal:" + hostPort + healthPath);
    urls.add("http://127.0.0.1:" + hostPort + healthPath);
    urls.add("http://localhost:" + hostPort + healthPath);

    return new ArrayList<>(urls);
  }

  private boolean checkSingleLinkHealth(String urlString) {
    try {
      URL url = new URL(urlString);
      HttpURLConnection connection = (HttpURLConnection) url.openConnection();
      connection.setRequestMethod("GET");
      connection.setConnectTimeout(2000);
      connection.setReadTimeout(2000);

      int statusCode = connection.getResponseCode();
      connection.disconnect();

      return statusCode > 0 && statusCode < 600;
    } catch (Exception e) {
      return false;
    }
  }

  private int resolveHostPort(ManagedService service, String containerId) {
    int hostPort = service.getDefaultHostPort();
    try {
      Ports ports = dockerClient.inspectContainerCmd(containerId).exec().getNetworkSettings().getPorts();
      if (ports == null || ports.getBindings() == null) {
        return hostPort;
      }

      Ports.Binding[] bindings = ports.getBindings().get(ExposedPort.tcp(service.getContainerPort()));
      if (bindings == null || bindings.length == 0 || bindings[0] == null) {
        return hostPort;
      }

      String hostPortSpec = bindings[0].getHostPortSpec();
      if (hostPortSpec == null || hostPortSpec.isBlank()) {
        return hostPort;
      }

      return Integer.parseInt(hostPortSpec);
    } catch (Exception e) {
      log.debug("Failed to resolve host port for {}", service.getContainerName(), e);
      return hostPort;
    }
  }

  private ResponseEntity<Map<String, Object>> buildErrorResponse(HttpStatus status, String message) {
    Map<String, Object> response = new LinkedHashMap<>();
    response.put("success", false);
    response.put("message", message);
    return ResponseEntity.status(status).body(response);
  }

  private record TonCenterV3Component(
      String displayName, String composeService, String containerName, boolean optionalIfMissing) {}

  private record ParsedSeqnoSync(String seqno, String syncedAgo) {}

  private record CommandResult(int exitCode, String output) {}
}
