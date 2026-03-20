FROM debian:bookworm-slim

ARG WHISPER_CPP_REF=
ARG GGML_CPU_ARM_ARCH=armv8.2-a+fp16

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    build-essential \
    cmake \
    pkg-config \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

RUN if [ -n "${WHISPER_CPP_REF}" ]; then \
      git clone https://github.com/ggml-org/whisper.cpp.git /opt/whisper.cpp && \
      cd /opt/whisper.cpp && \
      git checkout "${WHISPER_CPP_REF}"; \
    else \
      git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git /opt/whisper.cpp; \
    fi

WORKDIR /opt/whisper.cpp

RUN cmake -B build \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_BUILD_SERVER=ON \
    -DWHISPER_FFMPEG=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_CPU_ARM_ARCH="${GGML_CPU_ARM_ARCH}" \
 && cmake --build build -j"$(nproc)" --config Release

ENV PATH="/opt/whisper.cpp/build/bin:${PATH}"

CMD ["/bin/sh"]
