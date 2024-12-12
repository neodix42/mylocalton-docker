# MyLocalTon Docker image
Allows quickly to set up own TON network with up to 6 validators.

## Prerequisites

Installed Docker Engine or Docker desktop and docker-compose.

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

* Validation
  * automatic participation in elections and reaping of rewards  
  * specify from 1 to 6 validators on start
  * validation cycle lasts 20 minutes
  * elections lasts 10 minutes (starts 5 minutes after validation cycle starts and finishes 5 minutes before validation cycles ends)
  * stake freeze period 3 minutes
* Predefined Faucet Wallets
  * Wallet V3R2
    * address ```-1:7777777777777777777777777777777777777777777777777777777777777777```
    * private key ```249489b5c1bfa6f62451be3714679581ee04cc8f82a8e3f74b432a58f3e4fedf```
    * subWallet Id 42
  * Highload Wallet V3
    * address ```-1:8888888888888888888888888888888888888888888888888888888888888888```
    * private key ```ee26cd8f2709404b63bc172148ec6179bfc7049b1045a22c3ea5446c5d425347```    
* Predefined lite-server
  * ```lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -c last```
* cross-platform (arm64/amd64)
* tested on Ubuntu, Windows and MacOS