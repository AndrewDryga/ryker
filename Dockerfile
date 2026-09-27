ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-28.4.1-debian-bookworm-20260610-slim

FROM ${ELIXIR_IMAGE} AS build

ARG RYKER_VERSION
ENV MIX_ENV=prod \
    RYKER_ELIXIR_VERSION=${RYKER_VERSION}

RUN test -n "$RYKER_VERSION" \
 && apt-get update \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
# mix.exs reads release-assets.txt when it loads, so it is here before mix runs.
COPY mix.exs mix.lock release-assets.txt ./
RUN mix local.hex --force \
 && mix local.rebar --force \
 && mix deps.get --only prod \
 && mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY README.md CHANGELOG.md LICENSE SECURITY.md ./
COPY Dockerfile compose.yml install.sh ./
COPY deploy/compose deploy/compose
COPY deploy/nginx deploy/nginx
COPY docs docs
COPY scripts scripts

RUN mix compile --warnings-as-errors \
 && mix release ryker

# Voice messages are transcribed inside the container: whisper.cpp's CLI and
# its multilingual base model (Ryker.Transcription.Local). The release tag is
# checked against its commit and the model against its checksum, so a moved
# tag or a changed file fails the build instead of shipping. GGML_NATIVE=OFF
# keeps the binary portable to any CPU of the image's architecture.
FROM debian:bookworm-slim AS whisper

ARG WHISPER_CPP_VERSION=v1.9.4
ARG WHISPER_CPP_COMMIT=927cfce34f31707e17f2bff35c349632fb9e2c3a
ARG WHISPER_MODEL_URL=https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin
ARG WHISPER_MODEL_SHA256=60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential cmake git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "$WHISPER_CPP_VERSION" https://github.com/ggml-org/whisper.cpp /src \
 && test "$(git -C /src rev-parse HEAD)" = "$WHISPER_CPP_COMMIT" \
 && cmake -S /src -B /src/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
 && cmake --build /src/build --config Release --target whisper-cli -j "$(nproc)" \
 && install -D -m 0755 /src/build/bin/whisper-cli /opt/whisper/bin/whisper-cli

RUN curl -fsSL --retry 3 -o /opt/whisper/ggml-base.bin "$WHISPER_MODEL_URL" \
 && echo "$WHISPER_MODEL_SHA256  /opt/whisper/ggml-base.bin" | sha256sum -c -

FROM debian:bookworm-slim AS runtime

ARG RYKER_VERSION
LABEL org.opencontainers.image.title="Ryker" \
      org.opencontainers.image.version="$RYKER_VERSION" \
      org.opencontainers.image.source="https://github.com/AndrewDryga/ryker"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl ffmpeg git openssh-client openssl libstdc++6 libncurses6 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 1000 ryker \
 && useradd --uid 1000 --gid ryker --home-dir /var/lib/ryker --create-home --shell /usr/sbin/nologin ryker

WORKDIR /opt/ryker
COPY --from=build --chown=ryker:ryker /build/_build/prod/rel/ryker ./
COPY --from=whisper /opt/whisper /opt/whisper
COPY --chown=ryker:ryker deploy/compose/entrypoint.sh /usr/local/bin/ryker-entrypoint

RUN chmod 0755 /usr/local/bin/ryker-entrypoint \
 && mkdir -p /var/lib/ryker \
 && chown ryker:ryker /var/lib/ryker

USER ryker
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/var/lib/ryker \
    RELEASE_DISTRIBUTION=none \
    RYKER_CONTAINER=true \
    RYKER_STATE_DIR=/var/lib/ryker

EXPOSE 4321 4319 4320 4322
ENTRYPOINT ["/usr/local/bin/ryker-entrypoint"]
CMD ["start"]
