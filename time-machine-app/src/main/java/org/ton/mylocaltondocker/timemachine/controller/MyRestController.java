package org.ton.mylocaltondocker.timemachine.controller;

import static com.github.dockerjava.api.model.HostConfig.newHostConfig;
import static java.util.Objects.isNull;
import static java.util.Objects.nonNull;
import static org.ton.mylocaltondocker.timemachine.controller.StartUpTask.reinitializeAdnlLiteClient;

import com.github.dockerjava.api.DockerClient;
import com.github.dockerjava.api.command.*;
import com.github.dockerjava.api.exception.NotFoundException;
import com.github.dockerjava.api.model.*;
import com.github.dockerjava.core.DefaultDockerClientConfig;
import com.github.dockerjava.core.DockerClientBuilder;
import com.github.dockerjava.okhttp.OkDockerHttpClient;
import io.github.bucket4j.Bucket;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.*;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.reflect.TypeToken;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.io.FileUtils;
import org.codehaus.plexus.util.StringUtils;
import org.springframework.web.bind.annotation.*;
import org.ton.ton4j.tlb.Block;
import org.ton.ton4j.utils.Utils;
import org.ton.mylocaltondocker.timemachine.Main;
import org.ton.ton4j.tl.liteserver.responses.MasterchainInfo;

@RestController
@Slf4j
public class MyRestController {
  public static final String CONTAINER_GENESIS = "genesis";
  public static final String CONTAINER_DB_PATH = "/var/ton-work/db";
  public static final String GENESIS_IMAGE_NAME = "mylocaltondocker";
  public static final String[] VALIDATOR_CONTAINERS = {
    "genesis", "validator-1", "validator-2", "validator-3", "validator-4", "validator-5"
  };

  public static final Map<String, String> CONTAINER_VOLUME_MAP =
      Map.of(
          "genesis", "ton-db-val0",
          "validator-1", "ton-db-val1",
          "validator-2", "ton-db-val2",
          "validator-3", "ton-db-val3",
          "validator-4", "ton-db-val4",
          "validator-5", "ton-db-val5");
  String error;

  private final ConcurrentHashMap<String, Bucket> sessionBuckets = new ConcurrentHashMap<>();

  DockerClient dockerClient = createDockerClient();

