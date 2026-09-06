# Training Tracker, prod image (issue #17): one container with the ReleaseSafe
# Zig API on localhost:8080 and the Bun server on the only exposed port, 3000,
# proxying /api/* to it. The JSON store lives on the /data volume.
#
#   docker build -t training-tracker .
#   docker run -p 3000:3000 -v "$(pwd)/data:/data" training-tracker
#
# Versions come from mise.toml; pass --build-arg to override.
ARG BUN_VERSION=1.3.14
ARG ZIG_VERSION=0.16.0

# ---- API: Zig cross-compiles, so the build stage always runs natively on the
# build host and targets the image platform (musl, static). No emulation.
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS api-build
ARG ZIG_VERSION
ARG BUILDARCH
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*
RUN case "$BUILDARCH" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; *) echo "unsupported build arch $BUILDARCH" >&2; exit 1 ;; esac \
 && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt \
 && ln -s "/opt/zig-${arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
WORKDIR /src/api
COPY api/build.zig api/build.zig.zon api/openapi.yaml ./
COPY api/src ./src
RUN case "$TARGETARCH" in amd64) target=x86_64-linux-musl ;; arm64) target=aarch64-linux-musl ;; *) echo "unsupported target arch $TARGETARCH" >&2; exit 1 ;; esac \
 && zig build -Dtarget="$target" -Doptimize=ReleaseSafe --prefix /out

# ---- Runtime: Bun serves the app and proxies to the API next to it.
FROM oven/bun:${BUN_VERSION}-slim
ENV NODE_ENV=production \
    DATA_PATH=/data/data.json \
    PORT=3000
WORKDIR /app
COPY web/package.json web/bun.lock ./web/
# --omit=peer: bun-plugin-tailwind peer-depends on the `bun` npm package, 172 MB
# of runtime binaries this image already has; the plugin imports the built-in.
RUN cd web && bun install --frozen-lockfile --production --omit=peer
COPY web/server.ts web/index.html web/bunfig.toml web/tsconfig.json ./web/
COPY web/src ./web/src
COPY api/data.seed.json ./api/data.seed.json
COPY --from=api-build /out/bin/training-tracker /usr/local/bin/training-tracker
COPY scripts/container-entrypoint.sh /usr/local/bin/training-tracker-entrypoint
VOLUME ["/data"]
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s \
  CMD bun -e 'fetch("http://127.0.0.1:3000/api/health").then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))'
ENTRYPOINT ["training-tracker-entrypoint"]
