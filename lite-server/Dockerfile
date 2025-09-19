ARG TON_BRANCH=latest
FROM ghcr.io/ton-blockchain/ton:${TON_BRANCH}

ENV DEBIAN_FRONTEND=noninteractive
RUN apt -y update && apt install --no-install-recommends -y python3 cron bc

RUN mkdir -p /scripts
COPY --chmod=744 lite-server/start-liteserver.sh /scripts
COPY lite-server/liteserver /scripts
COPY lite-server/liteserver.pub /scripts
COPY lite-server/control.template /scripts

RUN echo 'alias last="lite-client -p /var/ton-work/db/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -c last"' >> ~/.bashrc

ENTRYPOINT ["/scripts/start-liteserver.sh"]