  @GetMapping("/seqno-volume")
  public Map<String, Object> getSeqno() {
    try {

      MasterchainInfo masterChainInfo = getMasterchainInfo();
      if (masterChainInfo == null) {
        log.warn("masterChainInfo is null, attempting reinit");
        try {
          reinitializeAdnlLiteClient();
        } catch (Exception reinitEx) {
          log.error("Reinitialization failed");
        }
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "masterChainInfo is null");
        return response;
      }

      String id = getActiveNodeIdFromVolume();
      int activeNodes = getAllCurrentlyRunningValidatorContainers().size();
      long syncDelay = getSyncDelay();
      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("seqno", masterChainInfo.getLast().getSeqno());
      response.put("id", id);
      response.put("activeNodes", activeNodes);
      response.put("syncDelay", syncDelay);
      //      log.info("return seqno-volume {} {}", masterChainInfo.getLast().getSeqno(), volume);
      return response;
    } catch (Throwable e) {

      // Always attempt reinitialization for any error
      try {
        reinitializeAdnlLiteClient();
      } catch (Exception reinitEx) {
        log.error("Reinitialization failed");
      }

      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to get seqno-volume");
      return response;
    }
  }

  @GetMapping("/active-nodes")
  public Map<String, Object> getActiveNodes() {
    try {
      int activeNodes = getAllCurrentlyRunningValidatorContainers().size();
      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("activeNodes", activeNodes);
      return response;
    } catch (Exception e) {
      log.error("Error getting active nodes count", e);
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to get active nodes count: " + e.getMessage());
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
        Gson gson = new GsonBuilder().create();
        TypeToken<Map<String, Object>> typeToken = new TypeToken<Map<String, Object>>() {};
        Map<String, Object> graphData = gson.fromJson(content, typeToken.getType());

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

      Gson gson = new GsonBuilder().create();
      String jsonContent = gson.toJson(request.get("graph"));

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

  @PostMapping("/reset-graph")
  public Map<String, Object> resetGraph() {
    try {
      String graphPath = "/usr/share/data/graph.json";
      File graphFile = new File(graphPath);

      if (graphFile.exists()) {
        graphFile.delete();
        log.info("Graph data file deleted: {}", graphPath);
      }

      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("message", "Graph data reset successfully");
      return response;
    } catch (Exception e) {
      log.error("Error resetting graph data", e);
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to reset graph data: " + e.getMessage());
      return response;
    }
  }

  // Store current snapshot status for status endpoint
  private volatile String currentSnapshotStatus = "Ready";
  private volatile boolean isSnapshotInProgress = false;

  @GetMapping("/snapshot-status")
  public Map<String, Object> getSnapshotStatus() {
    Map<String, Object> response = new HashMap<>();
    response.put("status", currentSnapshotStatus);
    response.put("inProgress", isSnapshotInProgress);
    return response;
  }

  private SnapshotConfig getCurrentSnapshotConfig() {
    List<String> runningContainers = getAllCurrentlyRunningContainers();
    Map<String, DockerContainer> dockerContainers = new HashMap<>();

    for (String containerName : runningContainers) {
      DockerContainer dockerContainer = getDockerContainerConfiguration(containerName);
      dockerContainers.put(containerName, dockerContainer);
    }

    return SnapshotConfig.builder()
        .runningContainers(runningContainers)
        .containers(dockerContainers)
        .build();
  }

  @PostMapping("/take-snapshot")
  public Map<String, Object> takeSnapshot(@RequestBody Map<String, String> request) {
    try {

      // Discover all running containers (including all services, not just genesis + validators)
      List<String> runningContainers = getAllCurrentlyRunningContainers();
      if (runningContainers.isEmpty()) {
        log.error("No containers found");
        isSnapshotInProgress = false;
        currentSnapshotStatus = "Ready";
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "No containers found");
        return response;
      }

      isSnapshotInProgress = true;
      currentSnapshotStatus = "Preparing snapshot...";

      String snapshotNumber;
      if (request.containsKey("snapshotNumber")) {
        snapshotNumber = request.get("snapshotNumber");
        log.info("got snapshot number from request {}", snapshotNumber);
      } else {
        log.error("snapshotNumber field is missing");
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "SnapshotNumber field is missing");
        return response;
      }

      if (!isConfigExist(0)) {
        SnapshotConfig snapshotConfig = getCurrentSnapshotConfig();
        snapshotConfig.setSnapshotNumber("0");
        snapshotConfig.setTimestamp(System.currentTimeMillis());
        storeSnapshotConfiguration(snapshotConfig);
      }

      log.info("Found running containers: {}", runningContainers);

      // Check if we're taking snapshot from active (running) node
      String parentId = request.get("parentId");
      String activeNodeId = getActiveNodeIdFromVolume();
      log.info(
          "/take-snapshot, parentSnapshotNumber: {}, nextSnapshotNumber {}, activeNodeId {}",
          parentId,
          snapshotNumber,
          activeNodeId);

      boolean isFromActiveNode = parentId != null && parentId.equals(activeNodeId);

      List<String> runningValidators = getAllCurrentlyRunningValidatorContainers();

      boolean shouldShutdownBlockchain = isFromActiveNode && !runningValidators.isEmpty();

      log.info(
          "Taking snapshot from active node: {}, Validator containers running: {}, should shutdown blockchain: {}",
          isFromActiveNode,
          runningValidators.size(),
          shouldShutdownBlockchain);

      // Get current block sequence BEFORE shutting down blockchain
      long lastSeqno = 0;
      try {
        lastSeqno = getCurrentBlockSequence();
      } catch (Exception e) {
        log.warn("Could not get current block sequence, using 0: {}", e.getMessage());
      }

      SnapshotConfig snapshotConfig = loadSnapshotConfiguration(parentId);
      SnapshotConfig snapshotConfigNew = loadSnapshotConfiguration(parentId);
      snapshotConfigNew.setSnapshotNumber(snapshotNumber);
      snapshotConfigNew.setTimestamp(System.currentTimeMillis());

      if (shouldShutdownBlockchain) {
        currentSnapshotStatus = "Stopping blockchain...";
        log.info("Shutting down blockchain (all containers) before taking snapshots");
        stopAndRemoveAllContainers();
      }

      // Create snapshots for all containers in parallel
      currentSnapshotStatus = "Taking snapshot...";

      // copy volumes in parallel
      snapshotConfig.getCoreContainers().parallelStream()
          .forEach(
              entry -> {
                String containerName = entry.getName();
                String currentVolume = entry.getTonDbVolumeName();
                String backupVolumeName =
                    CONTAINER_VOLUME_MAP.get(containerName) + "-snapshot-" + snapshotNumber;

                try {
                  if (nonNull(currentVolume)) {
                    log.info(
                        "Copy volumes in container {}: {} -> {}",
                        containerName,
                        currentVolume,
                        backupVolumeName);
                    copyVolume(dockerClient, currentVolume, backupVolumeName);
                  }
                } catch (InterruptedException e) {
                  throw new RuntimeException(e);
                }
              });

      // copy volumes in parallel
      snapshotConfig
          .getContainers()
          .forEach(
              (containerName, value) -> {
                String currentVolume = value.getTonDbVolumeName();
                String backupVolumeName =
                    CONTAINER_VOLUME_MAP.get(containerName) + "-snapshot-" + snapshotNumber;
                replaceVolumeInConfig(
                    snapshotConfigNew, containerName, currentVolume, backupVolumeName);
              });

      storeSnapshotConfiguration(snapshotConfigNew);

      Map<String, Object> response = new HashMap<>();

      // If blockchain was shutdown, restart it with the same volumes and configurations
      if (shouldShutdownBlockchain) {
        try {
          currentSnapshotStatus = "Starting blockchain...";

          createContainerGroup(snapshotConfig.getCoreContainers());

          // Wait for lite-server to be ready before setting status to Ready
          currentSnapshotStatus = "Waiting for lite-server to be ready";
          if (waitForSeqnoVolumeHealthy()) {
            currentSnapshotStatus = "Starting extra services...";
            createContainerGroup(snapshotConfig.getExtraContainers());
          } else {
            response.put("success", false);
            response.put("message", "Blockchain cannot be started, see docker logs.");
            currentSnapshotStatus = "Blockchain cannot be started, see docker logs.";
          }

          log.info("Blockchain restarted successfully after snapshot creation");
        } catch (Exception e) {
          log.error("Failed to restart blockchain after snapshot creation: {}", e.getMessage());
          // Add this to failed snapshots so the response indicates the issue
        }
      }

      // Get active nodes count to include in response
      int activeNodesCount = 0;
      try {
        activeNodesCount = getAllCurrentlyRunningValidatorContainers().size();
      } catch (Exception e) {
        log.warn("Could not get active nodes count for snapshot response: {}", e.getMessage());
      }

      currentSnapshotStatus = "Snapshot taken successfully";
      response.put("success", true);
      response.put("snapshotId", snapshotNumber);
      response.put("snapshotNumber", snapshotNumber);
      response.put("seqno", lastSeqno);
      response.put("volumeName", "ton-db-snapshot-" + snapshotNumber); // Keep for compatibility
      response.put("blockchainShutdown", shouldShutdownBlockchain);
      response.put("activeNodes", activeNodesCount); // Include active nodes count
      response.put("message", "Snapshots created successfully");

      isSnapshotInProgress = false;

      return response;

    } catch (Exception e) {
      log.error("Error creating snapshots", e);
      isSnapshotInProgress = false;
      currentSnapshotStatus = "Snapshot failed";
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to create snapshots: " + e.getMessage());
      return response;
    }
  }

  private String getGenesisContainerId() {
    return dockerClient
        .listContainersCmd()
        .withNameFilter(List.of(CONTAINER_GENESIS))
        .exec()
        .stream()
        .findFirst()
        .map(c -> c.getId())
        .orElse(null);
  }

  private List<String> getAllRunningContainers() {
    List<String> runningContainers = new ArrayList<>();

    // Check each validator
    for (String validatorContainer : getAllContainers()) {
      try {
        List<Container> containers =
            dockerClient.listContainersCmd().withNameFilter(List.of(validatorContainer)).exec();
        if (!containers.isEmpty()) {
          runningContainers.add(validatorContainer);
        }
      } catch (Exception e) {
        log.debug("Validator container {} not running", validatorContainer);
      }
    }

    return runningContainers;
  }

  private List<String> getAllCurrentlyRunningContainers() {
    List<String> runningContainers = new ArrayList<>();
    List<String> allContainers = getAllContainers();

    for (String containerName : allContainers) {
      try {
        String containerId = getContainerIdByName(containerName);
        if (containerId != null) {
          // Double-check that container is actually running
          InspectContainerResponse inspectResponse =
              dockerClient.inspectContainerCmd(containerId).exec();
          if (inspectResponse.getState().getRunning()) {
            runningContainers.add(containerName);
          }
        }
      } catch (Exception e) {
        log.debug("Container {} not running", containerName);
      }
    }

//    log.info("Found {} currently running containers: {}", runningContainers.size(), runningContainers);
    return runningContainers;
  }

  private List<String> getAllCurrentlyRunningValidatorContainers() {
    List<String> runningValidatorContainers = new ArrayList<>();

    for (String containerName : VALIDATOR_CONTAINERS) {
      try {
        String containerId = getContainerIdByName(containerName);
        if (containerId != null) {
          // Double-check that container is actually running
          InspectContainerResponse inspectResponse =
              dockerClient.inspectContainerCmd(containerId).exec();
          if (inspectResponse.getState().getRunning()) {
            runningValidatorContainers.add(containerName);
          }
        }
      } catch (Exception e) {
        log.debug("Validator container {} not running", containerName);
      }
    }

//    log.info(
//        "Found {} currently running containers: {}",
//        runningValidatorContainers.size(),
//        runningValidatorContainers);
    return runningValidatorContainers;
  }

  private String getContainerIdByName(String containerName) {
    try {
      return dockerClient.listContainersCmd().withNameFilter(List.of(containerName)).exec().stream()
          .findFirst()
          .map(c -> c.getId())
          .orElse(null);
    } catch (Exception e) {
      log.warn("Container {} not found", containerName);
      return null;
    }
  }

  private Map<String, String> getContainerVolumeMap(List<String> containers) {
    Map<String, String> containerVolumes = new HashMap<>();

    for (String containerName : containers) {
      String containerId = getContainerIdByName(containerName);
      if (containerId != null) {
        String volumeName = getCurrentVolume(dockerClient, containerId);
        if (volumeName != null) {
          containerVolumes.put(containerName, volumeName);
        }
      }
    }

    return containerVolumes;
  }

  private String getActiveNodeIdFromVolume() {
    try {
      String genesisContainerId = getGenesisContainerId();
      if (StringUtils.isEmpty(genesisContainerId)) {
        return "0"; // Default to root if no genesis container
      }

      String currentVolume = getCurrentVolume(dockerClient, genesisContainerId);
      if ((currentVolume == null) || currentVolume.equals("mylocalton-docker_ton-db-val0")) {
        return "0";
      }

      // Determine active node ID based on current volume name
      if (currentVolume.contains("snapshot-")) {
        String parts[] = currentVolume.split("snapshot-");
        if (parts.length > 1) {
          String numberPart = parts[1];
          return numberPart;
        }
      }

      return "0"; // Default to root for base volume
    } catch (Exception e) {
      log.warn("Error determining active node ID from volume: {}", e.getMessage());
      return "0";
    }
  }

  private void copyVolume(
      DockerClient dockerClient, String sourceVolumeName, String targetVolumeName)
      throws InterruptedException {

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

    // Generate unique container name to avoid conflicts in parallel operations
    String uniqueContainerName =
        "taking-snapshot-" + System.currentTimeMillis() + "-" + Thread.currentThread().getId();

    // Copy data to backup volume
    String copyContainerId =
        dockerClient
            .createContainerCmd("alpine")
            .withCmd("/bin/sh", "-c", "cp -rTv /from/. /to/.")
            .withVolumes(new Volume("/from"), new Volume("/to"))
            .withName(uniqueContainerName)
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
      String nodeType = request.get("nodeType"); // "snapshot" or "instance"
      String instanceNumberStr = request.get("instanceNumber");
      String seqnoStr = request.get("seqno"); // seqno from frontend

      log.info(
          "/restore-snapshot, snapshotId: {}, snapshotNumber: {}, instanceNumber {}",
          snapshotId,
          snapshotNumber,
          instanceNumberStr);

      SnapshotConfig snapshotConfig = loadSnapshotConfiguration(snapshotId);
      SnapshotConfig snapshotConfigNew = loadSnapshotConfiguration(snapshotId);

      int instanceNumber = 0;
      boolean isNewInstance = false;
      long lastKnownSeqno = 0;

      currentSnapshotStatus = "Saving current blockchain state...";

      try {
        MasterchainInfo masterChainInfo = getMasterchainInfo();
        if (masterChainInfo != null) {
          lastKnownSeqno = masterChainInfo.getLast().getSeqno();
          log.info("Captured last known seqno before restoration: {}", lastKnownSeqno);
        }
      } catch (Exception e) {
        log.warn("Could not get current seqno before restoration, using 0: {}", e.getMessage());
      }

      String snapshotAndInstanceNumber = "";
      if ("instance".equals(nodeType)) { // todo
        log.info("restore instance");
//        // Restoring from instance node - reuse existing volumes for containers that have them
//        if (instanceNumberStr != null) {
//          instanceNumber = Integer.parseInt(instanceNumberStr);
//          snapshotAndInstanceNumber = String.valueOf(instanceNumber);
//        }

      } else { // copy volumes
        // Restoring from snapshot node - create new instances for containers that have snapshots
        instanceNumber = getNextInstanceNumber(Integer.parseInt(snapshotNumber));
        isNewInstance = true;

        snapshotAndInstanceNumber = snapshotNumber + "-" + instanceNumber;

        snapshotConfigNew.setSnapshotNumber(snapshotAndInstanceNumber);

        log.info(
            "instanceNumber: {}, newSnapshotNumber {}", instanceNumber, snapshotAndInstanceNumber);

        for (DockerContainer dockerContainer : snapshotConfig.getCoreContainers()) { // todo review
          String containerName = dockerContainer.getName();
          String oldVolume = dockerContainer.getTonDbVolumeName();
          String newVolume =
              CONTAINER_VOLUME_MAP.get(containerName) + "-snapshot-" + snapshotAndInstanceNumber;

          try {
            log.info("Copy volume {} to {}", oldVolume, newVolume);
            copyVolume(dockerClient, oldVolume, newVolume);
            replaceVolumeInConfig(snapshotConfigNew, containerName, oldVolume, newVolume);
          } catch (NotFoundException e) {
            log.error("error copying volume {}->{}", oldVolume, newVolume);
            throw new RuntimeException("error copying volume: " + oldVolume + "->" + newVolume);
          }
        }

        storeSnapshotConfiguration(snapshotConfigNew);
      }

      currentSnapshotStatus = "Stopping blockchain...";
      stopAndRemoveAllContainers();

      currentSnapshotStatus = "Starting blockchain from the snapshot...";

      createContainerGroup(snapshotConfigNew.getCoreContainers());

      log.info("Snapshots restored for all containers using snapshotId: {}", snapshotId);

      currentSnapshotStatus = "Waiting for lite-server to be ready";

      if (waitForSeqnoVolumeHealthy()) {
        currentSnapshotStatus = "Starting extra-services...";
        createContainerGroup(snapshotConfigNew.getExtraContainers());

        Map<String, Object> response = new HashMap<>();
        response.put("success", true);
        response.put("message", "Snapshots restored successfully for all containers");
        response.put("id", snapshotAndInstanceNumber);
        response.put("instanceNumber", instanceNumber);
        response.put("isNewInstance", isNewInstance);
        response.put("lastKnownSeqno", lastKnownSeqno); // Include the captured seqno for frontend
        return response;
      } else {
        currentSnapshotStatus = "Blockchain cannot be started, see docker logs.";
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "Blockchain cannot be started, see docker logs.");
        return response;
      }

    } catch (Exception e) {
      log.error("Error restoring snapshots", e);
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to restore snapshots: " + e.getMessage());
      return response;
    }
  }

  private long getCurrentBlockSequence() throws Exception {
    return getMasterchainInfo().getLast().getSeqno();
  }

  public synchronized MasterchainInfo getMasterchainInfo() throws Exception {
    return Main.adnlLiteClient.getMasterchainInfo();
  }

  private int getNextInstanceNumber(int snapshotNumber) {
    try {
      List<InspectVolumeResponse> volumes = dockerClient.listVolumesCmd().exec().getVolumes();
      int maxInstanceNumber = 0;

      // Check validator instances
      List<String> validatorInstancePrefixes = new ArrayList<>();
      for (String validatorContainer : VALIDATOR_CONTAINERS) {
        String baseVolumeName = CONTAINER_VOLUME_MAP.get(validatorContainer);
        validatorInstancePrefixes.add(baseVolumeName + "-snapshot-" + snapshotNumber + "-");
      }

      for (InspectVolumeResponse volume : volumes) {
        String volumeName = volume.getName();
        // Check if this is a validator instance volume
        for (String validatorPrefix : validatorInstancePrefixes) {
          if (volumeName.startsWith(validatorPrefix)) {
            try {
              String numberPart = volumeName.substring(validatorPrefix.length());

              int instanceNumber = Integer.parseInt(numberPart);
              maxInstanceNumber = Math.max(maxInstanceNumber, instanceNumber);
            } catch (NumberFormatException e) {
              // Skip volumes that don't have valid number suffix
              log.warn("Invalid validator instance volume name format: {}", volumeName);
            }
            break; // Found matching prefix, no need to check other prefixes
          }
        }
      }

      return maxInstanceNumber + 1;
    } catch (Exception e) {
      log.error("Error determining next instance number for snapshot {}", snapshotNumber, e);
      // Fallback to 1 if volume listing fails
      return 1;
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

  @PostMapping("/delete-snapshot")
  public Map<String, Object> deleteSnapshot(@RequestBody Map<String, Object> request) {
    try {
      String snapshotId = (String) request.get("snapshotId");
      String snapshotNumber = String.valueOf(request.get("snapshotNumber"));
      String nodeType = (String) request.get("nodeType");
      String instanceNumber =
          request.get("instanceNumber") != null
              ? String.valueOf(request.get("instanceNumber"))
              : null;
      Boolean hasChildren = (Boolean) request.get("hasChildren");

      log.info(
          "Deleting snapshot: id: {}, snapshotNumber: {}, instanceNumber: {} type: {}, hasChildren: {}",
          snapshotId,
          snapshotNumber,
          instanceNumber,
          nodeType,
          hasChildren);

      String snapshotInstanceNumber =
          isNull(instanceNumber) ? snapshotNumber : snapshotNumber + "-" + instanceNumber;

      SnapshotConfig snapshotConfig = loadSnapshotConfiguration(snapshotInstanceNumber);
      Map<String, Object> response = new HashMap<>();

      if (isNull(snapshotConfig)) {
        response.put("success", true);
        response.put("message", "Snapshot not found, nothing to delete");
        return response;
      }

      // Check if any of the volumes to delete are currently in use
      String genesisContainerId = getGenesisContainerId();
      String currentVolume = null;

      if (!StringUtils.isEmpty(genesisContainerId)) {
        currentVolume = getCurrentVolume(dockerClient, genesisContainerId);
      }













      // Build list of volumes to delete from nodesToDelete list
      List<String> volumesToDelete = new ArrayList<>();

      @SuppressWarnings("unchecked")
      List<Map<String, Object>> nodesToDelete = (List<Map<String, Object>>) request.get("nodesToDelete");

      if (nodesToDelete != null && !nodesToDelete.isEmpty()) {
        // Delete volumes for all nodes in the list (including all container types)
        for (Map<String, Object> nodeToDelete : nodesToDelete) {

          log.info("node to delete {}", nodeToDelete.get("id"));
          deleteSnapshotConfiguration(nodeToDelete.get("id").toString());

            for (String validatorContainer : VALIDATOR_CONTAINERS) {
              String baseVolumeName = CONTAINER_VOLUME_MAP.get(validatorContainer);
              String validatorInstanceVolume =
                  baseVolumeName + "-snapshot-" + nodeToDelete.get("id");
              volumesToDelete.add(validatorInstanceVolume);
            }

        }
      }

      log.info("to delete {}", List.of(volumesToDelete).toArray());

      if (currentVolume != null && volumesToDelete.contains(currentVolume)) {
        log.warn("Attempting to delete currently active volume: {}", currentVolume);

        // If trying to delete active volume, return error immediately
        response.put("success", false);
        response.put("message", "Cannot delete currently active snapshot. Please switch to a different snapshot first.");
        response.put("deletingActiveVolume", true);
        return response;
      }

      // Delete the volumes
      List<String> deletedVolumes = new ArrayList<>();
      List<String> failedVolumes = new ArrayList<>();

      for (String volumeName : volumesToDelete) {
        try {
          // Check if volume exists
          dockerClient.inspectVolumeCmd(volumeName).exec();

          // If this is the active volume, we cannot delete it
          if (volumeName.equals(currentVolume)) {
            log.error("Cannot delete active volume: {}", volumeName);
            failedVolumes.add(volumeName + " (currently active)");
            continue;
          }

          // Delete the volume
          dockerClient.removeVolumeCmd(volumeName).exec();

          deletedVolumes.add(volumeName);
          log.info("Successfully deleted volume: {}", volumeName);

        } catch (NotFoundException e) {
          log.warn("Volume not found (already deleted?): {}", volumeName);
          // Consider this a success since the volume is gone
          deletedVolumes.add(volumeName + " (not found)");
        } catch (Exception e) {
          log.error("Failed to delete volume: {}", volumeName, e);
          failedVolumes.add(volumeName + " (" + e.getMessage() + ")");
        }
      }

      if (failedVolumes.isEmpty()) {
        response.put("success", true);
        response.put("message", "Snapshot deleted successfully");
        response.put("deletedVolumes", deletedVolumes);
      } else {
        response.put("success", false);
        response.put("message", "Failed to delete some volumes: " + String.join(", ", failedVolumes));
        response.put("deletedVolumes", deletedVolumes);
        response.put("failedVolumes", failedVolumes);
      }



//
//      // Delete the volumes
//      List<String> deletedVolumes = new ArrayList<>();
//      List<String> failedVolumes = new ArrayList<>();
//
//      for (String volumeName : volumesToDelete) {
//        try {
//          // Check if volume exists
//          dockerClient.inspectVolumeCmd(volumeName).exec();
//
//          // If this is the active volume, we cannot delete it
//          if (volumeName.equals(currentVolume)) {
//            log.error("Cannot delete active volume: {}", volumeName);
//            failedVolumes.add(volumeName + " (currently active)");
//            continue;
//          }
//
//          // Delete the volume
//          dockerClient.removeVolumeCmd(volumeName).exec();
//          deletedVolumes.add(volumeName);
//          log.info("Successfully deleted volume: {}", volumeName);
//
//        } catch (NotFoundException e) {
//          log.warn("Volume not found (already deleted?): {}", volumeName);
//          // Consider this a success since the volume is gone
//          deletedVolumes.add(volumeName + " (not found)");
//        } catch (Exception e) {
//          log.error("Failed to delete volume: {}", volumeName, e);
//          failedVolumes.add(volumeName + " (" + e.getMessage() + ")");
//        }
//      }
//
//      if (failedVolumes.isEmpty()) {
//        deleteSnapshotConfiguration(snapshotInstanceNumber);
//        response.put("success", true);
//        response.put("message", "Snapshot deleted successfully");
//        response.put("deletedVolumes", deletedVolumes);
//        response.put("deletingActiveVolume", deletingActiveVolume);
//      } else {
//        response.put("success", false);
//        response.put(
//            "message", "Failed to delete some volumes: " + String.join(", ", failedVolumes));
//        response.put("deletedVolumes", deletedVolumes);
//        response.put("failedVolumes", failedVolumes);
//        response.put("deletingActiveVolume", deletingActiveVolume);
//      }

      return response;

    } catch (Exception e) {
      log.error("Error deleting snapshot", e);
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to delete snapshot: " + e.getMessage());
      return response;
    }
  }

  private void stopAndRemoveAllContainers() {
    //    log.info("Stopping and removing all containers in parallel");

    // Get all running containers that we manage
    List<String> runningContainers = getAllContainers();

    if (runningContainers.isEmpty()) {
      log.info("No containers to stop");
      return;
    }

    stopAndRemoveSpecificContainers(runningContainers);
  }

  /**
   * Stops and removes specific containers by name with proper shutdown ordering. Extra services are
   * stopped first, then genesis+validators. This method ensures all containers from the list are
   * removed, regardless of their current state.
   */
  private void stopAndRemoveSpecificContainers(List<String> containerNames) {

    if (containerNames.isEmpty()) {
      log.info("No containers to stop");
      return;
    }

    // Separate containers into core blockchain (genesis + validators) and extra services
    List<String> coreContainers = new ArrayList<>();
    List<String> extraServices = new ArrayList<>();

    for (String containerName : containerNames) {
      if (CONTAINER_GENESIS.equals(containerName)
          || Arrays.asList(VALIDATOR_CONTAINERS).contains(containerName)) {
        coreContainers.add(containerName);
      } else {
        extraServices.add(containerName);
      }
    }

    log.info("Core containers to stop: {}", coreContainers);
    log.info("Extra services to stop: {}", extraServices);

    if (!extraServices.isEmpty()) {
      log.info("STEP 1: Stopping extra services first");
      stopAndRemoveContainerGroup(extraServices);
    }

    if (!coreContainers.isEmpty()) {
      log.info("STEP 2: Stopping core blockchain containers");
      stopAndRemoveContainerGroup(coreContainers);
    }
  }

  /** Helper method to stop and remove a group of containers in parallel. */
  private void stopAndRemoveContainerGroup(List<String> containerNames) {
    Map<String, String> containerIds = new HashMap<>();
    try {
      List<Container> allContainers = dockerClient.listContainersCmd().withShowAll(true).exec();

      for (String containerName : containerNames) {
        for (Container container : allContainers) {
          // Check if container name matches (Docker container names start with "/")
          if (container.getNames() != null) {
            for (String name : container.getNames()) {
              if (name.equals("/" + containerName)) {
                containerIds.put(containerName, container.getId());
                break;
              }
            }
          }
          if (containerIds.containsKey(containerName)) {
            break; // Found this container, move to next
          }
        }
      }
    } catch (Exception e) {
      log.error("Error listing containers: {}", e.getMessage());
      // Fallback to checking only running containers
      for (String containerName : containerNames) {
        String containerId = getContainerIdByName(containerName);
        if (containerId != null) {
          containerIds.put(containerName, containerId);
        }
      }
    }

    if (containerIds.isEmpty()) {
      log.info("No containers found to remove");
      return;
    }

//    log.info("Stopping {} containers in parallel", containerIds.size());

    List<CompletableFuture<Void>> stopFutures =
        containerIds.entrySet().stream()
            .map(
                entry ->
                    CompletableFuture.runAsync(
                        () -> {
                          String containerName = entry.getKey();
                          String containerId = entry.getValue();
                          try {
                            dockerClient.killContainerCmd(containerId).exec();
                            log.info("container stopped: {}", containerName);
                          } catch (Exception e) {
                            log.warn(
                                "Failed to stop container {}: {}", containerName, e.getMessage());
                          }
                        }))
            .toList();

    CompletableFuture<Void> allStopFutures =
        CompletableFuture.allOf(stopFutures.toArray(new CompletableFuture[0]));

    try {
      allStopFutures.get(); // Wait for all containers to stop
    } catch (Exception e) {
      log.error("Error waiting for containers to stop: {}", e.getMessage());
    }

//    log.info("Removing {} containers in parallel", containerIds.size());

    List<CompletableFuture<Void>> removeFutures =
        containerIds.entrySet().stream()
            .map(
                entry ->
                    CompletableFuture.runAsync(
                        () -> {
                          String containerName = entry.getKey();
                          String containerId = entry.getValue();
                          try {
                            dockerClient.removeContainerCmd(containerId).withForce(true).exec();
                            log.info("container removed: {}", containerName);
                          } catch (Exception e) {
                            log.warn("Failed to remove container {}", containerName);
                          }
                        }))
            .toList();

    CompletableFuture<Void> allRemoveFutures =
        CompletableFuture.allOf(removeFutures.toArray(new CompletableFuture[0]));

    try {
      allRemoveFutures.get(); // Wait for all containers to be removed
    } catch (Exception e) {
      log.error("Error waiting for containers to be removed: {}", e.getMessage());
    }
  }

  /** Helper method to recreate a group of containers in parallel. */
  private void createContainerGroup(List<DockerContainer> containers) {

//    log.info("Recreating {} containers in parallel", containers.size());

    // Create containers in this group in parallel
    List<CompletableFuture<Void>> recreateFutures =
        containers.stream()
            .map(
                entry ->
                    CompletableFuture.runAsync(
                        () -> {
                          String containerName = entry.getName();
                          String targetVolume = entry.getTonDbVolumeName();
                          DockerContainer dockerContainer = entry;
                          try {
                            log.info("Creating: {} with volume {}", containerName, targetVolume);
                            createContainerWithConfig(dockerContainer);
                          } catch (Exception e) {
                            log.error(
                                "Failed to recreate container {}: {}",
                                containerName,
                                e.getMessage());
                          }
                        }))
            .toList();

    CompletableFuture<Void> allRecreateFutures =
        CompletableFuture.allOf(recreateFutures.toArray(new CompletableFuture[0]));

    try {
      allRecreateFutures.get(); // Wait for all containers in this group to be recreated
    } catch (Exception e) {
      log.error("Error waiting for containers to be recreated: {}", e.getMessage());
    }
  }

  private void createContainerWithConfig(DockerContainer dockerContainer) {

    ContainerConfig config = dockerContainer.getContainerConfig();
    HostConfig hostConfig = dockerContainer.getHostConfig();
    String ipAddress = dockerContainer.getIp();

    String[] envs = config.getEnv();

    ExposedPort[] exposedPorts = config.getExposedPorts();
    HealthCheck healthCheck = config.getHealthcheck();
    String networkMode = hostConfig.getNetworkMode();

    // Create new container with the saved configuration but new volume
    CreateContainerCmd createCmd =
        dockerClient
            .createContainerCmd(config.getImage())
            .withName(dockerContainer.getName())
            .withEnv(envs)
            .withHealthcheck(healthCheck)
            .withHostConfig(hostConfig);

    if (exposedPorts != null) {
      createCmd.withExposedPorts(exposedPorts);
    }

    if (config.getCmd() != null) {
      createCmd.withCmd(config.getCmd());
    }

    if (ipAddress != null) {
      createCmd.withIpv4Address(ipAddress);
    }
    dockerClient.startContainerCmd(createCmd.exec().getId()).exec();
  }

  public static DockerClient createDockerClient() {
    DefaultDockerClientConfig defaultConfig =
        DefaultDockerClientConfig.createDefaultConfigBuilder().build();

    var httpClient =
        new OkDockerHttpClient.Builder()
            .dockerHost(defaultConfig.getDockerHost())
            .sslConfig(defaultConfig.getSSLConfig())
            .build();

    return DockerClientBuilder.getInstance(defaultConfig).withDockerHttpClient(httpClient).build();
  }

  private boolean waitForSeqnoVolumeHealthy() {
    int maxRetries = 30;
    int retryCount = 0;

    log.info("waitForSeqnoVolumeHealthy...");

    while (retryCount < maxRetries) {
      try {
        long delta = getSyncDelay();
        log.info("Sync delay: {} seconds (attempt {})", delta, retryCount + 1);

        if (delta < 10) {
          log.info(
              "waitForSeqnoVolumeHealthy is healthy after {} attempts (sync delay: {} seconds)",
              retryCount + 1,
              delta);
          return true; // Success, exit the method
        }

      } catch (Exception e) {
        log.warn("waitForSeqnoVolumeHealthy error (attempt {})", retryCount + 1);
        // Don't return on error, continue trying
      }

      retryCount++;

      // Wait 5 seconds before next attempt
      try {
        Thread.sleep(5000);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        log.warn("Health check interrupted");
        return false;
      }
    }

    log.warn(
        "Seqno-volume endpoint did not become healthy after {} attempts (max {} minutes), but continuing anyway",
        maxRetries,
        maxRetries * 5 / maxRetries);
    return false;
  }

  public long getSyncDelay() throws Exception {
    MasterchainInfo masterChainInfo = getMasterchainInfo();
    Block block = Main.adnlLiteClient.getBlock(masterChainInfo.getLast()).getBlock();
    return Utils.now() - block.getBlockInfo().getGenuTime();
  }

  private void storeSnapshotConfiguration(SnapshotConfig snapshotConfig) throws Exception {
    String configPath =
        "/usr/share/data/config-snapshot-" + snapshotConfig.getSnapshotNumber() + ".json";
    log.info("saving {}", configPath);

    File dataDir = new File("/usr/share/data");
    if (!dataDir.exists()) {
      dataDir.mkdirs();
    }
    Gson gson =
        new GsonBuilder()
            .setPrettyPrinting()
            .registerTypeAdapter(Ports.class, new PortsSerializer())
            .create();
    String jsonContent = gson.toJson(snapshotConfig);
    Files.write(Paths.get(configPath), jsonContent.getBytes());
  }

  private boolean isConfigExist(int snapshotNumber) {
    return Files.exists(Path.of("/usr/share/data/config-snapshot-" + snapshotNumber + ".json"));
  }

  private void deleteSnapshotConfiguration(String snapshotNumber) throws Exception {
    String configPath = "/usr/share/data/config-snapshot-" + snapshotNumber + ".json";
    log.info("deleting {}", configPath);
    File configFile = new File(configPath);

    if (!configFile.exists()) {
      log.error(
          "Snapshot configuration file not found for snapshot {}: {}", snapshotNumber, configPath);
    }

    Files.delete(Paths.get(configPath));
  }

  private SnapshotConfig loadSnapshotConfiguration(String snapshotNumber) throws Exception {
    String configPath = "/usr/share/data/config-snapshot-" + snapshotNumber + ".json";
    log.info("loading {}", configPath);
    File configFile = new File(configPath);

    if (!configFile.exists()) {
      log.error(
          "Snapshot configuration file not found for snapshot {}: {}", snapshotNumber, configPath);
      return null;
    }

    String content = new String(Files.readAllBytes(Paths.get(configPath)));
    Gson gson =
        new GsonBuilder().registerTypeAdapter(Ports.class, new PortsDeserializer()).create();

    return gson.fromJson(content, SnapshotConfig.class);
  }

  @PostMapping("/stop-blockchain")
  public Map<String, Object> stopBlockchain() {
    try {
      log.info("Stopping blockchain - stopping and removing all containers except time-machine");
      currentSnapshotStatus = "Stopping blockchain...";

      List<String> containersToStop = getAllRunningContainers();

      if (containersToStop.isEmpty()) {
        log.info("No containers found to stop");
        Map<String, Object> response = new HashMap<>();
        response.put("success", true);
        response.put("message", "No containers found to stop");
        response.put("stoppedContainers", 0);
        return response;
      }

      log.info("Stopping {} running containers: {}", containersToStop.size(), containersToStop);

      stopAndRemoveSpecificContainers(containersToStop);

      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("message", "Blockchain stopped successfully");
      response.put("stoppedContainers", containersToStop.size());
      response.put("containerNames", containersToStop);

      log.info("Successfully stopped {} containers", containersToStop.size());
      return response;

    } catch (Exception e) {
      log.error("Error stopping blockchain", e);
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to stop blockchain: " + e.getMessage());
      return response;
    }
  }

  private List<String> getAllContainers() {

    return Arrays.asList(
        "genesis",
        "blockchain-explorer",
        "validator-1",
        "validator-2",
        // "file-server",
        // "time-machine-server",
        "explorer-restarter",
        "ton-http-api-v2",
        "validator-3",
        "validator-4",
        "validator-5",
        "faucet",
        "data-generator",
        "index-event-cache",
        "index-event-classifier",
        "index-api",
        "index-worker",
        "index-postgres");
  }

  /**
   * Adds or updates CUSTOM_PARAMETERS environment variable with -T seqno flag
   *
   * @param envs existing environment variables array
   * @param seqnoStr seqno value from frontend
   * @return updated environment variables array with CUSTOM_PARAMETERS containing -T seqno
   */
  private String[] addCustomParametersWithSeqno(String[] envs, String seqnoStr) {
    try {
      // Use seqno from frontend parameter, fallback to current if not provided
      String seqnoFlag = "";
      if (seqnoStr != null && !seqnoStr.trim().isEmpty() && (Long.parseLong(seqnoStr) != 0)) {
        seqnoFlag = "-T " + seqnoStr.trim();
        log.info("Using seqno from frontend: {}", seqnoStr);
      } else {
        log.error("Wrong seqno from frontend {}", seqnoStr);
        return envs;
      }

      log.info("Adding CUSTOM_PARAMETERS with seqno flag: {}", seqnoFlag);

      List<String> envList = new ArrayList<>();
      boolean customParamsFound = false;

      // Process existing environment variables
      if (envs != null) {
        for (String env : envs) {
          if (env.startsWith("CUSTOM_PARAMETERS=")) {
            // Found existing CUSTOM_PARAMETERS, replace any existing -T parameter
            String existingValue = env.substring("CUSTOM_PARAMETERS=".length());
            String newValue = replaceOrAddTParameter(existingValue, seqnoFlag);
            envList.add("CUSTOM_PARAMETERS=" + newValue);
            customParamsFound = true;
            log.info("Updated existing CUSTOM_PARAMETERS: {} -> {}", existingValue, newValue);
          } else {
            envList.add(env);
          }
        }
      }

      // If CUSTOM_PARAMETERS wasn't found, add it
      if (!customParamsFound) {
        envList.add("CUSTOM_PARAMETERS=" + seqnoFlag);
        log.info("Added new CUSTOM_PARAMETERS: {}", seqnoFlag);
      }

      return envList.toArray(new String[0]);

    } catch (Exception e) {
      log.error("Error adding CUSTOM_PARAMETERS with seqno: {}", e.getMessage());
      // Return original envs if there's an error
      return envs;
    }
  }

  /**
   * Replaces existing -T parameter or adds new one to the custom parameters string
   *
   * @param existingParams existing custom parameters string
   * @param newTParam new -T parameter to add (e.g., "-T 61")
   * @return updated parameters string with only one -T parameter
   */
  private String replaceOrAddTParameter(String existingParams, String newTParam) {
    if (existingParams == null || existingParams.trim().isEmpty()) {
      return newTParam;
    }

    // Split parameters by spaces, but be careful with quoted values
    List<String> params = new ArrayList<>();
    String[] parts = existingParams.trim().split("\\s+");

    boolean skipNext = false;
    for (int i = 0; i < parts.length; i++) {
      if (skipNext) {
        skipNext = false;
        continue;
      }

      String part = parts[i];
      if ("-T".equals(part)) {
        // Skip this -T and its value
        skipNext = true;
        continue;
      }

      params.add(part);
    }

    // Add the new -T parameter
    params.add(newTParam);

    return String.join(" ", params);
  }

  DockerContainer getDockerContainerConfiguration(String containerName) {
    try {
      String containerId = getContainerIdByName(containerName);
      ContainerConfig containerConfig;
      HostConfig hostConfig;
      String ip = "";

      if (containerId != null) {
        InspectContainerResponse inspectResponse =
            dockerClient.inspectContainerCmd(containerId).exec();
        containerConfig = inspectResponse.getConfig();
        hostConfig = inspectResponse.getHostConfig();

        String volumeName = getCurrentVolume(dockerClient, containerId);

        // Get IP address if available
        try {
          if (inspectResponse.getNetworkSettings() != null
              && inspectResponse.getNetworkSettings().getNetworks() != null
              && !inspectResponse.getNetworkSettings().getNetworks().isEmpty()) {
            String ipAddress =
                inspectResponse
                    .getNetworkSettings()
                    .getNetworks()
                    .values()
                    .iterator()
                    .next()
                    .getIpAddress();
            if (ipAddress != null) {
              ip = ipAddress;
            }
          }
        } catch (Exception e) {
          log.warn(
              "Could not retrieve IP address for container {}: {}", containerName, e.getMessage());
        }
        return DockerContainer.builder()
            .name(containerName)
            .ip(ip)
            .hostConfig(hostConfig)
            .containerConfig(containerConfig)
            .tonDbVolumeName(volumeName)
            .build();
      }
    } catch (Exception e) {
      log.warn("Could not get configuration for container {}: {}", containerName, e.getMessage());
    }
    return null;
  }

  private void replaceVolumeInConfig(
      SnapshotConfig snapshotConfig, String containerName, String oldVolume, String newVolume) {
    DockerContainer dockerContainer = snapshotConfig.getContainers().get(containerName);
    List<Bind> binds = new ArrayList<>();
    for (Bind bind : dockerContainer.getHostConfig().getBinds()) {
      if (bind.getPath().equals(oldVolume)) {
        Bind bindNew = new Bind(newVolume, bind.getVolume(), bind.getAccessMode());
        binds.add(bindNew);
      } else {
        binds.add(bind);
      }
    }
    Binds bindsT = new Binds(binds.toArray(new Bind[0]));
    dockerContainer.getHostConfig().withBinds(bindsT);
    dockerContainer.setTonDbVolumeName(newVolume);
  }
}
