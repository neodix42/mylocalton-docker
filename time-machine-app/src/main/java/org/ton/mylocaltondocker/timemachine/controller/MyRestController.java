package org.ton.mylocaltondocker.timemachine.controller;

import static java.util.Objects.isNull;
import static org.ton.mylocaltondocker.timemachine.controller.MltUtils.*;
import static org.ton.mylocaltondocker.timemachine.controller.SnapshotConfig.ALL_CONTAINERS;
import static org.ton.mylocaltondocker.timemachine.controller.StartUpTask.dockerClient;
import static org.ton.mylocaltondocker.timemachine.controller.StartUpTask.reinitializeAdnlLiteClient;

import com.github.dockerjava.api.exception.NotFoundException;

import java.io.File;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.*;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.reflect.TypeToken;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.io.FileUtils;
import org.codehaus.plexus.util.StringUtils;
import org.springframework.web.bind.annotation.*;
import org.ton.ton4j.tl.liteserver.responses.MasterchainInfo;

@RestController
@Slf4j
public class MyRestController {

  @GetMapping("/seqno-volume")
  public Map<String, Object> getSeqno() {
    try {

      int activeNodes = MltUtils.getAllCurrentlyRunningValidatorContainers(dockerClient).size();

      if (activeNodes > 0) {

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

        String id = MltUtils.getActiveNodeIdFromVolume(dockerClient);
        long syncDelay = getSyncDelay();
        Map<String, Object> response = new HashMap<>();
        response.put("success", true);
        response.put("seqno", masterChainInfo.getLast().getSeqno());
        response.put("id", id);
        response.put("activeNodes", activeNodes);
        response.put("syncDelay", syncDelay);
        return response;
      } else { // no nodes are running, blockchain is down
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "activeNodes = 0");
        return response;
      }
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
      int activeNodes = MltUtils.getAllCurrentlyRunningValidatorContainers(dockerClient).size();
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

  @GetMapping("/health-check")
  public Map<String, Object> checkLinksHealth() {
    Map<String, Object> response = new HashMap<>();
    Map<String, String> linkStatuses = new HashMap<>();
    
    // Define the links to check with their Docker network IP addresses
    Map<String, String> linksToCheck = new HashMap<>();
    linksToCheck.put("8080", "http://172.28.1.20:8080/last"); // blockchain-explorer
    linksToCheck.put("8082", "http://172.28.1.105:8082"); // ton-http-api (TON Center V2)
    linksToCheck.put("8081", "http://172.28.1.102:8081"); // index-api (TON Center V3)
    linksToCheck.put("88", "http://172.28.1.21:88"); // faucet
    linksToCheck.put("99", "http://172.28.1.22:99"); // data-generator
    linksToCheck.put("8000", "http://172.28.1.24:8000"); // file-server

    for (Map.Entry<String, String> entry : linksToCheck.entrySet()) {
      String port = entry.getKey();
      String url = entry.getValue();
      String status = checkSingleLinkHealth(url);
      linkStatuses.put(port, status);
    }
    
    response.put("success", true);
    response.put("linkStatuses", linkStatuses);
    return response;
  }
  
  private String checkSingleLinkHealth(String urlString) {
    try {
      URL url = new URL(urlString);
      HttpURLConnection connection = (HttpURLConnection) url.openConnection();
      connection.setRequestMethod("GET");
      connection.setConnectTimeout(2000); // 2 second timeout
      connection.setReadTimeout(2000); // 2 second timeout
      
      connection.getResponseCode();
      connection.disconnect();
      
      // Consider any response (even errors like 404, 500) as "online" since the service is responding
      return "online";
      
    } catch (Exception e) {
      return "down";
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
        TypeToken<Map<String, Object>> typeToken = new TypeToken<>() {};
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

  @PostMapping("/take-snapshot")
  public Map<String, Object> takeSnapshot(@RequestBody Map<String, String> request) {
    try {

      // Discover all running containers (including all services, not just genesis + validators)
      List<String> runningContainers = MltUtils.getAllCurrentlyRunningContainers(dockerClient);
      if (runningContainers.isEmpty()) {
        log.error("No containers found");
        isSnapshotInProgress = false;
        currentSnapshotStatus = "Ready";
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "No containers found");
        return response;
      } else {
        log.info("Found running containers: {}", runningContainers);
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

      // Check if we're taking snapshot from active (running) node
      String parentId = request.get("parentId");
      String activeNodeId = MltUtils.getActiveNodeIdFromVolume(dockerClient);
      log.info(
          "/take-snapshot, parentSnapshotNumber: {}, snapshotNumber {}, activeNodeId {}",
          parentId,
          snapshotNumber,
          activeNodeId);

      boolean isFromActiveNode = parentId != null && parentId.equals(activeNodeId);

      List<String> runningValidators =
          MltUtils.getAllCurrentlyRunningValidatorContainers(dockerClient);

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

      SnapshotConfig snapshotConfig;
      SnapshotConfig snapshotConfigNew;

      if (shouldShutdownBlockchain) {
        snapshotConfig = MltUtils.getCurrentSnapshotConfig(dockerClient);
        snapshotConfig.setSnapshotNumber(parentId);
        MltUtils.storeSnapshotConfiguration(snapshotConfig);

        snapshotConfigNew = MltUtils.loadSnapshotConfiguration(parentId);
        snapshotConfigNew.setSnapshotNumber(snapshotNumber);
        snapshotConfigNew.setTimestamp(System.currentTimeMillis());

        currentSnapshotStatus = "Stopping blockchain...";
        log.info("Shutting down blockchain (all containers) before taking snapshots");
        stopAndRemoveAllContainers();
      } else {
        snapshotConfig = MltUtils.loadSnapshotConfiguration(parentId);
        snapshotConfigNew = MltUtils.loadSnapshotConfiguration(parentId);
        snapshotConfigNew.setSnapshotNumber(snapshotNumber);
        snapshotConfigNew.setTimestamp(System.currentTimeMillis());
      }

      // Create snapshots for all containers in parallel
      currentSnapshotStatus = "Taking snapshot...";

      // copy volumes in parallel
      copyVolumesInParallel(dockerClient, snapshotConfig.getCoreContainers(), snapshotNumber);
      copyVolumesInParallel(dockerClient, snapshotConfig.getIndexerContainersWithVolumes(), snapshotNumber);

      replaceVolumesInConfig(snapshotConfig, snapshotConfigNew);

      MltUtils.storeSnapshotConfiguration(snapshotConfigNew);

      Map<String, Object> response = new HashMap<>();

      // If blockchain was shutdown, restart it with the same volumes and configurations
      if (shouldShutdownBlockchain) {
        try {
          currentSnapshotStatus = "Starting blockchain...";

          MltUtils.createContainerGroup(dockerClient, snapshotConfig.getCoreContainers());

          // Wait for lite-server to be ready before setting status to Ready
          currentSnapshotStatus = "Waiting for lite-server to be ready";
          if (waitForSeqnoVolumeHealthy()) {
            currentSnapshotStatus = "Starting extra services...";
            MltUtils.createContainerGroup(dockerClient, snapshotConfig.getExtraContainers());
            MltUtils.createIndexerV3ContainersSequentially(dockerClient, snapshotConfig.getAllIndexerContainers());
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
        activeNodesCount = MltUtils.getAllCurrentlyRunningValidatorContainers(dockerClient).size();
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

      SnapshotConfig snapshotConfig = MltUtils.loadSnapshotConfiguration(snapshotId);
      SnapshotConfig snapshotConfigNew = MltUtils.loadSnapshotConfiguration(snapshotId);

      int instanceNumber = 0;
      boolean isNewInstance = false;
      long lastKnownSeqno = 0;

      if (!MltUtils.getAllCurrentlyRunningValidatorContainers(dockerClient).isEmpty()) {

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

        currentSnapshotStatus = "Stopping blockchain...";
        stopAndRemoveAllContainers();

      } else {
        log.info("Skipping saving blockchain state, since nothing is running...");
      }

      String snapshotAndInstanceNumber = "";
      if ("instance".equals(nodeType) || "root".equals(nodeType)) {
        log.info("restore instance or root node");
      } else { // copy volumes
        // Restoring from snapshot node - create new instances for containers that have snapshots
        instanceNumber =
            MltUtils.getNextInstanceNumber(dockerClient, Integer.parseInt(snapshotNumber));
        isNewInstance = true;

        snapshotAndInstanceNumber = snapshotNumber + "-" + instanceNumber;

        snapshotConfigNew.setSnapshotNumber(snapshotAndInstanceNumber);

        log.info(
            "instanceNumber: {}, newSnapshotNumber {}", instanceNumber, snapshotAndInstanceNumber);

        // copy volume to instance volume
        copyVolumesInParallel(
            dockerClient, snapshotConfig.getCoreContainers(), snapshotAndInstanceNumber);
        copyVolumesInParallel(
            dockerClient, snapshotConfig.getIndexerContainersWithVolumes(), snapshotAndInstanceNumber);

        replaceVolumesInConfig(snapshotConfig, snapshotConfigNew);

        MltUtils.storeSnapshotConfiguration(snapshotConfigNew);
      }

      currentSnapshotStatus = "Starting blockchain from the snapshot...";

      MltUtils.createContainerGroup(dockerClient, snapshotConfigNew.getCoreContainers());

      log.info("Snapshots restored for all containers using snapshotId: {}", snapshotId);

      currentSnapshotStatus = "Waiting for lite-server to be ready";

      if (waitForSeqnoVolumeHealthy()) {
        currentSnapshotStatus = "Starting extra-services...";
        MltUtils.createContainerGroup(dockerClient, snapshotConfigNew.getExtraContainers());
        MltUtils.createIndexerV3ContainersSequentially(dockerClient, snapshotConfigNew.getAllIndexerContainers());

        Map<String, Object> response = new HashMap<>();
        response.put("success", true);
        response.put("message", "Snapshots restored successfully for all containers");
        response.put("id", snapshotAndInstanceNumber);
        response.put("instanceNumber", instanceNumber);
        response.put("isNewInstance", isNewInstance);
        response.put("lastKnownSeqno", lastKnownSeqno);
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

      SnapshotConfig snapshotConfig = MltUtils.loadSnapshotConfiguration(snapshotInstanceNumber);
      Map<String, Object> response = new HashMap<>();

      if (isNull(snapshotConfig)) {
        response.put("success", true);
        response.put("message", "Snapshot not found, nothing to delete");
        return response;
      }

      // Check if any of the volumes to delete are currently in use
      String genesisContainerId = MltUtils.getGenesisContainerId(dockerClient);
      String currentVolume = null;

      if (!StringUtils.isEmpty(genesisContainerId)) {
        currentVolume = MltUtils.getCurrentVolume(dockerClient, genesisContainerId);
      }

      // Build list of volumes to delete from nodesToDelete list
      List<String> volumesToDelete = new ArrayList<>();

      @SuppressWarnings("unchecked")
      List<Map<String, Object>> nodesToDelete =
          (List<Map<String, Object>>) request.get("nodesToDelete");

      if (nodesToDelete != null && !nodesToDelete.isEmpty()) {
        // Delete volumes for all nodes in the list (including all container types)
        for (Map<String, Object> nodeToDelete : nodesToDelete) {

          log.info("node to delete {}", nodeToDelete.get("id"));
          MltUtils.deleteSnapshotConfiguration(nodeToDelete.get("id").toString());

          for (String validatorContainer : VALIDATOR_CONTAINERS) {
            String baseVolumeName = CONTAINER_VOLUME_MAP.get(validatorContainer);
            String validatorInstanceVolume = baseVolumeName + "-snapshot-" + nodeToDelete.get("id");
            volumesToDelete.add(validatorInstanceVolume);
          }
        }
      }

      log.info("to delete {}", List.of(volumesToDelete).toArray());

      if (currentVolume != null && volumesToDelete.contains(currentVolume)) {
        log.warn("Attempting to delete currently active volume: {}", currentVolume);

        // If trying to delete active volume, return error immediately
        response.put("success", false);
        response.put(
            "message",
            "Cannot delete currently active snapshot. Please switch to a different snapshot first.");
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
        response.put(
            "message", "Failed to delete some volumes: " + String.join(", ", failedVolumes));
        response.put("deletedVolumes", deletedVolumes);
        response.put("failedVolumes", failedVolumes);
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
    List<String> runningContainers = List.of(ALL_CONTAINERS);;

    if (runningContainers.isEmpty()) {
      log.info("No containers to stop");
      return;
    }

    MltUtils.stopAndRemoveSpecificContainers(dockerClient, runningContainers);
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

      } catch (Throwable e) {
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

  @PostMapping("/stop-blockchain")
  public Map<String, Object> stopBlockchain() {
    try {
      log.info("Stopping blockchain - stopping and removing all containers except time-machine");

      currentSnapshotStatus = "Saving current state...";
      String id = MltUtils.getActiveNodeIdFromVolume(dockerClient);
      log.info("found active snapshot id: {}", id);

      SnapshotConfig snapshotConfig = MltUtils.getCurrentSnapshotConfig(dockerClient);
      snapshotConfig.setSnapshotNumber(id);
      snapshotConfig.setTimestamp(System.currentTimeMillis());
      MltUtils.storeSnapshotConfiguration(snapshotConfig);

      currentSnapshotStatus = "Stopping blockchain...";

      List<String> containersToStopAndRemove = MltUtils.getAllRunningContainers(dockerClient);

      if (containersToStopAndRemove.isEmpty()) {
        log.info("No containers found to stop");
        Map<String, Object> response = new HashMap<>();
        response.put("success", true);
        response.put("message", "No containers found to stop");
        response.put("stoppedContainers", 0);
        return response;
      }

      log.info("Stopping {} running containers: {}", containersToStopAndRemove.size(), containersToStopAndRemove);

      MltUtils.stopAndRemoveSpecificContainers(dockerClient, containersToStopAndRemove);

      Map<String, Object> response = new HashMap<>();
      response.put("success", true);
      response.put("message", "Blockchain stopped successfully");
      response.put("stoppedContainers", containersToStopAndRemove.size());
      response.put("containerNames", containersToStopAndRemove);

      log.info("Successfully stopped {} containers", containersToStopAndRemove.size());
      return response;

    } catch (Exception e) {
      log.error("Error stopping blockchain", e);
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to stop blockchain: " + e.getMessage());
      return response;
    }
  }

  @PostMapping("/start-over")
  public Map<String, Object> startOver(@RequestBody Map<String, String> request) {
    try {
      log.info("Starting blockchain reset with new configuration");

      currentSnapshotStatus = "Stopping current blockchain...";

      // Stop all running containers first
      List<String> containersToStopAndRemove = MltUtils.getAllRunningContainers(dockerClient);
      if (!containersToStopAndRemove.isEmpty()) {
        log.info("Stopping {} running containers before reset", containersToStopAndRemove.size());
        MltUtils.stopAndRemoveSpecificContainers(dockerClient, containersToStopAndRemove);
      }

      deleteVolumes(dockerClient, "ton-db-");

      deleteSnapshots();

      currentSnapshotStatus = "Updating genesis configuration...";

      // Load the genesis snapshot configuration (snapshot 0)
      SnapshotConfig snapshotConfig = MltUtils.loadSnapshotConfiguration("0");
      if (isNull(snapshotConfig)) {
        log.error("Genesis snapshot configuration not found");
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "Genesis snapshot configuration not found");
        return response;
      }

      // Get the genesis container
      DockerContainer genesis = snapshotConfig.getContainers().get("genesis");
      if (isNull(genesis)) {
        log.error("Genesis container not found in snapshot configuration");
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "Genesis container not found in snapshot configuration");
        return response;
      }

      // Update environment variables in the genesis container
      String[] currentEnv = genesis.getContainerConfig().getEnv();
      List<String> newEnvList = new ArrayList<>();

      // Create a map of existing environment variables
      Map<String, String> existingEnvMap = new HashMap<>();
      if (currentEnv != null) {
        for (String env : currentEnv) {
          String[] parts = env.split("=", 2);
          if (parts.length == 2) {
            existingEnvMap.put(parts[0], parts[1]);
          }
        }
      }

      // Update with new values from the request
      for (Map.Entry<String, String> entry : request.entrySet()) {
        String key = entry.getKey();
        String value = entry.getValue();
        existingEnvMap.put(key, value);
        log.info("Updated environment variable: {}={}", key, value);
      }

      // Convert back to array format
      for (Map.Entry<String, String> entry : existingEnvMap.entrySet()) {
        newEnvList.add(entry.getKey() + "=" + entry.getValue());
      }

      // Update the container configuration with new environment variables
      genesis.getContainerConfig().withEnv(newEnvList.toArray(new String[0]));

      // Save the updated configuration
      MltUtils.storeSnapshotConfiguration(snapshotConfig);

      currentSnapshotStatus = "Starting new blockchain...";

      // Start the blockchain with the updated configuration
      MltUtils.createContainerGroup(dockerClient, snapshotConfig.getCoreContainers());

      // Wait for lite-server to be ready
      currentSnapshotStatus = "Waiting for lite-server to be ready";
      if (waitForSeqnoVolumeHealthy()) {
        currentSnapshotStatus = "Starting extra services...";
        MltUtils.createContainerGroup(dockerClient, snapshotConfig.getExtraContainers());
        MltUtils.createIndexerV3ContainersSequentially(dockerClient, snapshotConfig.getAllIndexerContainers());

        Map<String, Object> response = new HashMap<>();
        response.put("success", true);
        response.put("message", "Blockchain reset successfully with new configuration");
        return response;
      } else {
        currentSnapshotStatus = "Blockchain cannot be started, see docker logs.";
        Map<String, Object> response = new HashMap<>();
        response.put("success", false);
        response.put("message", "Blockchain cannot be started after reset, see docker logs.");
        return response;
      }

    } catch (Exception e) {
      log.error("Error resetting blockchain", e);
      Map<String, Object> response = new HashMap<>();
      response.put("success", false);
      response.put("message", "Failed to reset blockchain: " + e.getMessage());
      return response;
    }
  }
}
