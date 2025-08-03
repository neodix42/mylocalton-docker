package org.ton.mylocaltondocker.timemachine.controller;

import static com.github.dockerjava.api.model.HostConfig.newHostConfig;
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
      "validator-1", "validator-2", "validator-3", "validator-4", "validator-5"
  };
  public static final String[] ALL_CONTAINERS = {
      CONTAINER_GENESIS, "validator-1", "validator-2", "validator-3", "validator-4", "validator-5"
  };
  public static final Map<String, String> CONTAINER_VOLUME_MAP = Map.of(
      "genesis", "ton-db-val0",
      "validator-1", "ton-db-val1",
      "validator-2", "ton-db-val2",
      "validator-3", "ton-db-val3",
      "validator-4", "ton-db-val4",
      "validator-5", "ton-db-val5"
  );
  String error;

  private final ConcurrentHashMap<String, Bucket> sessionBuckets = new ConcurrentHashMap<>();

  DockerClient dockerClient = createDockerClient();

  @GetMapping("/seqno-volume")
  public Map<String, Object> getSeqno() throws Exception {
    try {
//      log.info("Getting seqno-volume");

      String genesisContainerId = getGenesisContainerId();

      if (StringUtils.isEmpty(genesisContainerId)) {
        log.error("seqno-volume, Container not found");
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "Container not found");
        return response;
      }

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

      String volume = getCurrentVolume(dockerClient, genesisContainerId);
      int activeNodes = getActiveNodesCount();
      long syncDelay = getSyncDelay();
      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("seqno", masterChainInfo.getLast().getSeqno());
      response.put("volume", volume);
      response.put("activeNodes", activeNodes);
      response.put("syncDelay", syncDelay);
//      log.info("return seqno-volume {} {}", masterChainInfo.getLast().getSeqno(), volume);
      return response;
    } catch (Throwable e) {
      log.warn("Error getting seqno-volume, attempting reinit");

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
      int activeNodes = getActiveNodesCount();
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

  private int getActiveNodesCount() {
    int count = 0;

    // Check genesis container
    try {
      String genesisId = getGenesisContainerId();
      if (!StringUtils.isEmpty(genesisId)) {
        count++;
      }
    } catch (Exception e) {
      log.debug("Genesis container not running");
    }

    // Check up to 5 validator containers
    for (String validatorContainer : VALIDATOR_CONTAINERS) {
      try {
        List<Container> containers = dockerClient
            .listContainersCmd()
            .withNameFilter(List.of(validatorContainer))
            .exec();
        if (!containers.isEmpty()) {
          count++;
        }
      } catch (Exception e) {
        log.debug("Validator container {} not running", validatorContainer);
      }
    }

    return count;
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

      // Get sequential snapshot number from request or generate next one
      String snapshotNumber;
      if (request.containsKey("snapshotNumber")) {
        snapshotNumber = request.get("snapshotNumber");
        log.info("got snapshot number from request {}", snapshotNumber);
      }
      else {
        // Fallback: generate next sequential number by counting existing volumes
        snapshotNumber = String.valueOf(getNextSnapshotNumber(dockerClient));
        log.info("getting next snapshot number {}", snapshotNumber);
      }


      if (!isConfigExist(0)) { // if name ROOT
        SnapshotConfig snapshotConfig = getCurrentSnapshotConfig();
        snapshotConfig.setSnapshotNumber("0");
        snapshotConfig.setTimestamp(System.currentTimeMillis());
        storeSnapshotConfiguration(snapshotConfig);
      }

      String snapshotId = "snapshot-" + snapshotNumber;

      log.info("Found running containers: {}", runningContainers);

      // Check if we're taking snapshot from active (running) node
      String parentId = request.get("parentId");
      String activeNodeId = getActiveNodeIdFromVolume();
      log.info("/take-snapshot, parentSnapshotNumber: {}, nextSnapshotNumber {}, activeNodeId {}" , parentId, snapshotNumber, activeNodeId);

      boolean isFromActiveNode = parentId != null && parentId.equals(activeNodeId);

      // Only shutdown blockchain if taking snapshot from active node AND multiple validators are running
      long validatorCount = runningContainers.stream()
          .filter(containerName -> !CONTAINER_GENESIS.equals(containerName))
          .count();

      boolean shouldShutdownBlockchain = isFromActiveNode && validatorCount > 0;
      log.info("Taking snapshot from active node: {}, Validator containers running: {}, should shutdown blockchain: {}",
          isFromActiveNode, validatorCount, shouldShutdownBlockchain);


      /// --------------------------------------------------------------------------------
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

      log.info("snapshots loaded");


//      log.info("snapshotConfig: {}", snapshotConfig);

      if (shouldShutdownBlockchain) {
        currentSnapshotStatus = "Stopping blockchain...";
        log.info("Shutting down blockchain (all containers) before taking snapshots");
        stopAndRemoveAllContainers();
      }

      // Create snapshots for all containers in parallel
      currentSnapshotStatus = "Taking snapshots...";

      // copy volumes in parallel
      snapshotConfig.getContainers().entrySet().parallelStream()
          .forEach(
              entry -> {
                String containerName = entry.getKey();
                String currentVolume = entry.getValue().getTonDbVolumeName();
                String backupVolumeName = CONTAINER_VOLUME_MAP.get(containerName) + "-snapshot-" + snapshotNumber;

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
      snapshotConfig.getContainers().forEach((containerName, value) -> {
          String currentVolume = value.getTonDbVolumeName();
          String backupVolumeName = CONTAINER_VOLUME_MAP.get(containerName) + "-snapshot-" + snapshotNumber;
          replaceVolumeInConfig(snapshotConfigNew, containerName, currentVolume, backupVolumeName);
      });

      storeSnapshotConfiguration(snapshotConfigNew);

      // If blockchain was shutdown, restart it with the same volumes and configurations
      if (shouldShutdownBlockchain) {
        try {
          currentSnapshotStatus = "Starting blockchain...";

          // First, recreate containers that have volumes (genesis + validators)
          createAllContainersGroups(snapshotConfig, String.valueOf(lastSeqno));
          
          log.info("Blockchain restarted successfully after snapshot creation");
        } catch (Exception e) {
          log.error("Failed to restart blockchain after snapshot creation: {}", e.getMessage());
          // Add this to failed snapshots so the response indicates the issue
        }
      }

      // Get active nodes count to include in response
      int activeNodesCount = 0;
      try {
        activeNodesCount = getActiveNodesCount();
      } catch (Exception e) {
        log.warn("Could not get active nodes count for snapshot response: {}", e.getMessage());
      }

      Map<String, Object> response = new HashMap<>();

        currentSnapshotStatus = "Snapshot taken successfully";
        response.put("success", true);
        response.put("snapshotId", snapshotId);
        response.put("snapshotNumber", snapshotNumber);
        response.put("seqno", lastSeqno);
        response.put("volumeName", "ton-db-snapshot-" + snapshotNumber); // Keep for compatibility
        response.put("blockchainShutdown", shouldShutdownBlockchain);
        response.put("activeNodes", activeNodesCount); // Include active nodes count
        response.put("message", "Snapshots created successfully");


      isSnapshotInProgress = false;

      // Wait for lite-server to be ready before setting status to Ready
      currentSnapshotStatus = "Waiting for lite-server to be ready";
      if (waitForSeqnoVolumeHealthy()) {
        currentSnapshotStatus = "Ready";
      }
      else {
        response.put("success", false);
        response.put("message","Blockchain cannot be started, see docker logs.");
        currentSnapshotStatus = "Blockchain cannot be started, see docker logs.";
      }

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
    return
        dockerClient
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

    // Always check genesis
    try {
      String genesisId = getGenesisContainerId();
      if (!StringUtils.isEmpty(genesisId)) {
        runningContainers.add(CONTAINER_GENESIS);
      }
    } catch (Exception e) {
      log.warn("Genesis container not running");
    }

    // Check each validator
    for (String validatorContainer : VALIDATOR_CONTAINERS) {
      try {
        List<Container> containers = dockerClient
            .listContainersCmd()
            .withNameFilter(List.of(validatorContainer))
            .exec();
        if (!containers.isEmpty()) {
          runningContainers.add(validatorContainer);
        }
      } catch (Exception e) {
        log.debug("Validator container {} not running", validatorContainer);
      }
    }

    return runningContainers;
  }

  /**
   * Gets all currently running containers from the complete list of containers.
   * This includes genesis, validators, and all other services like faucet, data-generator, etc.
   */
  private List<String> getAllCurrentlyRunningContainers() {
    List<String> runningContainers = new ArrayList<>();
    List<String> allContainers = getAllContainers();

    for (String containerName : allContainers) {
      try {
        String containerId = getContainerIdByName(containerName);
        if (containerId != null) {
          // Double-check that container is actually running
          InspectContainerResponse inspectResponse = dockerClient.inspectContainerCmd(containerId).exec();
          if (inspectResponse.getState().getRunning()) {
            runningContainers.add(containerName);
          }
        }
      } catch (Exception e) {
        log.debug("Container {} not running", containerName);
      }
    }

    log.info("Found {} currently running containers: {}", runningContainers.size(), runningContainers);
    return runningContainers;
  }

  private String getContainerIdByName(String containerName) {
    try {
      return dockerClient
          .listContainersCmd()
          .withNameFilter(List.of(containerName))
          .exec()
          .stream()
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
      if (currentVolume == null) {
        return "0";
      }

      // Determine active node ID based on current volume name
      if (currentVolume.contains("ton-db-snapshot-")) {
        String parts[] = currentVolume.split("ton-db-snapshot-");
        if (parts.length > 1) {
          String numberPart = parts[1];

          // Check for instance format: ton-db-snapshot-10-1
          if (numberPart.matches("\\d+-\\d+")) {
            String[] instanceParts = numberPart.split("-");
            String snapshotNumber = instanceParts[0];
            String instanceNumber = instanceParts[1];
            return "snapshot-" + snapshotNumber + "-" + instanceNumber;
          }
          // Check for old "-latest" format
          else if (numberPart.endsWith("-latest")) {
            String snapshotNumber = numberPart.replace("-latest", "");
            return "snapshot-" + snapshotNumber + "-latest";
          }
          // Plain snapshot number
          else if (numberPart.matches("\\d+")) {
            return "snapshot-" + numberPart;
          }
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
    String uniqueContainerName = "taking-snapshot-" + System.currentTimeMillis() + "-" + Thread.currentThread().getId();

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

//      log.info("Volumes copied from {} to {} using container", sourceVolumeName, targetVolumeName);
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

      log.info("/restore-snapshot, snapshotId: {}, snapshotNumber: {}, instanceNumber {}", snapshotId, snapshotNumber, instanceNumberStr);

      SnapshotConfig snapshotConfig = loadSnapshotConfiguration(snapshotNumber);
      SnapshotConfig snapshotConfigNew = loadSnapshotConfiguration(snapshotNumber);


      int instanceNumber = 0;
      boolean isNewInstance = false;
      long lastKnownSeqno = 0;

//        if (!getAllRunningContainers().isEmpty()) { // if running

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


        if ("instance".equals(nodeType)) { // todo
          // Restoring from instance node - reuse existing volumes for containers that have them
          if (instanceNumberStr != null) {
            instanceNumber = Integer.parseInt(instanceNumberStr);
          }

        } else { // copy volumes
          // Restoring from snapshot node - create new instances for containers that have snapshots
          instanceNumber = getNextInstanceNumber(Integer.parseInt(snapshotNumber));
          isNewInstance = true;
          String snapshotAndInstanceNumber = snapshotNumber+"-"+instanceNumber;

          snapshotConfigNew.setSnapshotNumber(snapshotAndInstanceNumber);


          log.info("instanceNumber: {}, newSnapshotNumber {}", instanceNumber, snapshotAndInstanceNumber);

          for (DockerContainer dockerContainer : snapshotConfig.getCoreContainers()) { // todo review
            String containerName = dockerContainer.getName();
            String oldVolume = dockerContainer.getTonDbVolumeName();
            String newVolume = CONTAINER_VOLUME_MAP.get(containerName) + "-snapshot-" + snapshotAndInstanceNumber;
//            String backupVolumeName = CONTAINER_VOLUME_MAP.get(containerName) + "-snapshot-" + snapshotAndInstanceNumber;

            try {
//              dockerClient.inspectVolumeCmd(backupVolumeName).exec();
              log.info("Copy volume {} to {}", oldVolume, newVolume);
              copyVolume(dockerClient, oldVolume, newVolume);
              replaceVolumeInConfig(snapshotConfigNew,containerName, oldVolume, newVolume);
            } catch (NotFoundException e) {
              log.error("error copying volume {}->{}", oldVolume, newVolume);
              throw new RuntimeException("error copying volume: " + oldVolume+ "->"+ newVolume);
            }
          }

          storeSnapshotConfiguration(snapshotConfigNew);
        }


      // Stop and remove ALL containers (both running and stopped) that are mentioned in the stored config
      currentSnapshotStatus = "Stopping current blockchain...";
      stopAndRemoveAllContainers();

      currentSnapshotStatus = "Starting blockchain from the snapshot...";

      createContainerGroup(snapshotConfigNew.getCoreContainers());

      log.info("Snapshots restored for all containers using instance number: {}", instanceNumber);

      // Wait for lite-server to be ready before setting status to Ready
      currentSnapshotStatus = "Waiting for lite-server to be ready";
      if (waitForSeqnoVolumeHealthy()) {
        currentSnapshotStatus = "Starting extra-services...";
        createContainerGroup(snapshotConfigNew.getExtraContainers());

        Map<String, Object> response = new HashMap<>();
        response.put("success", true);
        response.put("message", "Snapshots restored successfully for all containers");
//        response.put("volumeName", containerTargetVolumes.get(CONTAINER_GENESIS)); // Keep for compatibility
        response.put("originalVolumeName", "ton-db-snapshot-" + snapshotNumber);
        response.put("instanceNumber", instanceNumber);
        response.put("isNewInstance", isNewInstance);
//        response.put("restoredContainers", containerTargetVolumes.keySet());
        response.put("lastKnownSeqno", lastKnownSeqno); // Include the captured seqno for frontend
        return response;
      }
      else {
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

  private int getNextInstanceNumber(int snapshotNumber) {
    try {
      List<InspectVolumeResponse> volumes = dockerClient.listVolumesCmd().exec().getVolumes();
      int maxInstanceNumber = 0;

      // Check genesis instances
      String genesisInstancePrefix = "ton-db-snapshot-" + snapshotNumber + "-";

      // Check validator instances
      List<String> validatorInstancePrefixes = new ArrayList<>();
      for (String validatorContainer : VALIDATOR_CONTAINERS) {
        String baseVolumeName = CONTAINER_VOLUME_MAP.get(validatorContainer);
        validatorInstancePrefixes.add(baseVolumeName + "-snapshot-" + snapshotNumber + "-");
      }

      for (InspectVolumeResponse volume : volumes) {
        String volumeName = volume.getName();

        // Check if this is a genesis instance volume
        if (volumeName.startsWith(genesisInstancePrefix)) {
          try {
            String numberPart = volumeName.substring(genesisInstancePrefix.length());
            // Skip if it's the old "-latest" format
            if ("latest".equals(numberPart)) {
              continue;
            }
            int instanceNumber = Integer.parseInt(numberPart);
            maxInstanceNumber = Math.max(maxInstanceNumber, instanceNumber);
          } catch (NumberFormatException e) {
            // Skip volumes that don't have valid number suffix
            log.warn("Invalid genesis instance volume name format: {}", volumeName);
          }
        }

        // Check if this is a validator instance volume
        for (String validatorPrefix : validatorInstancePrefixes) {
          if (volumeName.startsWith(validatorPrefix)) {
            try {
              String numberPart = volumeName.substring(validatorPrefix.length());
              // Skip if it's the old "-latest" format
              if ("latest".equals(numberPart)) {
                continue;
              }
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
      String instanceNumber = request.get("instanceNumber") != null ? String.valueOf(request.get("instanceNumber")) : null;
      Boolean hasChildren = (Boolean) request.get("hasChildren");

      log.info("Deleting snapshot: {} (type: {}, hasChildren: {})", snapshotId, nodeType, hasChildren);

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
          String nodeSnapshotNumber = String.valueOf(nodeToDelete.get("snapshotNumber"));
          String nodeInstanceNumber = nodeToDelete.get("instanceNumber") != null ?
              String.valueOf(nodeToDelete.get("instanceNumber")) : null;
          String nodeNodeType = (String) nodeToDelete.get("type");

          if ("instance".equals(nodeNodeType) && nodeInstanceNumber != null) {
            // Delete instance volumes for ALL container types
            // Genesis instance volume
            String genesisInstanceVolume = "ton-db-snapshot-" + nodeSnapshotNumber + "-" + nodeInstanceNumber;
            volumesToDelete.add(genesisInstanceVolume);

            // Validator instance volumes
            for (String validatorContainer : VALIDATOR_CONTAINERS) {
              String baseVolumeName = CONTAINER_VOLUME_MAP.get(validatorContainer);
              String validatorInstanceVolume = baseVolumeName + "-snapshot-" + nodeSnapshotNumber + "-" + nodeInstanceNumber;
              volumesToDelete.add(validatorInstanceVolume);
            }
          } else {
            // Delete base snapshot volumes for ALL container types
            // Genesis base snapshot volume
            String genesisBaseVolume = "ton-db-snapshot-" + nodeSnapshotNumber;
            volumesToDelete.add(genesisBaseVolume);

            // Validator base snapshot volumes
            for (String validatorContainer : VALIDATOR_CONTAINERS) {
              String baseVolumeName = CONTAINER_VOLUME_MAP.get(validatorContainer);
              String validatorBaseVolume = baseVolumeName + "-snapshot-" + nodeSnapshotNumber;
              volumesToDelete.add(validatorBaseVolume);
            }
          }
        }
      } else {
        // Fallback to old logic if nodesToDelete is not provided
        if ("instance".equals(nodeType) && instanceNumber != null) {
          // Delete instance volumes for ALL container types
          // Genesis instance volume
          String genesisInstanceVolume = "ton-db-snapshot-" + snapshotNumber + "-" + instanceNumber;
          volumesToDelete.add(genesisInstanceVolume);

          // Validator instance volumes
          for (String validatorContainer : VALIDATOR_CONTAINERS) {
            String baseVolumeName = CONTAINER_VOLUME_MAP.get(validatorContainer);
            String validatorInstanceVolume = baseVolumeName + "-snapshot-" + snapshotNumber + "-" + instanceNumber;
            volumesToDelete.add(validatorInstanceVolume);
          }
        } else {
          // Delete base snapshot volumes for ALL container types
          // Genesis base snapshot volume
          String genesisBaseVolume = "ton-db-snapshot-" + snapshotNumber;
          volumesToDelete.add(genesisBaseVolume);

          // Validator base snapshot volumes
          for (String validatorContainer : VALIDATOR_CONTAINERS) {
            String baseVolumeName = CONTAINER_VOLUME_MAP.get(validatorContainer);
            String validatorBaseVolume = baseVolumeName + "-snapshot-" + snapshotNumber;
            volumesToDelete.add(validatorBaseVolume);
          }

          // If has children, also delete all instance volumes for this snapshot (all container types)
          if (hasChildren != null && hasChildren) {
            // Find all instance volumes for this snapshot across all container types
            List<InspectVolumeResponse> allVolumes = dockerClient.listVolumesCmd().exec().getVolumes();

            // Genesis instance volumes
            String genesisInstancePrefix = "ton-db-snapshot-" + snapshotNumber + "-";

            // Validator instance volume prefixes
            List<String> validatorInstancePrefixes = new ArrayList<>();
            for (String validatorContainer : VALIDATOR_CONTAINERS) {
              String baseVolumeName = CONTAINER_VOLUME_MAP.get(validatorContainer);
              validatorInstancePrefixes.add(baseVolumeName + "-snapshot-" + snapshotNumber + "-");
            }

            for (InspectVolumeResponse volume : allVolumes) {
              String volumeName = volume.getName();

              // Check genesis instance volumes
              if (volumeName.startsWith(genesisInstancePrefix)) {
                volumesToDelete.add(volumeName);
              }

              // Check validator instance volumes
              for (String validatorPrefix : validatorInstancePrefixes) {
                if (volumeName.startsWith(validatorPrefix)) {
                  volumesToDelete.add(volumeName);
                  break; // Found matching prefix, no need to check others
                }
              }
            }
          }
        }
      }

      boolean deletingActiveVolume = false;
      if (currentVolume != null && volumesToDelete.contains(currentVolume)) {
        deletingActiveVolume = true;
        log.warn("Attempting to delete currently active volume: {}", currentVolume);

        // If trying to delete active volume, return error immediately
        Map<String, Object> response = new HashMap<>();
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

      Map<String, Object> response = new HashMap<>();

      if (failedVolumes.isEmpty()) {
        response.put("success", true);
        response.put("message", "Snapshot deleted successfully");
        response.put("deletedVolumes", deletedVolumes);
        response.put("deletingActiveVolume", deletingActiveVolume);
      } else {
        response.put("success", false);
        response.put("message", "Failed to delete some volumes: " + String.join(", ", failedVolumes));
        response.put("deletedVolumes", deletedVolumes);
        response.put("failedVolumes", failedVolumes);
        response.put("deletingActiveVolume", deletingActiveVolume);
      }

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
   * Stops and removes specific containers by name with proper shutdown ordering.
   * Extra services are stopped first, then genesis+validators.
   * This method ensures all containers from the list are removed, regardless of their current state.
   */
  private void stopAndRemoveSpecificContainers(List<String> containerNames) {
//    log.info("Stopping and removing specific containers with proper ordering: {}", containerNames);

    if (containerNames.isEmpty()) {
      log.info("No containers to stop");
      return;
    }

    // Separate containers into core blockchain (genesis + validators) and extra services
    List<String> coreContainers = new ArrayList<>();
    List<String> extraServices = new ArrayList<>();
    
    for (String containerName : containerNames) {
      if (CONTAINER_GENESIS.equals(containerName) || Arrays.asList(VALIDATOR_CONTAINERS).contains(containerName)) {
        coreContainers.add(containerName);
      } else {
        extraServices.add(containerName);
      }
    }

    log.info("Core containers to stop: {}", coreContainers);
    log.info("Extra services to stop: {}", extraServices);

    // STEP 1: Stop extra services first
    if (!extraServices.isEmpty()) {
      log.info("STEP 1: Stopping extra services first");
      stopAndRemoveContainerGroup(extraServices );
    }

    // STEP 2: Stop core blockchain containers (genesis + validators)
    if (!coreContainers.isEmpty()) {
      log.info("STEP 2: Stopping core blockchain containers");
      stopAndRemoveContainerGroup(coreContainers);
    }
  }

  /**
   * Helper method to stop and remove a group of containers in parallel.
   */
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

    // Stop all containers in this group in parallel
    log.info("Stopping {} containers in parallel", containerIds.size());

    List<CompletableFuture<Void>> stopFutures = containerIds.entrySet().stream()
        .map(entry -> CompletableFuture.runAsync(() -> {
          String containerName = entry.getKey();
          String containerId = entry.getValue();
          try {
            dockerClient.stopContainerCmd(containerId).exec();
            log.info("container stopped: {}", containerName);
          } catch (Exception e) {
            log.warn("Failed to stop container {}: {}", containerName, e.getMessage());
          }
        }))
        .toList();

    // Wait for all stop operations to complete
    CompletableFuture<Void> allStopFutures = CompletableFuture.allOf(
        stopFutures.toArray(new CompletableFuture[0])
    );

    try {
      allStopFutures.get(); // Wait for all containers to stop
    } catch (Exception e) {
      log.error("Error waiting for containers to stop: {}", e.getMessage());
    }

    // Remove all containers in this group in parallel
    log.info("Removing {} containers in parallel", containerIds.size());

    List<CompletableFuture<Void>> removeFutures = containerIds.entrySet().stream()
        .map(entry -> CompletableFuture.runAsync(() -> {
          String containerName = entry.getKey();
          String containerId = entry.getValue();
          try {
//            log.info("Removing {} container: {}", groupName, containerName);
            dockerClient.removeContainerCmd(containerId).withForce(true).exec();
            log.info("container removed: {}", containerName);
          } catch (Exception e) {
            log.warn("Failed to remove container {}", containerName);
          }
        }))
        .toList();

    // Wait for all remove operations to complete
    CompletableFuture<Void> allRemoveFutures = CompletableFuture.allOf(
        removeFutures.toArray(new CompletableFuture[0])
    );

    try {
      allRemoveFutures.get(); // Wait for all containers to be removed
    } catch (Exception e) {
      log.error("Error waiting for containers to be removed: {}", e.getMessage());
    }

    // Verify all specified containers are actually removed before proceeding
    int maxRetries = 10;
    int retryCount = 0;

    while (retryCount < maxRetries) {
      // Check if any of the specified containers still exist
      List<String> stillExisting = new ArrayList<>();

      try {
        List<Container> allContainers = dockerClient.listContainersCmd().withShowAll(true).exec();

        for (String containerName : containerNames) {
          for (Container container : allContainers) {
            if (container.getNames() != null) {
              for (String name : container.getNames()) {
                if (name.equals("/" + containerName)) {
                  stillExisting.add(containerName);
                  break;
                }
              }
            }
            if (stillExisting.contains(containerName)) {
              break;
            }
          }
        }
      } catch (Exception e) {
        log.error("Error checking remaining containers: {}", e.getMessage());
        break;
      }

      if (stillExisting.isEmpty()) {
//        log.info("All {} containers successfully removed", groupName);
        break;
      }

      log.warn("Still found {} containers after removal attempt: {}", stillExisting.size(), stillExisting);

      // Force remove any remaining containers in parallel
      List<CompletableFuture<Void>> forceRemoveFutures = stillExisting.stream()
          .map(containerName -> CompletableFuture.runAsync(() -> {
            try {
              String containerId = getContainerIdByName(containerName);
              if (containerId != null) {
                log.info("Force removing remaining container: {} ({})", containerName, containerId);
                dockerClient.removeContainerCmd(containerId).withForce(true).exec();
              }
            } catch (Exception e) {
              log.warn("Failed to force remove container {}: {}", containerName, e.getMessage());
            }
          }))
          .toList();

      // Wait for all force remove operations to complete
      try {
        CompletableFuture.allOf(forceRemoveFutures.toArray(new CompletableFuture[0])).get();
      } catch (Exception e) {
        log.error("Error during force removal of containers: {}", e.getMessage());
      }

      retryCount++;
      try {
        Thread.sleep(1000); // Wait 1 second before checking again
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        break;
      }
    }

    if (retryCount >= maxRetries) {
      log.warn("Some containers may still exist after {} attempts, but continuing anyway", maxRetries);
    }
  }

  private void createAllContainersGroups(SnapshotConfig snapshotConfig, String seqnoStr) {

    log.info("STEP 1: Starting core service containers");

      createContainerGroup(snapshotConfig.getCoreContainers());

      log.info("STEP 2: Starting extra service containers");
      createContainerGroup(snapshotConfig.getExtraContainers());

  }

  /**
   * Helper method to recreate a group of containers in parallel.
   */
  private void createContainerGroup(List<DockerContainer> containers) {

    log.info("Recreating {} containers in parallel", containers.size());

    // Create containers in this group in parallel
    List<CompletableFuture<Void>> recreateFutures = containers.stream()
        .map(entry -> CompletableFuture.runAsync(() -> {
          String containerName = entry.getName();
          String targetVolume = entry.getTonDbVolumeName();
          DockerContainer dockerContainer =  entry;
          try {
            log.info("Creating: {} with volume {}", containerName, targetVolume);
            createContainerWithConfig(dockerContainer);
          } catch (Exception e) {
            log.error("Failed to recreate container {}: {}", containerName, e.getMessage());
          }
        })).toList();

    // Wait for all container recreation operations in this group to complete
    CompletableFuture<Void> allRecreateFutures = CompletableFuture.allOf(
        recreateFutures.toArray(new CompletableFuture[0])
    );

    try {
      allRecreateFutures.get(); // Wait for all containers in this group to be recreated
//      log.info("All containers recreated");
    } catch (Exception e) {
      log.error("Error waiting for containers to be recreated: {}", e.getMessage());
    }
  }

  /**
   * Unified method to recreate any container (genesis or validator) with a new volume and saved configuration.
   * Combines the logic from recreateGenesisContainerWithConfig() and recreateValidatorContainerWithConfig().
   */
  private void createContainerWithConfig(DockerContainer dockerContainer) {

    ContainerConfig config = dockerContainer.getContainerConfig();
    HostConfig hostConfig = dockerContainer.getHostConfig();
    String ipAddress = dockerContainer.getIp();

    String[] envs = config.getEnv();

    ExposedPort[] exposedPorts = config.getExposedPorts();
    HealthCheck healthCheck = config.getHealthcheck();
    String networkMode = hostConfig.getNetworkMode();

    // Create new container with the saved configuration but new volume
    CreateContainerCmd createCmd = dockerClient
        .createContainerCmd(config.getImage())
        .withName(dockerContainer.getName())
//        .withVolumes(new Volume(CONTAINER_DB_PATH), new Volume("/usr/share/data"))
        .withEnv(envs)
//        .withCmd(config.getCmd())
        .withHealthcheck(healthCheck)
        .withHostConfig(hostConfig);


    // Add exposed ports if they exist
    if (exposedPorts != null) {
      createCmd.withExposedPorts(exposedPorts);
    }

    if (config.getCmd() != null) {
      createCmd.withCmd(config.getCmd());
    }

    // Add IP address if available
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
        // Try to call the seqno-volume endpoint
        long delta = getSyncDelay();
        log.info("Sync delay: {} seconds (attempt {})", delta, retryCount + 1);

        if (delta < 10) {
          log.info("waitForSeqnoVolumeHealthy is healthy after {} attempts (sync delay: {} seconds)", retryCount + 1, delta);
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

    log.warn("Seqno-volume endpoint did not become healthy after {} attempts (max {} minutes), but continuing anyway", maxRetries, maxRetries * 5 / maxRetries);
    return false;
  }

  public long getSyncDelay() throws Exception {
    MasterchainInfo masterChainInfo = getMasterchainInfo();
    Block block = Main.adnlLiteClient.getBlock(masterChainInfo.getLast()).getBlock();
    long delta = Utils.now() - block.getBlockInfo().getGenuTime();
    return delta;
  }

  /**
   * Restarts an extra service container with provided configuration.
   * This method is used when we have saved configuration from before shutdown.
   */
  private void restartExtraServiceContainerWithConfig(String containerName, ContainerConfig config, HostConfig hostConfig, String ipAddress) {
    try {
      log.info("Restarting {} container with saved configuration", containerName);

      // Check if the container exists first
      String containerId = getContainerIdByName(containerName);
      if (!StringUtils.isEmpty(containerId)) {
        // Container exists, stop and remove it first
        log.info("Stopping existing container {}", containerName);
        dockerClient.stopContainerCmd(containerId).exec();
        dockerClient.removeContainerCmd(containerId).withForce(true).exec();
      }

      if (config == null || hostConfig == null) {
        log.warn("No saved configuration found for container {}, using fallback restart method", containerName);
        //restartExtraServiceContainer(containerName);
        return;
      }

      currentSnapshotStatus = "Restarting " + containerName + " container with saved config";

      // Extract configuration details
      String[] envs = config.getEnv();
      ExposedPort[] exposedPorts = config.getExposedPorts();
      HealthCheck healthCheck = config.getHealthcheck();
      String networkMode = hostConfig.getNetworkMode();
      String imageName = config.getImage();

      // Get port bindings
      Ports portBindings = new Ports();
      if (exposedPorts != null) {
        for (ExposedPort exposedPort : exposedPorts) {
          portBindings.bind(exposedPort, Ports.Binding.bindPort(exposedPort.getPort()));
        }
      }

      // Create volume mounts - we need to recreate the mounts from the original container
      List<Mount> mounts = new ArrayList<>();
      
      // Add common shared data mount that most services use
      mounts.add(new Mount()
          .withType(MountType.VOLUME)
          .withSource("mylocalton-docker_shared-data")
          .withTarget("/usr/share/data"));

      // Get volumes for backward compatibility
      List<Volume> volumes = new ArrayList<>();
      if (config.getVolumes() != null) {
        for (var volumeEntry : config.getVolumes().entrySet()) {
          volumes.add(new Volume(volumeEntry.getKey()));
        }
      }

      log.info("Recreating container {} with saved configuration", containerName);

      // Create new container with the saved configuration
      CreateContainerCmd createCmd = dockerClient
          .createContainerCmd(imageName)
          .withName(containerName)
          .withEnv(envs)
          .withHealthcheck(healthCheck)
          .withHostConfig(
              newHostConfig()
                  .withNetworkMode(networkMode)
                  .withPortBindings(portBindings)
                  .withMounts(mounts)
          );

      // Add exposed ports if they exist
      if (exposedPorts != null) {
        createCmd.withExposedPorts(exposedPorts);
      }

      // Add volumes if they exist
      if (!volumes.isEmpty()) {
        createCmd.withVolumes(volumes.toArray(new Volume[0]));
      }

      // Add IP address if available
      if (ipAddress != null) {
        createCmd.withIpv4Address(ipAddress);
      }

      CreateContainerResponse newContainer = createCmd.exec();

      log.info("Starting recreated container {}", containerName);
      dockerClient.startContainerCmd(newContainer.getId()).exec();

      log.info("Successfully restarted container {} with saved configuration", containerName);

    } catch (Exception e) {
      log.error("Failed to restart container {} with saved config: {}", containerName, e.getMessage(), e);
    }
  }

  private void storeSnapshotConfiguration(SnapshotConfig snapshotConfig)  throws Exception {
    log.info("storeSnapshotConfiguration, snapshot {}", snapshotConfig.getSnapshotNumber());
    String configPath = "/usr/share/data/config-snapshot-" + snapshotConfig.getSnapshotNumber() + ".json";

    // Ensure directory exists
    File dataDir = new File("/usr/share/data");
    if (!dataDir.exists()) {
      dataDir.mkdirs();
    }
    // Write to file
    Gson gson = new GsonBuilder()
            .setPrettyPrinting()
            .registerTypeAdapter(Ports.class, new PortsSerializer())
            .create();
    String jsonContent = gson.toJson(snapshotConfig);
//    log.info("gson {}", jsonContent);
    Files.write(Paths.get(configPath), jsonContent.getBytes());
  }

  private boolean isConfigExist(int snapshotNumber) {
    return Files.exists(Path.of("/usr/share/data/config-snapshot-" + snapshotNumber + ".json"));
  }

  private SnapshotConfig loadSnapshotConfiguration(String snapshotNumber) throws Exception {
    String configPath = "/usr/share/data/config-snapshot-" + snapshotNumber + ".json";
    log.info("loading {}", configPath);
    File configFile = new File(configPath);

    if (!configFile.exists()) {
      log.error("Snapshot configuration file not found for snapshot {}: {}", snapshotNumber, configPath);
      return null;
    }

    String content = new String(Files.readAllBytes(Paths.get(configPath)));
//    log.info(content);
    Gson gson = new GsonBuilder().
            registerTypeAdapter(Ports.class, new PortsDeserializer())
            .create();

    return gson.fromJson(content, SnapshotConfig.class);
  }


  @PostMapping("/stop-blockchain")
  public Map<String, Object> stopBlockchain() {
    try {
      log.info("Stopping blockchain - stopping and removing all containers except time-machine");
      
      // Get list of containers from docker-compose-build.yaml (excluding time-machine)
      List<String> containersToStop = getAllContainers();
      
      if (containersToStop.isEmpty()) {
        log.info("No containers found to stop");
        Map<String, Object> response = new HashMap<>();
        response.put("success", true);
        response.put("message", "No containers found to stop");
        response.put("stoppedContainers", 0);
        return response;
      }
      
      log.info("Found containers to stop: {}", containersToStop);
      
      // Filter to only running containers
      List<String> runningContainers = new ArrayList<>();
      for (String containerName : containersToStop) {
        try {
          String containerId = getContainerIdByName(containerName);
          if (containerId != null) {
            // Check if container is actually running
            InspectContainerResponse inspectResponse = dockerClient.inspectContainerCmd(containerId).exec();
            if (inspectResponse.getState().getRunning()) {
              runningContainers.add(containerName);
            }
          }
        } catch (Exception e) {
          log.debug("Container {} not found or not running", containerName);
        }
      }
      
      if (runningContainers.isEmpty()) {
        log.info("No running containers found to stop");
        Map<String, Object> response = new HashMap<>();
        response.put("success", true);
        response.put("message", "No running containers found to stop");
        response.put("stoppedContainers", 0);
        return response;
      }
      
      log.info("Stopping {} running containers: {}", runningContainers.size(), runningContainers);
      
      // Stop and remove the running containers
      stopAndRemoveSpecificContainers(runningContainers);
      
      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("message", "Blockchain stopped successfully");
      response.put("stoppedContainers", runningContainers.size());
      response.put("containerNames", runningContainers);
      
      log.info("Successfully stopped {} containers", runningContainers.size());
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
//          "file-server",
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
          "index-postgres"
      );
  }

  /**
   * Adds or updates CUSTOM_PARAMETERS environment variable with -T seqno flag
   * @param envs existing environment variables array
   * @param seqnoStr seqno value from frontend
   * @return updated environment variables array with CUSTOM_PARAMETERS containing -T seqno
   */
  private String[] addCustomParametersWithSeqno(String[] envs, String seqnoStr) {
    try {
      // Use seqno from frontend parameter, fallback to current if not provided
      String seqnoFlag = "";
      if (seqnoStr != null && !seqnoStr.trim().isEmpty() && (Long.parseLong(seqnoStr)!=0)) {
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
        InspectContainerResponse inspectResponse = dockerClient.inspectContainerCmd(containerId).exec();
        containerConfig  = inspectResponse.getConfig();
        hostConfig = inspectResponse.getHostConfig();

        String volumeName = getCurrentVolume(dockerClient, containerId);

        // Get IP address if available
        try {
          if (inspectResponse.getNetworkSettings() != null &&
                  inspectResponse.getNetworkSettings().getNetworks() != null &&
                  !inspectResponse.getNetworkSettings().getNetworks().isEmpty()) {
            String ipAddress = inspectResponse.getNetworkSettings().getNetworks().values().iterator().next().getIpAddress();
            if (ipAddress != null) {
              ip = ipAddress;
            }
           }
          } catch (Exception e) {
            log.warn("Could not retrieve IP address for container {}: {}", containerName, e.getMessage());
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

  private void replaceVolumeInConfig(SnapshotConfig snapshotConfig, String containerName, String oldVolume, String newVolume) {
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