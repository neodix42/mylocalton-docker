package org.ton.mylocaltondocker.timemachine.controller;

import lombok.Builder;
import lombok.Data;
import org.apache.commons.lang3.ArrayUtils;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

@Builder
@Data
public class SnapshotConfig {
  String snapshotNumber;
  long timestamp;
  List<String> runningContainers;
  Map<String, DockerContainer> containers;

  static String[] CORE_CONTAINERS = {
    "genesis", "validator-1", "validator-2", "validator-3", "validator-4", "validator-5"
  };

  static String[] INDEXER_CONTAINERS = {"index-worker", "index-postgres"};

  static String[] EXTRA_CONTAINERS = {
    "blockchain-explorer", "explorer-restarter", "faucet", "ton-http-api-v2", "data-generator"
  };

  static String[] ALL_INDEXER_CONTAINERS = {
    "index-postgres", "run-migrations", "index-event-cache", "index-event-classifier", "index-worker", "index-api"
  };

  static String[] ALL_CONTAINERS = { // except file-server and time-machine
          "genesis",
          "blockchain-explorer",
          "validator-1",
          "validator-2",
          "explorer-restarter",
          "ton-http-api-v2",
          "validator-3",
          "validator-4",
          "validator-5",
          "faucet",
          "data-generator",
          "run-migrations",
          "index-event-cache",
          "index-event-classifier",
          "index-api",
          "index-worker",
          "index-postgres"
  };

  static String[] ALL_CONTAINERS_FOR_CLEANUP = {
          "genesis",
          "blockchain-explorer",
          "validator-1",
          "validator-2",
          "explorer-restarter",
          "ton-http-api-v2",
          "validator-3",
          "validator-4",
          "validator-5",
          "faucet",
          "data-generator",
          "file-server",
//          "time-machine",
          "run-migrations",
          "index-event-cache",
          "index-event-classifier",
          "index-api",
          "index-worker",
          "index-postgres"
  };


  public List<DockerContainer> getCoreContainers() {
    List<DockerContainer> result = new ArrayList<>();
    for (Map.Entry<String, DockerContainer> dockerContainer : containers.entrySet()) {
      if (ArrayUtils.contains(CORE_CONTAINERS, dockerContainer.getKey())) {
        result.add(dockerContainer.getValue());
      }
    }
    return result;
  }

  public List<DockerContainer> getIndexerContainersWithVolumes() {
    List<DockerContainer> result = new ArrayList<>();
    for (Map.Entry<String, DockerContainer> dockerContainer : containers.entrySet()) {
      if (ArrayUtils.contains(INDEXER_CONTAINERS, dockerContainer.getKey())) {
        result.add(dockerContainer.getValue());
      }
    }
    return result;
  }

  public List<DockerContainer> getAllIndexerContainers() {
    List<DockerContainer> result = new ArrayList<>();
    for (Map.Entry<String, DockerContainer> dockerContainer : containers.entrySet()) {
      if (ArrayUtils.contains(ALL_INDEXER_CONTAINERS, dockerContainer.getKey())) {
        result.add(dockerContainer.getValue());
      }
    }
    return result;
  }

  public List<DockerContainer> getExtraContainers() {
    List<DockerContainer> result = new ArrayList<>();
    for (Map.Entry<String, DockerContainer> dockerContainer : containers.entrySet()) {
      if (ArrayUtils.contains(EXTRA_CONTAINERS, dockerContainer.getKey())) {
        result.add(dockerContainer.getValue());
      }
    }
    return result;
  }
}
