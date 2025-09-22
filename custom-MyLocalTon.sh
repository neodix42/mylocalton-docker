#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 1 ]]; then
    # Case 1: local path
    target_dir="$1"

    if [[ -d "$target_dir" ]]; then
        echo "Using existing path: $target_dir"
        cd "$target_dir"
        branch=$(git branch --show-current)
    else
        echo "Error: directory '$target_dir' does not exist."
        exit 1
    fi

elif [[ $# -eq 2 ]]; then
    # Case 2: branch and URL
    branch="$1"
    repo_url="$2"

    # Extract directory name from URL (strip .git if present)
    repo_dir=$(basename "$repo_url" .git)

    if [[ -d "$repo_dir" ]]; then
        echo "Directory '$repo_dir' already exists. Entering..."
        cd "$repo_dir"
        git checkout $branch
    else
        echo "Cloning $repo_url (branch: $branch) into $repo_dir ..."
        git clone --recursive --branch "$branch" --single-branch "$repo_url" "$repo_dir"
        cd "$repo_dir"
    fi

else
    echo "Usage:"
    echo "  $0 <local-path>"
    echo "  $0 <branch> <git-url>"
    exit 1
fi

echo $(pwd)
echo "Building Docker image custom-ton:$branch"
echo
docker build -t ton-custom:$branch .

cd ..

echo
echo "Compiling Java projects [Faucet, Data Generator, Time Machine]"
echo
mvn clean install

echo
echo "Build MyLocalTon Docker based on custom TON image"
echo

docker build --build-arg TON_IMAGE=ton-custom --build-arg TON_BRANCH=$branch -t mylocalton-custom-docker-data:$branch -f data/Dockerfile .
docker build --build-arg TON_IMAGE=ton-custom --build-arg TON_BRANCH=$branch -t mylocalton-custom-docker-explorer:$branch -f explorer/Dockerfile .
docker build --build-arg TON_IMAGE=ton-custom --build-arg TON_BRANCH=$branch -t mylocalton-custom-docker-faucet:$branch -f faucet/Dockerfile .
docker build --build-arg TON_IMAGE=ton-custom --build-arg TON_BRANCH=$branch -t mylocalton-custom-docker-time-machine:$branch -f time-machine/Dockerfile .
docker build --build-arg TON_IMAGE=ton-custom --build-arg TON_BRANCH=$branch -t mylocalton-custom-docker-lite-server:$branch -f lite-server/Dockerfile .
docker build --build-arg TON_IMAGE=ton-custom --build-arg TON_BRANCH=$branch -t mylocalton-custom-docker:$branch -f Dockerfile .

sed -i -E "s|^TON_BRANCH=.*$|TON_BRANCH=$branch|" .env
sed -i -E "s|^TON_IMAGE=.*$|TON_IMAGE=custom-ton|" .env
sed -i -E "s|^MLT_IMAGE=.*$|MLT_IMAGE=mylocalton-custom-docker|" .env
sed -i -E "s|^MLT_DATA_IMAGE=.*$|MLT_DATA_IMAGE=mylocalton-custom-docker-data|" .env
sed -i -E "s|^MLT_FAUCET_IMAGE=.*$|MLT_FAUCET_IMAGE=mylocalton-custom-docker-faucet|" .env
sed -i -E "s|^MLT_EXPLORER_IMAGE=.*$|MLT_EXPLORER_IMAGE=mylocalton-custom-docker-explorer|" .env
sed -i -E "s|^MLT_LITE_SERVER_IMAGE=.*$|MLT_LITE_SERVER_IMAGE=mylocalton-custom-docker-lite-server|" .env
sed -i -E "s|^MLT_TIME_MACHINE_IMAGE=.*$|MLT_TIME_MACHINE_IMAGE=mylocalton-custom-docker-time-machine|" .env

docker compose up


