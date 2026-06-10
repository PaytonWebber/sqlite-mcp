# Build a fully static binary, then ship it alone in a scratch image.
FROM alpine:3.21 AS build

ARG ZIG_VERSION=0.16.0
RUN apk add --no-cache curl xz \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt \
    && ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
# The tmp dirs must exist before zig can extract zip dependencies.
RUN mkdir -p .zig-cache/tmp /root/.cache/zig/tmp \
    && zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux-musl

# Sample database so the image runs (and answers introspection) with no
# arguments; mount a real database and pass its path to use your own data.
RUN ./zig-out/bin/make-fixture /sample.db

FROM scratch
COPY --from=build /src/zig-out/bin/sqlite-mcp /sqlite-mcp
COPY --from=build /sample.db /sample.db
ENTRYPOINT ["/sqlite-mcp"]
CMD ["/sample.db"]
