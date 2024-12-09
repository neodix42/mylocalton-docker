# FROM ghcr.io/ton-blockchain/ton:latest
FROM ghcr.io/neodix42/ton:testnet
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y python3
#    openjdk-21-jdk-headless

RUN mkdir -p /scripts \
    /var/ton-work/db/static \
    /var/ton-work/db/keyring \
    /var/ton-work/db/import \
    /var/ton-work/logs

COPY docker/scripts/start-genesis.sh /scripts/start-genesis.sh
COPY docker/scripts/start-validator.sh /scripts/start-validator.sh
COPY docker/scripts/start-node.sh /scripts/start-node.sh
COPY docker/scripts/gen-zerostate.fif /usr/share/ton/smartcont/gen-zerostate.fif
COPY docker/scripts/ton-private-testnet.config.json.template /var/ton-work/db
COPY docker/scripts/example.config.json /var/ton-work/db
COPY docker/scripts/control.template /var/ton-work/db

RUN echo 'alias getstats="validator-engine-console -k /var/ton-work/db/client -p /var/ton-work/db/server.pub -a 127.0.0.1:$(jq .control[].port <<< cat /var/ton-work/db/config.json)"' >> ~/.bashrc
RUN echo 'alias last="lite-client -p /var/ton-work/db/liteserver.pub -a 127.0.0.1:$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -c last"' >> ~/.bashrc

ENTRYPOINT ["/scripts/start-node.sh"]