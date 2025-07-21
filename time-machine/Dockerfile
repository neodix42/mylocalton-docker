FROM ghcr.io/ton-blockchain/ton:latest
ENV DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install --no-install-recommends -y openjdk-21-jdk-headless

ENV SERVER_PORT=8083

RUN mkdir -p /scripts/web

COPY time-machine/index.html /scripts/web
COPY time-machine/script.js /scripts/web
COPY time-machine/style.css /scripts/web
COPY time-machine-app/target/MyLocalTonTimeMachine.jar /scripts/web

WORKDIR "/scripts/web"
ENTRYPOINT ["java", "-jar", "/scripts/web/MyLocalTonTimeMachine.jar"]
