package org.ton.mylocaltondocker.timemachine.controller;

import static com.github.dockerjava.api.model.HostConfig.newHostConfig;

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

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.io.FileUtils;
import org.codehaus.plexus.util.StringUtils;
import org.springframework.web.bind.annotation.*;
import org.ton.java.tonlib.types.MasterChainInfo;
import org.ton.java.utils.Utils;
import org.ton.mylocaltondocker.timemachine.Main;

@RestController
@Slf4j
public class MyRestController {
  public static final String CONTAINER_GENESIS = "genesis";
  public static final String CONTAINER_DB_PATH = "/var/ton-work/db";
  public static final String GENESIS_IMAGE_NAME = "mylocaltondocker";
  String error;

  private final ConcurrentHashMap<String, Bucket> sessionBuckets = new ConcurrentHashMap<>();

  DockerClient dockerClient = createDockerClient();

  @GetMapping("/seqno-volume")
  public Map<String, Object> getSeqno() {
    try {
      log.info("Getting seqno-volume");

      String genesisContainerId = getGenesisContainerId();

      if (StringUtils.isEmpty(genesisContainerId)) {
        log.error("Container not found");
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "Container not found");
        return response;
      }

      MasterChainInfo masterChainInfo = Main.tonlib.getMasterChainInfo();
      if (masterChainInfo == null) {
        log.error("masterChainInfo is null");
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "masterChainInfo is null");
        return response;
      }

      String volume = getCurrentVolume(dockerClient, genesisContainerId);
      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("seqno", masterChainInfo.getLast().getSeqno());
      response.put("volume", volume);
      log.info("return seqno-volume {} {}", masterChainInfo.getLast().getSeqno(), volume);
      return response;
    } catch (Exception e) {
      log.error("Error getting seqno-volume", e);
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to get seqno-volume: " + e.getMessage());
      return response;
    }
  }

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
      log.info("taking snapshot");
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

      String genesisContainerId = getGenesisContainerId();

      if (StringUtils.isEmpty(genesisContainerId)) {
        log.error("Container not found");
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "Container not found");
        return response;
      }

      String volumeName = getCurrentVolume(dockerClient, genesisContainerId);

      if (volumeName == null) {
        log.error("Current volume not found");
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "Current volume not found");
        return response;
      }

      long lastSeqno = getCurrentBlockSequence();
      copyVolumes(dockerClient, volumeName, backupVolumeName);

      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("snapshotId", snapshotId);
      response.put("snapshotNumber", snapshotNumber);
      response.put("blockSequence", lastSeqno);
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

  private String getGenesisContainerId() {
    return
        dockerClient
            .listContainersCmd()
            .withNameFilter(List.of(CONTAINER_GENESIS))
            .exec()
            .stream()
            .findFirst()
            .map(c -> c.getId())
            .get();
  }

  private void copyVolumes(
      DockerClient dockerClient, String sourceVolumeName, String targetVolumeName)
      throws InterruptedException {
      log.info("copy volume {} to volume {}", sourceVolumeName, targetVolumeName);

    try {
      dockerClient.inspectVolumeCmd(targetVolumeName).exec();
    } catch (Exception e) {
      dockerClient.createVolumeCmd().withName(targetVolumeName).exec();
    }

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
            .withName("taking-snapshot")
            .withHostConfig(
                newHostConfig()
                    .withBinds(
                        new Bind(sourceVolumeName, new Volume("/from")),
                        new Bind(targetVolumeName, new Volume("/to"))))
            .exec()
            .getId();

      dockerClient.startContainerCmd(copyContainerId).exec();
      var callback = new WaitContainerResultCallback();
      dockerClient.waitContainerCmd(copyContainerId).exec(callback);
      callback.awaitCompletion();
      dockerClient.removeContainerCmd(copyContainerId).withForce(true).exec();

      log.info("Volumes copied");
  }

  private static String getCurrentVolume(DockerClient dockerClient, String containerId) {
    // Get currently used volume name that is mounted to path CONTAINER_DB_PATH
    InspectContainerResponse inspectX = dockerClient.inspectContainerCmd(containerId).exec();
    String volumeName = null;
    for (var mount : inspectX.getMounts()) {
      if (mount.getSource() != null && mount.getDestination().getPath().equals(CONTAINER_DB_PATH)) {
        volumeName = mount.getName();
        break;
      }
    }
    return volumeName;
  }

  @PostMapping("/restore-snapshot")
  public Map<String, Object> restoreSnapshot(@RequestBody Map<String, String> request) {
    try {
      String snapshotId = request.get("snapshotId");
      String snapshotNumber = request.get("snapshotNumber");

      log.info("Restoring snapshot: {}", snapshotId);

      String backupVolumeName = "ton-db-snapshot-" + snapshotNumber;

      String genesisContainerId = getGenesisContainerId();

      if (StringUtils.isEmpty(genesisContainerId)) {
        log.error("Container not found");
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "Container not found");
        return response;
      }

      // Get container configuration
      InspectContainerResponse inspectX = dockerClient.inspectContainerCmd(genesisContainerId).exec();
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

      dockerClient.stopContainerCmd(genesisContainerId).exec();
      dockerClient.removeContainerCmd(genesisContainerId).withForce(true).exec();

      CreateContainerResponse newContainer =
          dockerClient
              .createContainerCmd(GENESIS_IMAGE_NAME)
              .withName(CONTAINER_GENESIS)
              .withVolumes(new Volume(CONTAINER_DB_PATH), new Volume("/usr/share/data"))
              .withEnv(envs)
              .withExposedPorts(exposedPorts)
              .withIpv4Address("172.28.1.10")
              .withHealthcheck(healthCheck)
              .withHostConfig(
                  newHostConfig()
                      .withNetworkMode(networkMode)
                      .withPortBindings(portBindings)
                      .withBinds(
                          new Bind(backupVolumeName, new Volume(CONTAINER_DB_PATH)),
                          new Bind("mylocalton-docker_shared-data", new Volume("/usr/share/data"))))
              .exec();

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

  private long getCurrentBlockSequence() {
    MasterChainInfo masterChainInfo = Main.tonlib.getMasterChainInfo();
    return masterChainInfo.getLast().getSeqno();
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
      return Utils.getRandomInt();
    }
  }

  public static long getVolumeSize(String volumeName) {
    File volumeDir = new File(volumeName);
    if (!volumeDir.exists() || !volumeDir.isDirectory()) {
      System.err.println("Volume path does not exist or is not a directory: " + volumeName);
      return 0L;
    }
    return FileUtils.sizeOfDirectory(volumeDir);
  }

  public static DockerClient createDockerClient() {
//    log.info("Env DOCKER_HOST: {}", System.getenv("DOCKER_HOST"));
    DefaultDockerClientConfig defaultConfig =
        DefaultDockerClientConfig.createDefaultConfigBuilder().build();
//    log.info("Using Docker host: {}", defaultConfig.getDockerHost());

    var httpClient =
        new OkDockerHttpClient.Builder()
            .dockerHost(defaultConfig.getDockerHost())
            .sslConfig(defaultConfig.getSSLConfig())
            .build();

    return DockerClientBuilder.getInstance(defaultConfig).withDockerHttpClient(httpClient).build();
  }
}
