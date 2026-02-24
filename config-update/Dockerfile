ARG TON_BRANCH=latest
ARG TON_IMAGE=ghcr.io/ton-blockchain/ton
FROM ${TON_IMAGE}:${TON_BRANCH}

ENV DEBIAN_FRONTEND=noninteractive
RUN apt -y update && apt install --no-install-recommends -y openjdk-21-jdk-headless

ENV SERVER_PORT=8084

RUN mkdir -p /scripts/web

COPY config-update/index.html /scripts/web
COPY config-update/script.js /scripts/web
COPY config-update/style.css /scripts/web
COPY --chmod=744 config-update/start.sh /scripts/web
COPY config-update-app/target/MyLocalTonConfigUpdate.jar /scripts/web

WORKDIR "/scripts/web"
ENTRYPOINT ["./start.sh"]
