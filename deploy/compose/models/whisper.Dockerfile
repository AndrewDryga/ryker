# whisper.cpp's server for voice messages, on the CPU, with its model in the image. Compose runs
# two from this file: `whisper` writes the words with large-v3-turbo, and `whisper-detect` only
# detects each part's language with a small model (`-dl`), which is far cheaper
# (`Ryker.Transcription.Service`).
#
# Docker on a Mac cannot reach the GPU, so the build targets the CPU's own features: dot product
# and half precision on arm64, AVX2, FMA and F16C on amd64. On an M3 Pro that made large-v3-turbo
# about twice as fast as a generic build: 29 s instead of 54 s for 31 s of speech (2026-10-12).
# GGML_NATIVE and GGML_CPU_ALL_VARIANTS both fail with bookworm's GCC 12. An older CPU cannot run
# these servers, and Ryker's own model, built for any CPU, reads voice messages there.
FROM debian:bookworm-20261005-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587 AS build

ARG WHISPER_CPP_VERSION=v1.9.4
ARG WHISPER_CPP_COMMIT=927cfce34f31707e17f2bff35c349632fb9e2c3a
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential cmake git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "$WHISPER_CPP_VERSION" https://github.com/ggml-org/whisper.cpp /src \
 && test "$(git -C /src rev-parse HEAD)" = "$WHISPER_CPP_COMMIT" \
 && case "$TARGETARCH" in \
      arm64) cpu="-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16" ;; \
      amd64) cpu="-DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON" ;; \
      *) cpu="" ;; \
    esac \
 && cmake -S /src -B /src/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DGGML_NATIVE=OFF $cpu -DGGML_OPENMP=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=ON \
 && cmake --build /src/build --config Release --target whisper-server -j "$(nproc)" \
 && install -D -m 0755 /src/build/bin/whisper-server /opt/whisper/bin/whisper-server

# The model is pinned by revision and digest: a moved branch or a replaced file fails the build.
ARG MODEL_URL
ARG MODEL_SHA256
RUN test -n "$MODEL_URL" && test -n "$MODEL_SHA256" \
 && curl -fsSL --retry 3 -o /opt/whisper/model.bin "$MODEL_URL" \
 && echo "$MODEL_SHA256  /opt/whisper/model.bin" | sha256sum -c -

FROM debian:bookworm-20261005-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libstdc++6 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 1000 --home-dir /opt/whisper --no-create-home --shell /usr/sbin/nologin whisper

COPY --from=build /opt/whisper /opt/whisper
USER whisper
EXPOSE 8080
# whisper.cpp uses four threads unless told. Up to eight answer fastest; on an M3 Pro's twelve,
# beside the rest of Ryker, detecting a part's language took 9 s instead of 3 (2026-10-13).
ENTRYPOINT ["/bin/sh", "-c", "threads=$(nproc); [ \"$threads\" -gt 8 ] && threads=8; exec /opt/whisper/bin/whisper-server -m /opt/whisper/model.bin --host 0.0.0.0 --port 8080 -t \"$threads\" \"$@\"", "whisper-server"]
