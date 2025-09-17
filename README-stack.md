# TON Docker Stack Deployment Guide

This guide explains how to deploy the TON blockchain services using Docker Swarm with the provided `stack.yaml` file.

## Prerequisites

- Docker engine 28.0.1 and above
- Docker Swarm cluster initialized and internode communication is possible
- Nodes labeled appropriately for service placement

## Deployment

### Specify location of services

```bash
export DOCKER_IGNORE_BR_NETFILTER_ERROR=1

# Set node names for core services
export GENESIS_NODE_NAME=manager

# Set node names for validators
export VALIDATOR1_NODE_NAME=worker-node-1
export VALIDATOR2_NODE_NAME=worker-node-2
export VALIDATOR3_NODE_NAME=worker-node-3
export VALIDATOR4_NODE_NAME=worker-node-4
export VALIDATOR5_NODE_NAME=worker-node-5

# Set node name for native TON blockchain explorer
export EXPLORER_NODE_NAME=worker-node-7

export FAUCET_NODE_NAME=worker-node-8
export DATA_NODE_NAME=worker-node-9

# Set node name for the secondary standalone lite-server  
export LITESERVER_NODE_NAME=worker-node-10
```

### To deploy the stack, use the following command:

```
docker stack deploy -c stack.yaml ton
```

Where `ton` is the name of your stack. You can choose any name you prefer.

## Service Groups

### Core Services

- **genesis**: The main TON blockchain node that generates the initial blockchain state
- **blockchain-explorer**: Web interface to explore the blockchain
- **liteserver**: Standalone lite-server used
- **faucet**: Service to distribute test TON coins
- **data**: Data service for the TON blockchain
- **restarter**: Utility service to periodically restart the blockchain explorer

### Validator Services

- **validator-1** to **validator-5**: Validator nodes that participate in block validation

### Indexer Services (Always Deployed Together)

These services are always deployed together on the node specified by `GENESIS_NODE_NAME`:

- **tonhttpapi**: HTTP API for TON blockchain
- **index-worker**: Worker for indexing blockchain data
- **index-api**: API for accessing indexed data
- **event-classifier**: Service for classifying blockchain events
- **index-postgres**: PostgreSQL database for storing indexed data
- **event-cache**: Redis cache for event data

## Volume Configuration

The stack uses several Docker volumes:

- **shared-data**: Shared data between services on the same node, used only for genesis+indexer
- **postgres-data**: PostgreSQL data
- **index-workdir**: Working directory for the index worker
- **ton-db**: TON blockchain database

## Network Configuration

The stack creates an overlay network with subnet 172.28.0.0/16.

Since you deploy in a public network and want to access your lite-server and
other services from outside you have to specify EXTERNAL_IP for genesis service and
use its value in other services.

## Customizing the Deployment

You can customize the deployment by modifying the stack.yaml file or by setting environment variables. For example:

```bash
# Deploy with custom node placement
stack deploy -c stack.yaml ton
```

## Testing the Deployment

After deployment, you can access the following services:

- Blockchain Explorer: http://<node-ip>:8080
- Faucet: http://<node-ip>:88
- Data generator: http://<node-ip>:99
- TON HTTP API V2: http://<node-ip>:8081
- TON HTTP API V3: http://<node-ip>:8082
- Lite-server: lite-client -a <node-ip>:30004 -b Wha42OjSNvDaHOjhZhUZu0zW/+wu/+PaltND/a0FbuI= -c last

## Troubleshooting

If services fail to start, check the logs:

```bash
docker service logs ton_genesis --no-trunc --tail all
docker service logs ton_blockchain-explorer --no-trunc --tail all
docker service logs ton_lite-server --no-trunc --tail all
docker service logs ton_faucet --no-trunc --tail all
docker service logs ton_validator-1 --no-trunc --tail all
docker service logs ton_index-worker --no-trunc --tail all

docker service ps ton_genesis --no-trunc
docker service ps ton_blockchain-explorer --no-trunc
docker service ps ton_validator-1 --no-trunc
docker service ps ton_index-worker --no-trunc
docker service ps ton_faucet --no-trunc
docker service ps ton_restarter --no-trunc
docker service ps ton_lite-server --no-trunc 
```

Some more helpful commands:

```
docker node ls
docker stack services ton

# node to leave swarm
docker swarm leave
docker node rm <id>
```

## Uninstall

```
docker stack rm ton
docker volume rm ton_index-workdir ton_postgres-data ton_shared-data ton_ton-db
# docker system prune -a -f
```