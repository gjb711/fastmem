#!/bin/bash
# One-shot three-engine benchmark in Docker:
# builds the server image with FASTMEM from source, starts it, runs the
# benchmark, prints the report and cleans up.
#
#   ./docker/run-benchmark.sh [MARIADB_VERSION]     # default 12.1.2
set -euo pipefail
VERSION="${1:-12.1.2}"
IMAGE="fastmem-server:${VERSION}"
CTR="fastmem-bench-$$"

cd "$(dirname "$0")/.."

echo ">> building ${IMAGE} (downloads MariaDB ${VERSION} source + builds plugin)"
docker build -t "$IMAGE" --build-arg MARIADB_VERSION="$VERSION" -f docker/Dockerfile .

echo ">> starting server container"
docker rm -f "$CTR" >/dev/null 2>&1 || true
docker run -d --name "$CTR" -e MARIADB_ROOT_PASSWORD=bench "$IMAGE" >/dev/null

echo ">> waiting for server"
for i in $(seq 1 180); do
  docker exec "$CTR" mariadb-admin -uroot -pbench ping >/dev/null 2>&1 && break
  sleep 1
done

echo ">> running benchmark"
docker exec -e MARIADB_ROOT_PASSWORD=bench "$CTR" bash /bench/bench.sh

docker rm -f "$CTR" >/dev/null 2>&1 || true
echo ">> done"
