# example of setting up the env and launching deployment of MyLocalTon-Docker in docker swarm cluster.
export DOCKER_IGNORE_BR_NETFILTER_ERROR=1
export GENESIS_NODE_NAME=manager
export VALIDATOR1_NODE_NAME=worker-1
export EXPLORER_NODE_NAME=worker-2
export FAUCET_NODE_NAME=worker-3
export LITESERVER_NODE_NAME=worker-4
export DATA_NODE_NAME=worker-5
export VALIDATOR2_NODE_NAME=worker-6
export VALIDATOR3_NODE_NAME=worker-7
export VALIDATOR4_NODE_NAME=worker-8
export VALIDATOR5_NODE_NAME=worker-9

docker stack deploy -c stack.yaml ton
