FROM ghcr.io/ton-blockchain/ton:latest

ARG SERVER_PORT=8080
ENV SERVER_PORT_VAR=$SERVER_PORT
ENTRYPOINT blockchain-explorer -C /usr/share/data/global.config.json -H $SERVER_PORT_VAR