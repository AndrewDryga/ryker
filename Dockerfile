ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-28.4.1-debian-bookworm-20260610-slim

FROM ${ELIXIR_IMAGE} AS build

ENV MIX_ENV=prod

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
# mix.exs reads release-assets.txt when it loads, so it is here before mix runs.
# Dependencies do not depend on Ryker's own version: they build under a fixed
# one, so they stay cached from one release to the next. On a slow network Hex
# gave up on its registry at its default timeout and failed the build
# (2026-10-01), so it waits longer.
COPY mix.exs mix.lock release-assets.txt ./
ENV RYKER_ELIXIR_VERSION=0.0.0-dependencies \
    HEX_HTTP_TIMEOUT=120
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

# The version is named only from here on. Named before the packages and the
# dependencies, it made every release download and compile them again, and a
# deploy took sixteen minutes instead of about one (2026-10-01).
ARG RYKER_VERSION
ENV RYKER_ELIXIR_VERSION=${RYKER_VERSION}

RUN test -n "$RYKER_VERSION" \
 && mix compile --warnings-as-errors \
 && mix release ryker

# Voice messages are transcribed inside the container (Ryker.Transcription.Local):
# ffmpeg turns a recording into 16 kHz mono WAV and whisper.cpp's CLI reads it
# with its multilingual base model. Every source is pinned by checksum or commit,
# so a moved tag or a changed file fails the build instead of shipping.
#
# ffmpeg is built with only the audio demuxers and decoders a voice message or
# video needs: 3 MB, where Debian's package added 386 MB of video codecs and X11
# libraries, and far fewer parsers facing an untrusted upload. The release
# tarball is FFmpeg's signed 9.0.2 (key FCF986EA15E6E293A5644F10B4322F04D67658D8).
FROM debian:bookworm-slim AS ffmpeg

ARG FFMPEG_VERSION=9.0.2
ARG FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL --retry 3 -o /ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" \
 && echo "$FFMPEG_SHA256  /ffmpeg.tar.xz" | sha256sum -c - \
 && mkdir /src \
 && tar -xJf /ffmpeg.tar.xz -C /src --strip-components=1 \
 && cd /src \
 && ./configure --prefix=/opt/ffmpeg \
      --disable-everything --disable-autodetect --disable-doc --disable-debug \
      --disable-ffplay --disable-ffprobe --disable-network --disable-x86asm \
      --enable-static --disable-shared --enable-protocol=file \
      --enable-demuxer=aac,flac,matroska,mov,mp3,ogg,wav \
      --enable-decoder=aac,aac_latm,flac,mp3,mp3float,opus,vorbis,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8,pcm_alaw,pcm_mulaw \
      --enable-parser=aac,aac_latm,flac,mpegaudio,opus,vorbis \
      --enable-muxer=wav --enable-encoder=pcm_s16le \
      --enable-filter=abuffer,abuffersink,aformat,anull,aresample,atrim \
      --enable-swresample \
 && make -j"$(nproc)" \
 && make install

# GGML_NATIVE=OFF keeps whisper-cli portable to any CPU of the image's architecture.
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

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git openssh-client openssl libstdc++6 libncurses6 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 1000 ryker \
 && useradd --uid 1000 --gid ryker --home-dir /var/lib/ryker --create-home --shell /usr/sbin/nologin ryker

WORKDIR /opt/ryker
COPY --from=build --chown=ryker:ryker /build/_build/prod/rel/ryker ./
COPY --from=ffmpeg /opt/ffmpeg/bin/ffmpeg /usr/local/bin/ffmpeg
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

ARG RYKER_VERSION
LABEL org.opencontainers.image.title="Ryker" \
      org.opencontainers.image.version="$RYKER_VERSION" \
      org.opencontainers.image.source="https://github.com/AndrewDryga/ryker"
