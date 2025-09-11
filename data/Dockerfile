FROM ghcr.io/ton-blockchain/ton:latest
ENV DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install --no-install-recommends -y openjdk-21-jdk-headless

ENV SERVER_PORT=99

RUN mkdir -p /scripts/web

COPY data/index.html /scripts/web
COPY data/script.js /scripts/web
COPY data/style.css /scripts/web
COPY --chmod=744 data/start.sh /scripts/web
COPY data-app/target/MyLocalTonDockerData.jar /scripts/web

WORKDIR "/scripts/web"
ENTRYPOINT ["./start.sh"]
