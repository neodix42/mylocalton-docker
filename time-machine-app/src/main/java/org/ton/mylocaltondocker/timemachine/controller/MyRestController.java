package org.ton.mylocaltondocker.timemachine.controller;

import static com.github.dockerjava.api.model.HostConfig.newHostConfig;
import static java.util.Objects.isNull;

import com.github.dockerjava.api.DockerClient;
import com.github.dockerjava.api.command.*;
import com.github.dockerjava.api.exception.NotFoundException;
import com.github.dockerjava.api.model.*;
import com.github.dockerjava.core.DefaultDockerClientConfig;
import com.github.dockerjava.core.DockerClientBuilder;
import com.github.dockerjava.okhttp.OkDockerHttpClient;
import io.github.bucket4j.Bandwidth;
import io.github.bucket4j.Bucket;
import io.github.bucket4j.Refill;
import jakarta.servlet.http.HttpServletRequest;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.websocket.EndpointConfig;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.io.FileUtils;
import org.springframework.web.bind.annotation.*;
import org.ton.java.tonlib.types.MasterChainInfo;
import org.ton.java.utils.Utils;
import org.ton.mylocaltondocker.timemachine.Main;

@RestController
@Slf4j
public class MyRestController {
  String error;

  private final ConcurrentHashMap<String, Bucket> sessionBuckets = new ConcurrentHashMap<>();

  public static String getContainerId() throws IOException {
    try (BufferedReader br =
        new BufferedReader(
            new InputStreamReader(new java.io.FileInputStream("/proc/self/cgroup")))) {
      String line;
      while ((line = br.readLine()) != null) {
        if (line.contains("docker")) {
          String[] parts = line.split("/");
          String id = parts[parts.length - 1].trim();
          if (id.length() == 64) {
            return id; // full container ID
          }
          // else, might be short, handle accordingly
          return id;
        }
      }
    }
    return null;
  }

  //  private static String getYamlFileFromCompose() throws IOException, InterruptedException {
  //    ProcessBuilder pb = new ProcessBuilder("docker-compose", "ls");
  //    Process process = pb.start();
  //
  //    try (BufferedReader reader =
  //        new BufferedReader(new InputStreamReader(process.getInputStream()))) {
  //      String line;
  //      boolean headerSkipped = false; // To skip header line
  //      while ((line = reader.readLine()) != null) {
  //        if (!headerSkipped) {
  //          // Skip the header line
  //          headerSkipped = true;
  //          continue;
  //        }
  //        // Example line:
  //        // mylocalton-docker   running(3)
  //        // /home/neodix/IdeaProjects/mylocalton-docker/docker-compose-build.yaml
  //        String[] parts = line.trim().split("\\s+");
  //        if (parts.length >= 3) {
  //          String containerName = parts[0];
  //          String configFilePath = parts[2];
  //          //          if (containerName.equals(targetContainerName)) {
  //          return configFilePath;
  //          //          }
  //        }
  //      }
  //    }
  //    process.waitFor();
  //    return null; // Not found
  //  }
  //
  //  private static void copyFileToContainer(
  //      String containerId, String sourceFilePath, String targetDirInContainer)
  //      throws IOException, InterruptedException {
  //    String targetPathInContainer = targetDirInContainer; // e.g., "/tmp/"
  //    String command =
  //        String.format("docker cp %s %s:%s", sourceFilePath, containerId, targetPathInContainer);
  //    System.out.println("Executing: " + command);
  //    ProcessBuilder pb = new ProcessBuilder("sh", "-c", command);
  //    Process process = pb.start();
  //    int exitCode = process.waitFor();
  //    if (exitCode != 0) {
  //      System.err.println("Failed to copy file to container");
  //    }
  //  }
  //
  //  @PostMapping("/ls")
  //  public Map<String, Object> executeJavaCodeLs(
  //      @RequestBody Map<String, String> request, HttpServletRequest httpServletRequest) {
  //
  //    try {
  //      String yaml = getYamlFileFromCompose();
  //      log.info("found yaml on host {}", yaml);
  //
  //      //      String hostname = getContainerId();
  //      String hostname = "time-machine";
  //      log.info("hostname (container-id) {}", hostname);
  //
  //      copyFileToContainer(hostname, yaml, "/tmp/");
  //      System.out.println("File copied to container's /tmp/ directory");
  //
  //      Map<String, Object> response = new HashMap<>();
  //      response.put("success", false);
  //      response.put("message", "ls");
  //      return response;
  //    } catch (IOException | InterruptedException e) {
  //      e.printStackTrace();
  //    }
  //    return null;
  //  }

