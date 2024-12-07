# FROM ghcr.io/ton-blockchain/ton:latest
FROM ghcr.io/neodix42/ton:testnet
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y python3

RUN mkdir -p /scripts \
    /var/ton-work/db/static \
    /var/ton-work/db/keyring \
    /var/ton-work/db/import

COPY docker/scripts/create-genesis.sh /scripts/create-genesis.sh
COPY docker/scripts/start-node.sh /scripts/start-node.sh
COPY docker/scripts/gen-zerostate.fif /usr/share/ton/smartcont/gen-zerostate.fif
COPY docker/scripts/ton-private-testnet.config.json.template /var/ton-work/db
COPY docker/scripts/example.config.json /var/ton-work/db
COPY docker/scripts/control.template /var/ton-work/db

ENTRYPOINT ["/scripts/start-node.sh"]