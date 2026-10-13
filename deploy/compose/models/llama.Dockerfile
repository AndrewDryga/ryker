# llama.cpp's server with one model in the image: `embeddings` (bge-m3) for routing's search by
# meaning and, behind the `routing-model` profile, `routing-model` (Qwen2.5 3B) for the local
# routing comparison. The server image is llama.cpp's own, pinned by digest (2026-10-13).
FROM ghcr.io/ggml-org/llama.cpp:server@sha256:052888c603894ecfa08deb6714fdc2d7084e491e174d5ab41bfb36b49ee7151c

# The model is pinned by revision and digest: a moved branch or a replaced file fails the build.
# The server does not run as root, and a downloaded file is only its owner's to read unless the
# mode says otherwise; a directory ADD makes takes the file's mode, which cannot be entered.
ARG MODEL_URL
ARG MODEL_SHA256
ARG MODEL_FILE
RUN mkdir -m 0755 /models
ADD --chmod=0644 --checksum=sha256:${MODEL_SHA256} ${MODEL_URL} /models/${MODEL_FILE}
