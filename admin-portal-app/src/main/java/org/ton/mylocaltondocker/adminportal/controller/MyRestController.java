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
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/admin")
@Slf4j
public class MyRestController {

  private static final Pattern VALIDATOR_INDEX_PATTERN = Pattern.compile("^validator-(\\d+)$");
  private static final int MAX_VALIDATORS = 5;
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
  public ResponseEntity<Map<String, Object>> getBlockchainNodeLogs(@PathVariable("nodeId") String nodeId) {
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
      String logs = getContainerLogs(containerOptional.get().getId(), 100);

      Map<String, Object> response = new LinkedHashMap<>();
      response.put("success", true);
      response.put("nodeId", nodeId);
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
    if (exitCode != 0) {
      throw new IllegalStateException(
          "command failed ("
              + exitCode
              + "): "
              + String.join(" ", command)
              + (output == null || output.isBlank() ? "" : "\n" + output));
    }
    return output;
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

    runComposeCommand(
        getComposeProjectDir(),
        profile,
        List.of("up", "-d", "--force-recreate", "--no-deps", nodeId),
        envOverrides);
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
    List<String> hosts = List.of("host.docker.internal", "127.0.0.1");

    for (String host : hosts) {
      String url = "http://" + host + ":" + hostPort + service.getHealthPath();
      if (checkSingleLinkHealth(url)) {
        return true;
      }
    }
    return false;
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
}
