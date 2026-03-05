package org.ton.mylocaltondocker.adminportal.controller;

import java.util.Arrays;
import lombok.Getter;
import lombok.RequiredArgsConstructor;

@Getter
@RequiredArgsConstructor
public enum ManagedService {
  FILE_SERVER("file-server", "File Server", "file-server", "file-server", 8000, 8000, "/", "/"),
  DATA_GENERATOR("data-generator", "Data Generator", "data", "data-generator", 99, 99, "/", "/"),
  FAUCET("faucet", "Faucet", "faucet", "faucet", 88, 88, "/", "/"),
  BLOCKCHAIN_EXPLORER(
      "blockchain-explorer",
      "Blockchain Explorer",
      "blockchain-explorer",
      "blockchain-explorer",
      8080,
      8080,
      "/last",
      "/last"),
  TIME_MACHINE(
      "time-machine", "Time Machine", "time-machine", "time-machine", 8083, 8083, "/", "/"),
  CONFIG_UPDATE(
      "config-update", "Config Update", "config-update", "config-update", 8084, 8084, "/", "/"),
  TON_CENTER_V2(
      "ton-center-v2",
      "TON Center V2",
      "tonhttpapi",
      "ton-http-api-v2",
      8082,
      8081,
      "/api/v2/",
      "/api/v2/getMasterchainInfo"),
  TON_CENTER_V3(
      "ton-center-v3", "TON Center V3", "index-api", "index-api", 8081, 8081, "/", "/");

  private final String id;
  private final String name;
  private final String composeService;
  private final String containerName;
  private final int defaultHostPort;
  private final int containerPort;
  private final String path;
  private final String healthPath;

  public String buildUrl(int hostPort) {
    return "http://localhost:" + hostPort + path;
  }

  public static ManagedService fromId(String id) {
    return Arrays.stream(values()).filter(service -> service.id.equals(id)).findFirst().orElse(null);
  }
}
