FROM ghcr.io/ton-blockchain/ton:latest

ARG SERVER_PORT=8080
ENV SERVER_PORT_VAR=$SERVER_PORT
RUN mkdir -p /scripts
COPY --chmod=744 explorer/start.sh /scripts
ENTRYPOINT ["/scripts/start.sh"]