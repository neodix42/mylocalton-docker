package org.ton.mylocaltondocker.adminportal.controller;

import com.github.dockerjava.api.DockerClient;
import com.github.dockerjava.api.model.Container;
import com.github.dockerjava.core.DefaultDockerClientConfig;
import com.github.dockerjava.core.DockerClientBuilder;
import com.github.dockerjava.okhttp.OkDockerHttpClient;
import java.util.Arrays;
import java.util.List;
import java.util.Optional;

public class AdminPortalUtils {

  private AdminPortalUtils() {}

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

  public static Optional<Container> findContainerByName(List<Container> containers, String containerName) {
    return containers.stream()
        .filter(
            container -> {
              String[] names = container.getNames();
              if (names == null) {
                return false;
              }
              return Arrays.stream(names)
                  .anyMatch(name -> name.equals("/" + containerName) || name.equals(containerName));
            })
        .findFirst();
  }
}
