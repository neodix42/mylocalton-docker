# MyLocalTon Docker image
Allows quickly to set up own TON network with up to 6 validators.

## Prerequisites

Installed Docker or Docker desktop

## Usage

### Build and start:

Clone this repo and execute:

```docker-compose -f docker-compose-build.yaml up```

### Download and start:

```docker-compose -f docker-compose.yaml up```

**Blockchain explorer** will be available on localhost via:

http://127.0.0.1:8080/last

**Simple HTTP server** on genesis node will be available on: 

http://127.0.0.1:8000

Global network configuration file available at:

http://127.0.0.1:8000/global.config.json

### Go inside the container:

```
docker exec -it genesis bash
docker exec -it validator-1 bash
docker exec -it validator-2 bash

# each container has some predefined aliases:
>last
>getstats
```

### Stop all containers:

```docker-compose -f docker-compose-build.yaml stop```

the state will be persisted, and the next time when you start the container the blockchain will be resumed from the last state.

### Reset network and remove all data:

```docker-compose -f docker-compose-build.yaml down -v --rmi all```


## Features

* has predefined faucet address
  * address ```-1:7777777777777777777777777777777777777777777777777777777777777777```
  * private key ```249489b5c1bfa6f62451be3714679581ee04cc8f82a8e3f74b432a58f3e4fedf```
* has predefined lite-server keys
  * ```lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -c last```
* additional full-nodes become validators and participate in elections automatically
  * validation cycle
* cross-platform (arm64/amd64)