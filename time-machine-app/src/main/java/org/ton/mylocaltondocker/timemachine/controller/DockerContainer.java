package org.ton.mylocaltondocker.timemachine.controller;

import com.github.dockerjava.api.model.ContainerConfig;
import com.github.dockerjava.api.model.HostConfig;
import lombok.Builder;
import lombok.Data;

import java.io.Serializable;

@Builder
@Data
public class DockerContainer implements Serializable {
    String name;
    String ip;
    HostConfig hostConfig;
    ContainerConfig containerConfig;
    String tonDbVolumeName;
}
