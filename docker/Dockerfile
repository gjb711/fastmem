# Multi-stage image: build the FASTMEM plugin against the official MariaDB
# source tarball, then run it inside the matching mariadb:<ver> image.
# The plugin is compiled from the exact server version it will be loaded
# into, so no prebuilt binaries and no ABI guesswork.
#
#   docker build -t fastmem-server --build-arg MARIADB_VERSION=12.1.2 \
#                -f docker/Dockerfile .
#
# Use docker/run-benchmark.sh for the complete three-engine benchmark.

ARG MARIADB_VERSION=12.1.2

# ---------- stage 1: build ha_fastmem.so ---------------------------------
FROM ubuntu:24.04 AS builder
ARG MARIADB_VERSION
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential cmake bison libssl-dev libncurses-dev libpcre2-dev \
      pkg-config libxml2-dev libcurl4-openssl-dev libkrb5-dev zlib1g-dev \
      curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY . /fastmem
WORKDIR /work
RUN curl -fsSL --retry 6 --connect-timeout 30 -o src.tar.gz \
      "https://archive.mariadb.org/mariadb-${MARIADB_VERSION}/source/mariadb-${MARIADB_VERSION}.tar.gz" \
 && mkdir -p src && tar -xzf src.tar.gz -C src --strip-components=1 \
 && if [ ! -f src/libmariadb/CMakeLists.txt ]; then \
      echo "source tarball lacks submodules - fetching MariaDB Connector/C"; \
      curl -fsSL --retry 6 -o conn.tar.gz \
        "https://codeload.github.com/MariaDB/mariadb-connector-c/tar.gz/refs/heads/3.4"; \
      mkdir -p conn && tar -xzf conn.tar.gz -C conn --strip-components=1; \
      rm -rf src/libmariadb && cp -r conn src/libmariadb; \
    fi \
 && /fastmem/install.sh --source-dir /work/src --jobs "$(nproc)" \
 && cp src/build_fastmem/storage/fastmem/ha_fastmem.so /work/ha_fastmem.so

# ---------- stage 2: server image with the plugin ------------------------
FROM mariadb:${MARIADB_VERSION}
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      mariadb-client procps bc \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /work/ha_fastmem.so /usr/lib/mysql/plugin/ha_fastmem.so
COPY docker/bench.sql docker/bench.sh /bench/
# Auto-load the engine at startup. MariaDB >= 12.x defaults to
# plugin-maturity=gamma and refuses BETA-maturity plugins; FASTMEM
# honestly declares BETA, so the maturity gate is relaxed here too.
RUN printf '[mariadbd]\nplugin-load-add=ha_fastmem.so\nplugin-maturity=beta\n' \
    > /etc/mysql/mariadb.conf.d/99-fastmem.cnf
EXPOSE 3306
CMD ["mariadbd"]
