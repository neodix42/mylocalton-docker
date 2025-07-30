package org.ton.mylocaltondocker.timemachine.controller;

import static com.github.dockerjava.api.model.HostConfig.newHostConfig;
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
import java.nio.file.Paths;
import java.util.*;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.stream.Collectors;

import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.io.FileUtils;
import org.codehaus.plexus.util.StringUtils;
import org.springframework.web.bind.annotation.*;
import org.ton.java.adnl.AdnlLiteClient;
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
  public static final Map<String, String> CONTAINER_VOLUME_MAP = Map.of(
      "genesis", "ton-db",
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
        log.error("masterChainInfo is null, reinit");
        reinitializeAdnlLiteClient();
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
      log.error("Error getting seqno-volume, reinit");
      reinitializeAdnlLiteClient();
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to get seqno-volume: " + e.getMessage());
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

  @PostMapping("/take-snapshot")
  public Map<String, Object> takeSnapshot(@RequestBody Map<String, String> request) {
    try {
      isSnapshotInProgress = true;
      currentSnapshotStatus = "Preparing snapshot...";
      
      log.info("taking snapshot for all containers");
      // Get sequential snapshot number from request or generate next one
      int snapshotNumber;
      if (request.containsKey("snapshotNumber")) {
        snapshotNumber = Integer.parseInt(request.get("snapshotNumber"));
      } else {
        // Fallback: generate next sequential number by counting existing volumes
        snapshotNumber = getNextSnapshotNumber(dockerClient);
      }

      String snapshotId = "snapshot-" + snapshotNumber;

      // Discover all running containers
      List<String> runningContainers = getAllRunningContainers();
      if (runningContainers.isEmpty()) {
        log.error("No containers found");
        isSnapshotInProgress = false;
        currentSnapshotStatus = "Ready";
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "No containers found");
        return response;
      }

      log.info("Found running containers: {}", runningContainers);

      // Check if we're taking snapshot from active (running) node
      String parentId = request.get("parentId");
      boolean isFromActiveNode = parentId != null && parentId.equals(getActiveNodeIdFromVolume());
      
      // Only shutdown blockchain if taking snapshot from active node AND multiple validators are running
      long validatorCount = runningContainers.stream()
          .filter(containerName -> !CONTAINER_GENESIS.equals(containerName))
          .count();
      
      boolean shouldShutdownBlockchain = isFromActiveNode && validatorCount > 0;
      log.info("Taking snapshot from active node: {}, Validator containers running: {}, should shutdown blockchain: {}", 
          isFromActiveNode, validatorCount, shouldShutdownBlockchain);

      // Store container configurations before shutdown if needed
      Map<String, ContainerConfig> containerConfigs = new HashMap<>();
      Map<String, HostConfig> hostConfigs = new HashMap<>();
      Map<String, String> containerIpAddresses = new HashMap<>();
      Map<String, String> containerVolumes = new HashMap<>();

      /// --------------------------------------------------------------------------------
      // Get current block sequence BEFORE shutting down blockchain
      long lastSeqno = 0;
      try {
        lastSeqno = getCurrentBlockSequence();
      } catch (Exception e) {
        log.warn("Could not get current block sequence, using 0: {}", e.getMessage());
      }
      
      if (shouldShutdownBlockchain) {
        currentSnapshotStatus = "Stopping blockchain...";
        log.info("Multiple validators detected, capturing container configurations before shutdown");
        
        // Get container configurations BEFORE stopping them
        for (String containerName : runningContainers) {
          try {
            String containerId = getContainerIdByName(containerName);
            if (containerId != null) {
              InspectContainerResponse inspectResponse = dockerClient.inspectContainerCmd(containerId).exec();
              containerConfigs.put(containerName, inspectResponse.getConfig());
              hostConfigs.put(containerName, inspectResponse.getHostConfig());
              
              // Get current volume
              String volumeName = getCurrentVolume(dockerClient, containerId);
              if (volumeName != null) {
                containerVolumes.put(containerName, volumeName);
              }
              
              // Get IP address if available
              try {
                if (inspectResponse.getNetworkSettings() != null && 
                    inspectResponse.getNetworkSettings().getNetworks() != null && 
                    !inspectResponse.getNetworkSettings().getNetworks().isEmpty()) {
                  String ipAddress = inspectResponse.getNetworkSettings().getNetworks().values().iterator().next().getIpAddress();
                  if (ipAddress != null) {
                    containerIpAddresses.put(containerName, ipAddress);
                  }
                }
              } catch (Exception e) {
                log.warn("Could not retrieve IP address for container {}: {}", containerName, e.getMessage());
              }
            }
          } catch (Exception e) {
            log.warn("Could not get configuration for container {}: {}", containerName, e.getMessage());
          }
        }
        
        // Stop and remove ALL running containers
        log.info("Shutting down blockchain (all containers) before taking snapshots");
        stopAndRemoveAllContainers();
      } else {
        // Only genesis is running, get volumes without shutdown
        containerVolumes = getContainerVolumeMap(runningContainers);
      }

      if (containerVolumes.isEmpty()) {
        log.error("No volumes found for containers");
        isSnapshotInProgress = false;
        currentSnapshotStatus = "Ready";
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "No volumes found for containers");
        return response;
      }


      
      // Create snapshots for all containers in parallel
      currentSnapshotStatus = "Taking snapshots...";
      log.info("Creating snapshots for {} containers in parallel", containerVolumes.size());
      
      // Use thread-safe collections for parallel processing
      List<String> createdSnapshots = Collections.synchronizedList(new ArrayList<>());
      List<String> failedSnapshots = Collections.synchronizedList(new ArrayList<>());
      
      // Process all containers in parallel
      containerVolumes.entrySet().parallelStream().forEach(entry -> {
        String containerName = entry.getKey();
        String currentVolume = entry.getValue();
        
        // Generate backup volume name based on container type
        String backupVolumeName;
        if (CONTAINER_GENESIS.equals(containerName)) {
          backupVolumeName = "ton-db-snapshot-" + snapshotNumber;
        } else {
          // For validators: ton-db-val1 -> ton-db-val1-snapshot-{number}
          String baseVolumeName = CONTAINER_VOLUME_MAP.get(containerName);
          backupVolumeName = baseVolumeName + "-snapshot-" + snapshotNumber;
        }
        
        try {
          log.info("Creating snapshot for container {}: {} -> {}", containerName, currentVolume, backupVolumeName);
          copyVolumes(dockerClient, currentVolume, backupVolumeName);
          createdSnapshots.add(backupVolumeName);
          log.info("Successfully created snapshot for container {}: {}", containerName, backupVolumeName);
        } catch (Exception e) {
          log.error("Failed to create snapshot for container {}: {}", containerName, e.getMessage());
          failedSnapshots.add(containerName + ": " + e.getMessage());
        }
      });
      
      log.info("Parallel snapshot creation completed. Created: {}, Failed: {}", createdSnapshots.size(), failedSnapshots.size());

      // If blockchain was shutdown, restart it with the same volumes and configurations
      if (shouldShutdownBlockchain && failedSnapshots.isEmpty()) {
        try {
          currentSnapshotStatus = "Starting blockchain...";
          log.info("Restarting blockchain with original volumes and configurations");
          recreateAllContainersWithConfigs(containerVolumes, containerConfigs, hostConfigs, containerIpAddresses, String.valueOf(lastSeqno));
          log.info("Blockchain restarted successfully after snapshot creation");
        } catch (Exception e) {
          log.error("Failed to restart blockchain after snapshot creation: {}", e.getMessage());
          // Add this to failed snapshots so the response indicates the issue
          failedSnapshots.add("Failed to restart blockchain: " + e.getMessage());
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
      
      if (failedSnapshots.isEmpty()) {
        currentSnapshotStatus = "Snapshot taken successfully";
        response.put("success", true);
        response.put("snapshotId", snapshotId);
        response.put("snapshotNumber", snapshotNumber);
        response.put("blockSequence", lastSeqno);
        response.put("volumeName", "ton-db-snapshot-" + snapshotNumber); // Keep for compatibility
        response.put("createdSnapshots", createdSnapshots);
        response.put("blockchainShutdown", shouldShutdownBlockchain);
        response.put("activeNodes", activeNodesCount); // Include active nodes count
        response.put("message", "Snapshots created successfully for all containers (" + createdSnapshots.size() + " volumes)" + 
            (shouldShutdownBlockchain ? " with blockchain shutdown/restart" : ""));
      } else {
        // If some snapshots failed, clean up successful ones
        for (String createdSnapshot : createdSnapshots) {
          try {
            dockerClient.removeVolumeCmd(createdSnapshot).exec();
            log.info("Cleaned up partial snapshot: {}", createdSnapshot);
          } catch (Exception cleanupError) {
            log.warn("Failed to clean up partial snapshot {}: {}", createdSnapshot, cleanupError.getMessage());
          }
        }
        
        currentSnapshotStatus = "Snapshot failed";
        response.put("success", false);
        response.put("message", "Failed to create snapshots for some containers: " + String.join(", ", failedSnapshots));
        response.put("failedSnapshots", failedSnapshots);
        response.put("blockchainShutdown", shouldShutdownBlockchain);
      }
      
      isSnapshotInProgress = false;

      // Wait for lite-server to be ready before setting status to Ready
      currentSnapshotStatus = "Waiting for lite-server to be ready";
      waitForSeqnoVolumeHealthy();
      currentSnapshotStatus = "Ready";
      
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
        return "root"; // Default to root if no genesis container
      }
      
      String currentVolume = getCurrentVolume(dockerClient, genesisContainerId);
      if (currentVolume == null) {
        return "root";
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
      
      return "root"; // Default to root for base volume
    } catch (Exception e) {
      log.warn("Error determining active node ID from volume: {}", e.getMessage());
      return "root";
    }
  }

  private void copyVolumes(
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

      log.info("Volumes copied from {} to {} using container {}", sourceVolumeName, targetVolumeName, uniqueContainerName);
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

      currentSnapshotStatus = "Saving current blockchain...";

      log.info("Restoring snapshot for all containers: {} (type: {}, seqno: {})", snapshotId, nodeType, seqnoStr);

      // Determine target volume names for ALL containers using the same logic
      Map<String, String> containerTargetVolumes = new HashMap<>();
      int instanceNumber = 0;
      boolean isNewInstance = false;

      if ("instance".equals(nodeType)) {
        // Restoring from instance node - reuse existing volumes for containers that have them
        if (instanceNumberStr != null) {
          instanceNumber = Integer.parseInt(instanceNumberStr);
        }

        // Genesis container - always should exist for instances
        String genesisTargetVolume = "ton-db-snapshot-" + snapshotNumber + 
            (instanceNumberStr != null ? "-" + instanceNumber : "-latest");
        
        // Check if genesis volume exists before adding
        try {
          dockerClient.inspectVolumeCmd(genesisTargetVolume).exec();
          containerTargetVolumes.put(CONTAINER_GENESIS, genesisTargetVolume);
          log.info("Found existing genesis instance volume: {}", genesisTargetVolume);
        } catch (NotFoundException e) {
          log.warn("Genesis instance volume {} not found", genesisTargetVolume);
        }

        // Validator containers - only add if their volumes exist
        for (String validatorContainer : VALIDATOR_CONTAINERS) {
          String baseVolumeName = CONTAINER_VOLUME_MAP.get(validatorContainer) + "-snapshot-" + snapshotNumber;
          String targetVolume = baseVolumeName + (instanceNumberStr != null ? "-" + instanceNumber : "-latest");
          
          // Only add if the instance volume exists
          try {
            dockerClient.inspectVolumeCmd(targetVolume).exec();
            containerTargetVolumes.put(validatorContainer, targetVolume);
            log.info("Found existing validator instance volume: {}", targetVolume);
          } catch (NotFoundException e) {
            log.debug("Validator instance volume {} not found, skipping", targetVolume);
          }
        }

        log.info("Reusing existing instance volumes for {} containers", containerTargetVolumes.size());

      } else {
        // Restoring from snapshot node - create new instances for containers that have snapshots
        instanceNumber = getNextInstanceNumber(Integer.parseInt(snapshotNumber));
        isNewInstance = true;

        // Genesis container - should always exist
        String genesisBackupVolume = "ton-db-snapshot-" + snapshotNumber;
        String genesisTargetVolume = genesisBackupVolume + "-" + instanceNumber;
        
        // Check if genesis backup exists before copying
        try {
          dockerClient.inspectVolumeCmd(genesisBackupVolume).exec();
          log.info("Copying volume {} to {}", genesisBackupVolume, genesisTargetVolume);
          copyVolumes(dockerClient, genesisBackupVolume, genesisTargetVolume);
          containerTargetVolumes.put(CONTAINER_GENESIS, genesisTargetVolume);
        } catch (NotFoundException e) {
          log.error("Genesis backup volume {} not found", genesisBackupVolume);
          throw new RuntimeException("Genesis backup volume not found: " + genesisBackupVolume);
        }

        // Validator containers - only copy and add if backup volumes exist
        for (String validatorContainer : VALIDATOR_CONTAINERS) {
          String validatorBackupVolume = CONTAINER_VOLUME_MAP.get(validatorContainer) + "-snapshot-" + snapshotNumber;
          String validatorTargetVolume = validatorBackupVolume + "-" + instanceNumber;

          // Only copy if the backup volume exists (validator was running when snapshot was taken)
          try {
            dockerClient.inspectVolumeCmd(validatorBackupVolume).exec();
            log.info("Copying volume {} to {}", validatorBackupVolume, validatorTargetVolume);
            copyVolumes(dockerClient, validatorBackupVolume, validatorTargetVolume);
            containerTargetVolumes.put(validatorContainer, validatorTargetVolume);
          } catch (NotFoundException e) {
            log.info("Validator backup volume {} not found, skipping", validatorBackupVolume);
          }
        }
        
        log.info("Created new instance volumes for {} containers", containerTargetVolumes.size());
      }

      // Get container configurations BEFORE stopping them
      Map<String, ContainerConfig> containerConfigs = new HashMap<>();
      Map<String, HostConfig> hostConfigs = new HashMap<>();
      Map<String, String> containerIpAddresses = new HashMap<>();
      
      List<String> runningContainers = getAllRunningContainers();
      for (String containerName : runningContainers) {
        try {
          String containerId = getContainerIdByName(containerName);
          if (containerId != null) {
            InspectContainerResponse inspectResponse = dockerClient.inspectContainerCmd(containerId).exec();
            containerConfigs.put(containerName, inspectResponse.getConfig());
            hostConfigs.put(containerName, inspectResponse.getHostConfig());
            
            // Get IP address if available
            try {
              if (inspectResponse.getNetworkSettings() != null && 
                  inspectResponse.getNetworkSettings().getNetworks() != null && 
                  !inspectResponse.getNetworkSettings().getNetworks().isEmpty()) {
                String ipAddress = inspectResponse.getNetworkSettings().getNetworks().values().iterator().next().getIpAddress();
                if (ipAddress != null) {
                  containerIpAddresses.put(containerName, ipAddress);
                }
              }
            } catch (Exception e) {
              log.warn("Could not retrieve IP address for container {}: {}", containerName, e.getMessage());
            }
          }
        } catch (Exception e) {
          log.warn("Could not get configuration for container {}: {}", containerName, e.getMessage());
        }
      }

      // Stop and remove ALL running containers
      currentSnapshotStatus = "Stopping current blockchain...";

      stopAndRemoveAllContainers();

      // Recreate and start containers with target volumes using saved configurations
      currentSnapshotStatus = "Starting blockchain from the snapshot...";
      recreateAllContainersWithConfigs(containerTargetVolumes, containerConfigs, hostConfigs, containerIpAddresses, seqnoStr);

      log.info("Snapshots restored for all containers using instance number: {}", instanceNumber);

      // Wait for lite-server to be ready before setting status to Ready
      currentSnapshotStatus = "Waiting for lite-server to be ready";
      waitForSeqnoVolumeHealthy();
      currentSnapshotStatus = "Ready";

      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("message", "Snapshots restored successfully for all containers");
      response.put("volumeName", containerTargetVolumes.get(CONTAINER_GENESIS)); // Keep for compatibility
      response.put("originalVolumeName", "ton-db-snapshot-" + snapshotNumber);
      response.put("instanceNumber", instanceNumber);
      response.put("isNewInstance", isNewInstance);
      response.put("restoredContainers", containerTargetVolumes.keySet());
      return response;

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
      // List all volumes with instance prefix for this snapshot to determine next sequential number
      // Check across ALL container types (genesis + validators)
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
    log.info("Stopping and removing all containers in parallel");
    
    // Get all running containers that we manage
    List<String> runningContainers = getAllRunningContainers();
    
    if (runningContainers.isEmpty()) {
      log.info("No containers to stop");
      return;
    }
    
    // Capture container IDs before stopping them
    Map<String, String> containerIds = new HashMap<>();
    for (String containerName : runningContainers) {
      String containerId = getContainerIdByName(containerName);
      if (containerId != null) {
        containerIds.put(containerName, containerId);
      }
    }
    
    log.info("Captured container IDs: {}", containerIds);
    
    // Stop all containers in parallel using CompletableFuture for true parallelism
    log.info("Stopping {} containers in parallel", containerIds.size());
    
    List<CompletableFuture<Void>> stopFutures = containerIds.entrySet().stream()
        .map(entry -> CompletableFuture.runAsync(() -> {
          String containerName = entry.getKey();
          String containerId = entry.getValue();
          try {
            log.info("Stopping container: {} ({})", containerName, containerId);
            dockerClient.stopContainerCmd(containerId).exec();
            log.info("Container stopped: {} ({})", containerName, containerId);
          } catch (Exception e) {
            log.warn("Failed to stop container {} ({}): {}", containerName, containerId, e.getMessage());
          }
        }))
        .toList();
    
    // Wait for all stop operations to complete
    CompletableFuture<Void> allStopFutures = CompletableFuture.allOf(
        stopFutures.toArray(new CompletableFuture[0])
    );
    
    try {
      allStopFutures.get(); // Wait for all containers to stop
      log.info("All containers stopped in parallel");
    } catch (Exception e) {
      log.error("Error waiting for containers to stop: {}", e.getMessage());
    }
    
    // Remove all containers in parallel using CompletableFuture
    log.info("Removing {} containers in parallel", containerIds.size());
    
    List<CompletableFuture<Void>> removeFutures = containerIds.entrySet().stream()
        .map(entry -> CompletableFuture.runAsync(() -> {
          String containerName = entry.getKey();
          String containerId = entry.getValue();
          try {
            log.info("Removing container: {} ({})", containerName, containerId);
            dockerClient.removeContainerCmd(containerId).withForce(true).exec();
            log.info("Container removed: {} ({})", containerName, containerId);
          } catch (Exception e) {
            log.warn("Failed to remove container {} ({}): {}", containerName, containerId, e.getMessage());
          }
        }))
        .toList();
    
    // Wait for all remove operations to complete
    CompletableFuture<Void> allRemoveFutures = CompletableFuture.allOf(
        removeFutures.toArray(new CompletableFuture[0])
    );
    
    try {
      allRemoveFutures.get(); // Wait for all containers to be removed
      log.info("All containers removed in parallel");
    } catch (Exception e) {
      log.error("Error waiting for containers to be removed: {}", e.getMessage());
    }
    
    // Verify all containers are actually removed before proceeding
    log.info("Verifying all containers are completely removed...");
    int maxRetries = 10;
    int retryCount = 0;
    
    while (retryCount < maxRetries) {
      List<String> stillRunning = getAllRunningContainers();
      if (stillRunning.isEmpty()) {
        log.info("All containers successfully removed");
        break;
      }
      
      log.warn("Still found {} running containers after removal attempt: {}", stillRunning.size(), stillRunning);
      
      // Force remove any remaining containers in parallel
      List<CompletableFuture<Void>> forceRemoveFutures = stillRunning.stream()
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
        log.error("Error during force removal: {}", e.getMessage());
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
      List<String> stillRunning = getAllRunningContainers();
      if (!stillRunning.isEmpty()) {
        throw new RuntimeException("Failed to remove all containers after " + maxRetries + " attempts. Still running: " + stillRunning);
      }
    }
    
    log.info("All containers stopped and removed successfully");
  }

  private void recreateAllContainers(Map<String, String> containerTargetVolumes) throws Exception {
    log.info("Recreating containers with target volumes: {}", containerTargetVolumes);
    
    // Start with genesis container
    if (containerTargetVolumes.containsKey(CONTAINER_GENESIS)) {
      recreateGenesisContainer(containerTargetVolumes.get(CONTAINER_GENESIS));
    }
    
    // Then recreate validator containers
    for (String validatorContainer : VALIDATOR_CONTAINERS) {
      if (containerTargetVolumes.containsKey(validatorContainer)) {
        recreateValidatorContainer(validatorContainer, containerTargetVolumes.get(validatorContainer));
      }
    }
  }

  private void recreateAllContainersWithConfigs(
      Map<String, String> containerTargetVolumes,
      Map<String, ContainerConfig> containerConfigs,
      Map<String, HostConfig> hostConfigs,
      Map<String, String> containerIpAddresses,
      String seqnoStr) {
    
    log.info("Recreating {} containers in parallel with target volumes and saved configs: {}", containerTargetVolumes.size(), containerTargetVolumes);
    
    // Use thread-safe collections for parallel processing
    List<String> createdContainers = Collections.synchronizedList(new ArrayList<>());
    List<String> failedContainers = Collections.synchronizedList(new ArrayList<>());
    
    // Recreate all containers in parallel using CompletableFuture for true parallelism
    List<CompletableFuture<Void>> recreateFutures = containerTargetVolumes.entrySet().stream()
        .map(entry -> CompletableFuture.runAsync(() -> {
          String containerName = entry.getKey();
          String targetVolume = entry.getValue();
          
          try {
            if (CONTAINER_GENESIS.equals(containerName)) {
              log.info("Recreating genesis container in parallel with volume and saved config: {}", targetVolume);
              recreateGenesisContainerWithConfig(
                  targetVolume,
                  containerConfigs.get(containerName),
                  hostConfigs.get(containerName),
                  containerIpAddresses.get(containerName)
              );
            } else {
              log.info("Recreating validator container {} in parallel with volume and saved config: {}", containerName, targetVolume);
              recreateValidatorContainerWithConfig(
                  containerName,
                  targetVolume,
                  containerConfigs.get(containerName),
                  hostConfigs.get(containerName),
                  containerIpAddresses.get(containerName)
              );
            }
            createdContainers.add(containerName);
            log.info("Successfully recreated container: {}", containerName);
          } catch (Exception e) {
            log.error("Failed to recreate container {}: {}", containerName, e.getMessage());
            failedContainers.add(containerName + ": " + e.getMessage());
          }
        }))
        .collect(Collectors.toList());
    
    // Wait for all container recreation operations to complete
    CompletableFuture<Void> allRecreateFutures = CompletableFuture.allOf(
        recreateFutures.toArray(new CompletableFuture[0])
    );
    
    try {
      allRecreateFutures.get(); // Wait for all containers to be recreated
      log.info("All containers recreated in parallel");
    } catch (Exception e) {
      log.error("Error waiting for containers to be recreated: {}", e.getMessage());
    }
    
    log.info("Parallel container recreation completed. Created: {}, Failed: {}", createdContainers.size(), failedContainers.size());
    
    if (!failedContainers.isEmpty()) {
      throw new RuntimeException("Failed to recreate some containers: " + String.join(", ", failedContainers));
    }
  }

  private void recreateGenesisContainer(String targetVolume) throws Exception {
    log.info("Recreating genesis container with volume: {}", targetVolume);
    
    // First, get the existing container configuration before stopping it
    String genesisContainerId = getGenesisContainerId();
    if (StringUtils.isEmpty(genesisContainerId)) {
      throw new RuntimeException("Genesis container not found for configuration retrieval");
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

    // Stop and remove the existing container
    dockerClient.stopContainerCmd(genesisContainerId).exec();
    dockerClient.removeContainerCmd(genesisContainerId).withForce(true).exec();

    // Create new container with the same configuration but new volume
    CreateContainerResponse newContainer = dockerClient
        .createContainerCmd(GENESIS_IMAGE_NAME)
        .withName(CONTAINER_GENESIS)
        .withVolumes(new Volume(CONTAINER_DB_PATH), new Volume("/usr/share/data"))
        .withEnv(envs)
        .withExposedPorts(exposedPorts)
        .withIpv4Address(inspectX.getNetworkSettings().getNetworks().values().iterator().next().getIpAddress())
        .withHealthcheck(healthCheck)
        .withHostConfig(
            newHostConfig()
                .withNetworkMode(networkMode)
                .withPortBindings(portBindings)
                .withBinds(
                    new Bind(targetVolume, new Volume(CONTAINER_DB_PATH)),
                    new Bind("mylocalton-docker_shared-data", new Volume("/usr/share/data"))
                )
        )
        .exec();

    dockerClient.startContainerCmd(newContainer.getId()).exec();
    log.info("Genesis container recreated and started");
  }

  private void recreateValidatorContainer(String containerName, String targetVolume) throws Exception {
    log.info("Recreating validator container {} with volume: {}", containerName, targetVolume);
    
    // First, get the existing container configuration before stopping it
    String validatorContainerId = getContainerIdByName(containerName);
    if (StringUtils.isEmpty(validatorContainerId)) {
      throw new RuntimeException("Validator container " + containerName + " not found for configuration retrieval");
    }

    // Get container configuration
    InspectContainerResponse inspectX = dockerClient.inspectContainerCmd(validatorContainerId).exec();
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

    // Get IP address if available
    String ipAddress = null;
    try {
      if (inspectX.getNetworkSettings() != null && 
          inspectX.getNetworkSettings().getNetworks() != null && 
          !inspectX.getNetworkSettings().getNetworks().isEmpty()) {
        ipAddress = inspectX.getNetworkSettings().getNetworks().values().iterator().next().getIpAddress();
      }
    } catch (Exception e) {
      log.warn("Could not retrieve IP address for validator container {}: {}", containerName, e.getMessage());
    }

    // Stop and remove the existing container
    dockerClient.stopContainerCmd(validatorContainerId).exec();
    dockerClient.removeContainerCmd(validatorContainerId).withForce(true).exec();

    // Create new container with the same configuration but new volume
    CreateContainerCmd createCmd = dockerClient
        .createContainerCmd(GENESIS_IMAGE_NAME)
        .withName(containerName)
        .withVolumes(new Volume(CONTAINER_DB_PATH), new Volume("/usr/share/data"))
        .withEnv(envs)
        .withHealthcheck(healthCheck)
        .withHostConfig(
            newHostConfig()
                .withNetworkMode(networkMode)
                .withPortBindings(portBindings)
                .withBinds(
                    new Bind(targetVolume, new Volume(CONTAINER_DB_PATH)),
                    new Bind("mylocalton-docker_shared-data", new Volume("/usr/share/data"))
                )
        );

    // Add exposed ports if they exist
    if (exposedPorts != null) {
      createCmd.withExposedPorts(exposedPorts);
    }

    // Add IP address if available
    if (ipAddress != null) {
      createCmd.withIpv4Address(ipAddress);
    }

    CreateContainerResponse newContainer = createCmd.exec();

    dockerClient.startContainerCmd(newContainer.getId()).exec();
    log.info("Validator container {} recreated and started", containerName);
  }

  private void recreateGenesisContainerWithConfig(
      String targetVolume, 
      ContainerConfig config, 
      HostConfig hostConfig, 
      String ipAddress) throws Exception {
    
    log.info("Recreating genesis container with volume and saved config: {}", targetVolume);
    
    if (config == null || hostConfig == null) {
      log.warn("No saved configuration found for genesis container, using default recreation method");
      recreateGenesisContainer(targetVolume);
      return;
    }

    String[] envs = config.getEnv();
    
    ExposedPort[] exposedPorts = config.getExposedPorts();
    HealthCheck healthCheck = config.getHealthcheck();
    String networkMode = hostConfig.getNetworkMode();

    Ports portBindings = new Ports();
    if (exposedPorts != null) {
      for (ExposedPort exposedPort : exposedPorts) {
        portBindings.bind(exposedPort, Ports.Binding.bindPort(exposedPort.getPort()));
      }
    }

    // Create new container with the saved configuration but new volume
    CreateContainerCmd createCmd = dockerClient
        .createContainerCmd(GENESIS_IMAGE_NAME)
        .withName(CONTAINER_GENESIS)
        .withVolumes(new Volume(CONTAINER_DB_PATH), new Volume("/usr/share/data"))
        .withEnv(envs)
        .withHealthcheck(healthCheck)
        .withHostConfig(
            newHostConfig()
                .withNetworkMode(networkMode)
                .withPortBindings(portBindings)
                .withBinds(
                    new Bind(targetVolume, new Volume(CONTAINER_DB_PATH)),
                    new Bind("mylocalton-docker_shared-data", new Volume("/usr/share/data"))
                )
        );

    // Add exposed ports if they exist
    if (exposedPorts != null) {
      createCmd.withExposedPorts(exposedPorts);
    }

    // Add IP address if available
    if (ipAddress != null) {
      createCmd.withIpv4Address(ipAddress);
    }

    CreateContainerResponse newContainer = createCmd.exec();

    dockerClient.startContainerCmd(newContainer.getId()).exec();
    log.info("Genesis container recreated and started with saved config");
  }

  private void recreateValidatorContainerWithConfig(
      String containerName,
      String targetVolume, 
      ContainerConfig config, 
      HostConfig hostConfig, 
      String ipAddress) throws Exception {
    
    log.info("Recreating validator container {} with volume and saved config: {}", containerName, targetVolume);
    
    if (config == null || hostConfig == null) {
      log.warn("No saved configuration found for validator container {}, using default recreation method", containerName);
      recreateValidatorContainer(containerName, targetVolume);
      return;
    }

    log.info("recreateValidatorContainerWithConfig 1");

    String[] envs = config.getEnv();
    
    ExposedPort[] exposedPorts = config.getExposedPorts();
    HealthCheck healthCheck = config.getHealthcheck();
    String networkMode = hostConfig.getNetworkMode();

    Ports portBindings = new Ports();
    if (exposedPorts != null) {
      for (ExposedPort exposedPort : exposedPorts) {
        portBindings.bind(exposedPort, Ports.Binding.bindPort(exposedPort.getPort()));
      }
    }

    log.info("recreateValidatorContainerWithConfig 2");

    // Create new container with the saved configuration but new volume
    CreateContainerCmd createCmd = dockerClient
        .createContainerCmd(GENESIS_IMAGE_NAME)
        .withName(containerName)
        .withVolumes(new Volume(CONTAINER_DB_PATH), new Volume("/usr/share/data"))
        .withEnv(envs)
        .withHealthcheck(healthCheck)
        .withHostConfig(
            newHostConfig()
                .withNetworkMode(networkMode)
                .withPortBindings(portBindings)
                .withBinds(
                    new Bind(targetVolume, new Volume(CONTAINER_DB_PATH)),
                    new Bind("mylocalton-docker_shared-data", new Volume("/usr/share/data"))
                )
        );

    log.info("recreateValidatorContainerWithConfig 3");

    // Add exposed ports if they exist
    if (exposedPorts != null) {
      createCmd.withExposedPorts(exposedPorts);
    }

    // Add IP address if available
    if (ipAddress != null) {
      createCmd.withIpv4Address(ipAddress);
    }

    CreateContainerResponse newContainer = createCmd.exec();

    log.info("recreateValidatorContainerWithConfig 4");

    dockerClient.startContainerCmd(newContainer.getId()).exec();
    log.info("Validator container {} recreated and started with saved config", containerName);

    log.info("recreateValidatorContainerWithConfig 5");
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


  private void waitForSeqnoVolumeHealthy() {
    int maxRetries = 60; // Wait up to 5 minutes (60 * 5 seconds)
    int retryCount = 0;

    log.info("Waiting for seqno-volume endpoint to be healthy...");

    while (retryCount < maxRetries) {
      try {
        // Try to call the seqno-volume endpoint
        long delta = getSyncDelay();
        log.info("Sync delay: {} seconds (attempt {})", delta, retryCount + 1);

        if (delta < 10) {
          log.info("Seqno-volume endpoint is healthy after {} attempts (sync delay: {} seconds)", retryCount + 1, delta);
          return; // Success, exit the method
        }

      } catch (Exception e) {
        log.warn("Seqno-volume endpoint error (attempt {}): {}", retryCount + 1, e.getMessage());
        // Don't return on error, continue trying
      }

      retryCount++;

      // Wait 5 seconds before next attempt
      try {
        Thread.sleep(5000);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        log.warn("Health check interrupted");
        return;
      }
    }

    log.warn("Seqno-volume endpoint did not become healthy after {} attempts (max {} minutes), but continuing anyway", maxRetries, maxRetries * 5 / 60);
  }

  public long getSyncDelay() throws Exception {
    MasterchainInfo masterChainInfo = getMasterchainInfo();
    Block block = Main.adnlLiteClient.getBlock(masterChainInfo.getLast()).getBlock();
    long delta = Utils.now() - block.getBlockInfo().getGenuTime();
    log.info("getSyncDelay {}", delta);
    return delta;
  }
}
