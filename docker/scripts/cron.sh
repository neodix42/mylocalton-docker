#!/bin/bash

# Load environment variables from file
set -a
source /etc/container_env
set +a

echo "cron. Using NAME = $NAME"

/scripts/participate.sh
sleep 45
/scripts/reap.sh
