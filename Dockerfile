# ---- Dependency planner ----
FROM rust:1-bookworm AS chef-planner

RUN cargo install cargo-chef --locked
WORKDIR /usr/src/readyset
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ---- Builder stage ----
FROM rust:1-bookworm AS builder

ARG TARGETARCH
ENV TARGETARCH=${TARGETARCH:-amd64}

RUN set -eux; \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential llvm clang libclang-dev lld cmake \
        libssl-dev liblz4-dev protobuf-compiler && \
    rm -rf /var/lib/apt/lists/*

# Pin Rust version from rust-toolchain.toml (same pattern as build/Dockerfile)
COPY rust-toolchain.toml /tmp/
RUN rustup default "$(grep channel /tmp/rust-toolchain.toml | sed -e 's/.*"\(.*\)"/\1/')"; \
    rm /tmp/rust-toolchain.toml

RUN cargo install cargo-chef --locked

# Set rustflags via CARGO_HOME config (pattern from build/Dockerfile:75-82)
# Combines lld linker + lz4 + frame pointers + graviton (arm64)
RUN set -eux; \
    linker_flag='"-C", "link-arg=-fuse-ld=lld"' \
    && lz4_flag='"-C", "link-args=-llz4"' \
    && fp_flag='"-C", "force-frame-pointers=yes"' \
    && graviton_flag='"-C", "target-feature=+lse"' \
    && if [ "${TARGETARCH}" = "arm64" ]; then \
         rustflags="${linker_flag}, ${lz4_flag}, ${fp_flag}, ${graviton_flag}"; \
       else \
         rustflags="${linker_flag}, ${lz4_flag}, ${fp_flag}"; \
       fi \
    && printf '[build]\nrustflags = [%s]\n' "${rustflags}" > ${CARGO_HOME}/config.toml

WORKDIR /usr/src/readyset

# Build dependencies (cached until Cargo.toml/Cargo.lock change)
COPY --from=chef-planner /usr/src/readyset/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json

# Build the real binary
COPY . .
RUN cargo build --locked --release --bin readyset && \
    cp target/release/readyset /usr/local/bin/readyset

# ---- Runtime stage ----
FROM debian:bookworm-slim

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates liblz4-1 libssl3 \
        postgresql-client curl && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -r readyset && useradd -r -g readyset -u 10001 readyset

COPY --from=builder /usr/local/bin/readyset /usr/local/bin/readyset

RUN mkdir -p /state && chown readyset:readyset /state
VOLUME /state
WORKDIR /state

USER readyset

ENV LISTEN_ADDRESS=0.0.0.0:5433
ENV METRICS_ADDRESS=0.0.0.0:6034
ENV PROMETHEUS_METRICS=true
ENV DEPLOYMENT=readyset
ENV STORAGE_DIR=/state
ENV QUERY_CACHING=explicit

EXPOSE 5433 6034

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:6034/health || exit 1

ENTRYPOINT ["readyset"]
