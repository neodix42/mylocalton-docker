ARG TON_BRANCH=latest
ARG TON_IMAGE=ghcr.io/ton-blockchain/ton
FROM ${TON_IMAGE}:${TON_BRANCH}

RUN mkdir -p /scripts
COPY --chmod=744 explorer/start.sh /scripts
ENTRYPOINT ["/scripts/start.sh"]