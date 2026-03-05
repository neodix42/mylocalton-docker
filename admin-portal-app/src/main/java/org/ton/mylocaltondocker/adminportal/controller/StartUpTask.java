package org.ton.mylocaltondocker.adminportal.controller;

import com.github.dockerjava.api.DockerClient;
import java.nio.file.Files;
import java.nio.file.Path;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

@Component
@Slf4j
public class StartUpTask {

  public static DockerClient dockerClient;

  @EventListener(ApplicationReadyEvent.class)
  public void onApplicationReady() throws Exception {

    Path dockerSockPath = Path.of("/var/run/docker.sock");

    while (!Files.exists(dockerSockPath)) {
      log.info("admin-portal-app is waiting for {}", dockerSockPath);
      Thread.sleep(3000);
    }

    dockerClient = AdminPortalUtils.createDockerClient();
    log.info("dockerClient initialized");

    log.info("admin-portal-app ready");
  }
}
