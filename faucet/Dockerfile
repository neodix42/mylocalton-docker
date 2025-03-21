FROM ghcr.io/ton-blockchain/ton:latest
ENV DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install --no-install-recommends -y openjdk-19-jdk-headless

ENV SERVER_PORT=80
ENV FAUCET_REQUEST_EXPIRATION_PERIOD=86400
ENV FAUCET_SINGLE_GIVEAWAY=10

RUN mkdir -p /scripts/web

COPY faucet/index.html /scripts/web
COPY faucet/script.js /scripts/web
COPY faucet/index-no-recaptcha.html /scripts/web
COPY faucet/script-no-recaptcha.js /scripts/web
COPY faucet/style.css /scripts/web
COPY --chmod=744 faucet/start.sh /scripts/web
COPY faucet-app/target/MyLocalTonDockerWebFaucet.jar /scripts/web

WORKDIR "/scripts/web"
ENTRYPOINT ["./start.sh"]
