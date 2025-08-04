package org.ton.mylocaltondocker.timemachine.controller;

import com.github.dockerjava.api.DockerClient;
import com.github.dockerjava.api.command.*;
import com.github.dockerjava.api.exception.NotFoundException;
import com.github.dockerjava.api.model.*;
import com.github.dockerjava.core.DefaultDockerClientConfig;
import com.github.dockerjava.core.DockerClientBuilder;
import com.github.dockerjava.okhttp.OkDockerHttpClient;
import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import lombok.extern.slf4j.Slf4j;
import org.codehaus.plexus.util.StringUtils;
import org.ton.mylocaltondocker.timemachine.Main;
import org.ton.ton4j.tl.liteserver.responses.MasterchainInfo;
import org.ton.ton4j.tlb.Block;
import org.ton.ton4j.utils.Utils;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.*;
import java.util.concurrent.CompletableFuture;

import static com.github.dockerjava.api.model.HostConfig.newHostConfig;

@Slf4j
public class MltUtils {

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

  public static void storeSnapshotConfiguration(SnapshotConfig snapshotConfig) throws Exception {
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

  public static boolean isConfigExist(int snapshotNumber) {
    return Files.exists(Path.of("/usr/share/data/config-snapshot-" + snapshotNumber + ".json"));
  }

  public static SnapshotConfig getCurrentSnapshotConfig(DockerClient dockerClient) {
    List<String> runningContainers = getAllCurrentlyRunningContainers(dockerClient);
    Map<String, DockerContainer> dockerContainers = new HashMap<>();

    for (String containerName : runningContainers) {
      DockerContainer dockerContainer =
          getDockerContainerConfiguration(dockerClient, containerName);
      dockerContainers.put(containerName, dockerContainer);
    }

    return SnapshotConfig.builder()
        .runningContainers(runningContainers)
        .containers(dockerContainers)
        .build();
  }

  public static List<String> getAllCurrentlyRunningContainers(DockerClient dockerClient) {
    List<String> runningContainers = new ArrayList<>();
    List<String> allContainers = getAllContainers();

    for (String containerName : allContainers) {
      try {
        String containerId = getContainerIdByName(dockerClient, containerName);
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

    //    log.info("Found {} currently running containers: {}", runningContainers.size(),
    // runningContainers);
    return runningContainers;
  }

  public static DockerContainer getDockerContainerConfiguration(
      DockerClient dockerClient, String containerName) {
    try {
      String containerId = getContainerIdByName(dockerClient, containerName);
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

  public static String getContainerIdByName(DockerClient dockerClient, String containerName) {
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

  public static String getCurrentVolume(DockerClient dockerClient, String containerId) {
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

  public static List<String> getAllContainers() {

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

  public static List<String> getAllCurrentlyRunningValidatorContainers(DockerClient dockerClient) {
    List<String> runningValidatorContainers = new ArrayList<>();

    for (String containerName : VALIDATOR_CONTAINERS) {
      try {
        String containerId = MltUtils.getContainerIdByName(dockerClient, containerName);
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

    return runningValidatorContainers;
  }

  public static String getGenesisContainerId(DockerClient dockerClient) {
    return dockerClient
        .listContainersCmd()
        .withNameFilter(List.of(CONTAINER_GENESIS))
        .exec()
        .stream()
        .findFirst()
        .map(c -> c.getId())
        .orElse(null);
  }

  public static List<String> getAllRunningContainers(DockerClient dockerClient) {
    List<String> runningContainers = new ArrayList<>();

    // Check each validator
    for (String validatorContainer : MltUtils.getAllContainers()) {
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

  public static int getNextInstanceNumber(DockerClient dockerClient, int snapshotNumber) {
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

  /** Helper method to stop and remove a group of containers in parallel. */
  public static void stopAndRemoveContainerGroup(
      DockerClient dockerClient, List<String> containerNames) {
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
        String containerId = MltUtils.getContainerIdByName(dockerClient, containerName);
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
  public static void createContainerGroup(
      DockerClient dockerClient, List<DockerContainer> containers) {

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
                            createContainerWithConfig(dockerClient, dockerContainer);
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

  public static void createContainerWithConfig(
      DockerClient dockerClient, DockerContainer dockerContainer) {

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

  /**
   * Stops and removes specific containers by name with proper shutdown ordering. Extra services are
   * stopped first, then genesis+validators. This method ensures all containers from the list are
   * removed, regardless of their current state.
   */
  public static void stopAndRemoveSpecificContainers(
      DockerClient dockerClient, List<String> containerNames) {

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
      MltUtils.stopAndRemoveContainerGroup(dockerClient, extraServices);
    }

    if (!coreContainers.isEmpty()) {
      log.info("STEP 2: Stopping core blockchain containers");
      MltUtils.stopAndRemoveContainerGroup(dockerClient, coreContainers);
    }
  }

  public static String getActiveNodeIdFromVolume(DockerClient dockerClient) {
    try {
      String genesisContainerId = getGenesisContainerId(dockerClient);
      if (StringUtils.isEmpty(genesisContainerId)) {
        return "0";
      }

      String currentVolume = getCurrentVolume(dockerClient, genesisContainerId);
      if ((currentVolume == null)
          || currentVolume.equals("mylocalton-docker_ton-db-val0")
          || currentVolume.equals("ton-db-val0-snapshot-0-1")) {
        return "0";
      }

      if (currentVolume.contains("snapshot-")) {
        String parts[] = currentVolume.split("snapshot-");
        if (parts.length > 1) {
          return parts[1];
        }
      }

      return "0";
    } catch (Exception e) {
      log.warn("Error determining active node ID from volume: {}", e.getMessage());
      return "0";
    }
  }

  /**
   * Adds or updates CUSTOM_PARAMETERS environment variable with -T seqno flag
   *
   * @param envs existing environment variables array
   * @param seqnoStr seqno value from frontend
   * @return updated environment variables array with CUSTOM_PARAMETERS containing -T seqno
   */
  public static String[] addCustomParametersWithSeqno(String[] envs, String seqnoStr) {
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
  public static String replaceOrAddTParameter(String existingParams, String newTParam) {
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

  public static void replaceVolumeInConfig(
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

  public static long getCurrentBlockSequence() throws Exception {
    return getMasterchainInfo().getLast().getSeqno();
  }

  public static synchronized MasterchainInfo getMasterchainInfo() throws Exception {
    return Main.adnlLiteClient.getMasterchainInfo();
  }

  public static long getSyncDelay() throws Exception {
    MasterchainInfo masterChainInfo = getMasterchainInfo();
    Block block = Main.adnlLiteClient.getBlock(masterChainInfo.getLast()).getBlock();
    return Utils.now() - block.getBlockInfo().getGenuTime();
  }

  public static void deleteSnapshotConfiguration(String snapshotNumber) throws Exception {
    String configPath = "/usr/share/data/config-snapshot-" + snapshotNumber + ".json";
    log.info("deleting {}", configPath);
    File configFile = new File(configPath);

    if (!configFile.exists()) {
      log.error(
          "Snapshot configuration file not found for snapshot {}: {}", snapshotNumber, configPath);
    }

    Files.delete(Paths.get(configPath));
  }

  public static SnapshotConfig loadSnapshotConfiguration(String snapshotNumber) throws Exception {
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

  public static void copyVolume(
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
}
