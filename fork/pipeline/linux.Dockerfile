# Build image for the Linux x64 server/CLI archive. It mirrors upstream's ubuntu-24.04 release
# runner so nothing has to be installed on the host: the exact engines.node (the single-executable
# build refuses any other), stable Rust for the resource monitor, and patchelf for the archive.
FROM ubuntu:24.04

ARG NODE_VERSION
ARG VP_VERSION
# From 1.8.0 the vite-plus npm package no longer downloads pnpm: `vp install` runs the pnpm on
# PATH (its docs/guide/ci.md). So the image carries the pnpm that package.json pins.
ARG PNPM_VERSION

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git xz-utils build-essential pkg-config patchelf libatomic1 python3 \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    name="node-v${NODE_VERSION}-linux-x64"; \
    cd /tmp; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${name}.tar.xz"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"; \
    grep " ${name}.tar.xz\$" SHASUMS256.txt | sha256sum -c -; \
    tar -xJf "${name}.tar.xz" -C /usr/local --strip-components=1; \
    rm -f "${name}.tar.xz" SHASUMS256.txt; \
    node --version

ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain stable --target x86_64-unknown-linux-gnu \
 && cargo --version

# An empty version would install npm's "latest", so a caller that passes none stops the build.
RUN : "${VP_VERSION:?}" "${PNPM_VERSION:?}" \
 && npm install --global "vite-plus@${VP_VERSION}" "pnpm@${PNPM_VERSION}" \
 && vp --version && pnpm --version
