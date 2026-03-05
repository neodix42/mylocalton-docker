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
import java.util.LinkedHashSet;
import java.util.LinkedHashMap;
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
    String projectDir = getComposeProjectDir();
    String composeFile = projectDir + "/docker-compose.yaml";

    List<List<String>> commands =
        List.of(
            List.of("docker", "compose", "-f", composeFile, "up", "-d", service.getComposeService()),
            List.of("docker-compose", "-f", composeFile, "up", "-d", service.getComposeService()));

    List<String> errors = new ArrayList<>();
    for (List<String> command : commands) {
      try {
        runCommand(command, projectDir);
        return;
      } catch (Exception e) {
        errors.add(e.getMessage());
        log.warn("Failed command {}", String.join(" ", command));
      }
    }

    throw new IllegalStateException(
        "Unable to start service "
            + service.getComposeService()
            + " via docker compose. "
            + String.join(" | ", errors));
  }

  private void runCommand(List<String> command, String workDir) throws Exception {
    ProcessBuilder processBuilder = new ProcessBuilder(command);
    processBuilder.directory(new File(workDir));
    processBuilder.redirectErrorStream(true);

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

    if (output != null && !output.isBlank()) {
      log.info("Command output: {}", output);
    }
  }

  private String getComposeProjectDir() {
    String envValue = System.getenv("COMPOSE_PROJECT_DIR");
    if (envValue == null || envValue.isBlank()) {
      return "/workspace";
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

    return List.copyOf(nodeNames);
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
    return Math.min(Math.max(maxValidators, 0), 5);
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