  @PostMapping("/time-machine")
  public Map<String, Object> executeJavaCode(
      @RequestBody Map<String, String> request, HttpServletRequest httpServletRequest) {
    System.out.println("running /time-machine");

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

      //      new DockerComposeContainer(new File("/tmp/docker-compose-build.yaml")).start();

      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "time-machine");
      return response;

    } else {
      Map<String, Object> response = new HashMap<>();
      log.info("rate limit, session {}", sessionId);
      response.put("success", false);
      response.put("message", "rate limit, 10 requests per minute");
      return response;
    }
  }

  @GetMapping("/seqno")
  public Map<String, Object> getSeqno() {
    try {
      MasterChainInfo masterChainInfo= Main.tonlib.getMasterChainInfo();

      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("seqno", masterChainInfo.getLast().getSeqno());
      return response;
    } catch (Exception e) {
      log.error("Error getting seqno", e);
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to get seqno: " + e.getMessage());
      return response;
    }
  }
  // Graph management endpoints
  @GetMapping("/graph")
  public Map<String, Object> getGraph() {
    try {
      String graphPath = "/usr/share/data/graph.json";
      File graphFile = new File(graphPath);

      if (graphFile.exists()) {
        String content = new String(Files.readAllBytes(Paths.get(graphPath)));
        ObjectMapper mapper = new ObjectMapper();
        Map<String, Object> graphData = mapper.readValue(content, Map.class);

        Map<String, Object> response = new HashMap<>();
        response.put("success", true);
        response.put("graph", graphData);
        return response;
      } else {
        // Return empty graph if file doesn't exist
        Map<String, Object> response = new HashMap<>();
        response.put("success", true);
        response.put("graph", null);
        return response;
      }
    } catch (Exception e) {
      log.error("Error reading graph data", e);
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to read graph data: " + e.getMessage());
      return response;
    }
  }

  @PostMapping("/graph")
  public Map<String, Object> saveGraph(@RequestBody Map<String, Object> request) {
    try {
      String graphPath = "/usr/share/data/graph.json";

      // Ensure directory exists
      File dataDir = new File("/usr/share/data");
      if (!dataDir.exists()) {
        dataDir.mkdirs();
      }

      ObjectMapper mapper = new ObjectMapper();
      String jsonContent = mapper.writeValueAsString(request.get("graph"));

      Files.write(Paths.get(graphPath), jsonContent.getBytes());

      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("message", "Graph saved successfully");
      return response;
    } catch (Exception e) {
      log.error("Error saving graph data", e);
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to save graph data: " + e.getMessage());
      return response;
    }
  }

  @PostMapping("/take-snapshot")
  public Map<String, Object> takeSnapshot(@RequestBody Map<String, String> request) {
    try {
      log.info("Creating snapshot (backup only)");

      DockerClient dockerClient = createDockerClient();
      String containerXName = "genesis";
      String containerXMountPath = "/var/ton-work/db";

      // Get sequential snapshot number from request or generate next one
      int snapshotNumber;
      if (request.containsKey("snapshotNumber")) {
        snapshotNumber = Integer.parseInt(request.get("snapshotNumber"));
      } else {
        // Fallback: generate next sequential number by counting existing volumes
        snapshotNumber = getNextSnapshotNumber(dockerClient);
      }
      
      String snapshotId = "snapshot-" + snapshotNumber;
      String backupVolumeName = "ton-db-snapshot-" + snapshotNumber;

      // Find container
      String containerXId =
          dockerClient.listContainersCmd().withNameFilter(List.of(containerXName)).exec().stream()
              .findFirst()
              .map(c -> c.getId())
              .orElseThrow(() -> new RuntimeException("Container not found"));

      // Get current volume
      InspectContainerResponse inspectX = dockerClient.inspectContainerCmd(containerXId).exec();
      String volumeName = null;
      for (var mount : inspectX.getMounts()) {
        if (mount.getSource() != null
            && mount.getDestination().getPath().equals(containerXMountPath)) {
          volumeName = mount.getName();
          break;
        }
      }

      if (volumeName == null) {
        throw new RuntimeException("Volume not found");
      }

      // Create backup volume
      try {
        dockerClient.inspectVolumeCmd(backupVolumeName).exec();
      } catch (Exception e) {
        dockerClient.createVolumeCmd().withName(backupVolumeName).exec();
      }

      // Ensure alpine image exists
      try {
        dockerClient.inspectImageCmd("alpine:latest").exec();
      } catch (NotFoundException e) {
        dockerClient
            .pullImageCmd("alpine")
            .withTag("latest")
            .exec(new PullImageResultCallback())
            .awaitCompletion();
      }

      // Copy data to backup volume
      String copyContainerId =
          dockerClient
              .createContainerCmd("alpine")
              .withCmd("/bin/sh", "-c", "cp -rTv /from/. /to/.")
              .withVolumes(new Volume("/from"), new Volume("/to"))
              .withName("taking-snapshot-" + snapshotNumber)
              .withHostConfig(
                  newHostConfig()
                      .withBinds(
                          new Bind(volumeName, new Volume("/from")),
                          new Bind(backupVolumeName, new Volume("/to"))))
              .exec()
              .getId();

      dockerClient.startContainerCmd(copyContainerId).exec();
      Thread.sleep(5000); // Wait for copy to complete
      dockerClient.removeContainerCmd(copyContainerId).withForce(true).exec();

      log.info("Snapshot created: {}", snapshotId);

      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("snapshotId", snapshotId);
      response.put("snapshotNumber", snapshotNumber);
      response.put("blockSequence", getCurrentBlockSequence());
      response.put("volumeName", backupVolumeName);
      response.put("message", "Snapshot created successfully");
      return response;

    } catch (Exception e) {
      log.error("Error creating snapshot", e);
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to create snapshot: " + e.getMessage());
      return response;
    }
  }

  @PostMapping("/restore-snapshot")
  public Map<String, Object> restoreSnapshot(@RequestBody Map<String, String> request) {
    try {
      String snapshotId = request.get("snapshotId");
      String snapshotNumber = request.get("snapshotNumber");

      log.info("Restoring snapshot: {}", snapshotId);

      DockerClient dockerClient = createDockerClient();
      String containerXName = "genesis";
      String containerXMountPath = "/var/ton-work/db";
      String imageName = "mylocaltondocker";
      String backupVolumeName = "ton-db-snapshot-" + snapshotNumber;

      // Find and stop current container
      String containerXId =
          dockerClient.listContainersCmd().withNameFilter(List.of(containerXName)).exec().stream()
              .findFirst()
              .map(c -> c.getId())
              .orElseThrow(() -> new RuntimeException("Container not found"));

      // Get container configuration
      InspectContainerResponse inspectX = dockerClient.inspectContainerCmd(containerXId).exec();
      ContainerConfig oldConfig = inspectX.getConfig();
      HostConfig oldHostConfig = inspectX.getHostConfig();

      String[] envs = oldConfig.getEnv();
      ExposedPort[] exposedPorts = oldConfig.getExposedPorts();
      HealthCheck healthCheck = oldConfig.getHealthcheck();
      String networkMode = oldHostConfig.getNetworkMode();

      Ports portBindings = new Ports();
      if (exposedPorts != null) {
        for (ExposedPort exposedPort : exposedPorts) {
          portBindings.bind(exposedPort, Ports.Binding.bindPort(exposedPort.getPort()));
        }
      }

      // Stop and remove current container
      dockerClient.stopContainerCmd(containerXId).exec();
      Thread.sleep(1000);
      dockerClient.removeContainerCmd(containerXId).withForce(true).exec();
      Thread.sleep(1000);

      // Create new container with snapshot volume
      CreateContainerResponse newContainer =
          dockerClient
              .createContainerCmd(imageName)
              .withName(containerXName)
              .withVolumes(new Volume(containerXMountPath), new Volume("/usr/share/data"))
              .withEnv(envs)
              .withExposedPorts(exposedPorts)
              .withIpv4Address("172.28.1.10")
              .withHealthcheck(healthCheck)
              .withHostConfig(
                  newHostConfig()
                      .withNetworkMode(networkMode)
                      .withPortBindings(portBindings)
                      .withBinds(
                          new Bind(backupVolumeName, new Volume(containerXMountPath)),
                          new Bind("mylocalton-docker_shared-data", new Volume("/usr/share/data"))))
              .exec();

      // Start the container
      dockerClient.startContainerCmd(newContainer.getId()).exec();

      log.info("Snapshot restored: {}", snapshotId);

      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("message", "Snapshot restored successfully");
      return response;

    } catch (Exception e) {
      log.error("Error restoring snapshot", e);
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to restore snapshot: " + e.getMessage());
      return response;
    }
  }

  private int getCurrentBlockSequence() {
    // This is a placeholder - in a real implementation, you would
    // query the blockchain to get the current block sequence number
    return Utils.getRandomInt() % 10000;
  }

  private int getNextSnapshotNumber(DockerClient dockerClient) {
    try {
      // List all volumes with snapshot prefix to determine next sequential number
      List<InspectVolumeResponse> volumes = dockerClient.listVolumesCmd().exec().getVolumes();
      int maxSnapshotNumber = 0;
      
      for (InspectVolumeResponse volume : volumes) {
        String volumeName = volume.getName();
        if (volumeName.startsWith("ton-db-snapshot-")) {
          try {
            String numberPart = volumeName.substring("ton-db-snapshot-".length());
            int snapshotNumber = Integer.parseInt(numberPart);
            maxSnapshotNumber = Math.max(maxSnapshotNumber, snapshotNumber);
          } catch (NumberFormatException e) {
            // Skip volumes that don't have valid number suffix
            log.warn("Invalid snapshot volume name format: {}", volumeName);
          }
        }
      }
      
      return maxSnapshotNumber + 1;
    } catch (Exception e) {
      log.error("Error determining next snapshot number", e);
      // Fallback to timestamp-based number if volume listing fails
      return (int) (System.currentTimeMillis() % 10000);
    }
  }

  public static long getVolumeSize(String volumeName) {
    String volumePath = volumeName; // Docker default path
    File volumeDir = new File(volumePath);
    if (!volumeDir.exists() || !volumeDir.isDirectory()) {
      System.err.println("Volume path does not exist or is not a directory: " + volumePath);
      return 0L;
    }
    return FileUtils.sizeOfDirectory(volumeDir);
  }

  public static DockerClient createDockerClient() {
    log.info("Env DOCKER_HOST: {}", System.getenv("DOCKER_HOST"));
    DefaultDockerClientConfig defaultConfig =
        DefaultDockerClientConfig.createDefaultConfigBuilder().build();
    log.info("Using Docker host: {}", defaultConfig.getDockerHost());

    var httpClient =
        new OkDockerHttpClient.Builder()
            .dockerHost(defaultConfig.getDockerHost())
            .sslConfig(defaultConfig.getSSLConfig())
            .build();

    return DockerClientBuilder.getInstance(defaultConfig).withDockerHttpClient(httpClient).build();
  }

  // Function to check if IP is available
  public boolean isIpAvailable(DockerClient dockerClient, String ipAddress, String networkName) {
    // List all containers
    List<Container> containers = dockerClient.listContainersCmd().withShowAll(true).exec();

    // Check each container's network settings for IP address conflicts
    for (Container container : containers) {
      InspectContainerResponse containerDetails =
          dockerClient.inspectContainerCmd(container.getId()).exec();
      Map<String, ContainerNetwork> networks = containerDetails.getNetworkSettings().getNetworks();
      ContainerNetwork containerNetwork = networks.get(networkName);
      //      log.info("container network {}, container {}", containerNetwork, container);
      if (containerNetwork != null && ipAddress.equals(containerNetwork.getIpAddress())) {
        return false; // IP is in use
      }
    }
    return true; // IP is available
  }
}
