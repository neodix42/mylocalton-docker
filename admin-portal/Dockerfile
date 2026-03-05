ARG TON_BRANCH=latest
ARG TON_IMAGE=ghcr.io/ton-blockchain/ton
FROM ${TON_IMAGE}:${TON_BRANCH}

ENV DEBIAN_FRONTEND=noninteractive
RUN apt -y update && apt install --no-install-recommends -y openjdk-21-jdk-headless docker.io docker-compose-v2

ENV SERVER_PORT=8085

RUN mkdir -p /scripts/web

COPY admin-portal/index.html /scripts/web
COPY admin-portal/blockchain.html /scripts/web
COPY admin-portal/script.js /scripts/web
COPY admin-portal/blockchain.js /scripts/web
COPY admin-portal/style.css /scripts/web
COPY admin-portal/blockchain.css /scripts/web
COPY admin-portal-app/target/MyLocalTonAdminPortal.jar /scripts/web

WORKDIR "/scripts/web"
ENTRYPOINT ["java", "-jar", "/scripts/web/MyLocalTonAdminPortal.jar"]
