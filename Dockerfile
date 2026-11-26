# Opsily deploy of the MinerU 4.x API server for OpenWebUI (CPU only).
# The official docker/global/Dockerfile is a ~10 GB GPU/vLLM image, so this builds a slim CPU image instead:
# base "mineru" package (ONNX Runtime) + the "basic" tier models baked in at build time.
FROM python:3.12-slim

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    MINERU_MODEL_SMALL_BACKEND=onnx \
    MINERU_MODEL_ONNX_DEVICE=cpu \
    MINERU_TELEMETRY_DISABLED=1 \
    MINERU_HOME=/opt/mineru

RUN apt-get update \
 && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 curl \
 && rm -rf /var/lib/apt/lists/*

# Pinned: 4.0 and 4.1 both changed the HTTP API.
RUN pip install "mineru==4.2.3"

# Bake the basic-tier ONNX models (~860 MB) into the image so the first upload doesn't download them.
# MINERU_HOME is outside /root because Opsily may run the container as a non-root user.
RUN mineru-kit models download --tier basic --small-backend onnx --source huggingface \
 && mineru-kit models verify --tier basic --small-backend onnx \
 && chmod -R a+rwX /opt/mineru

# Runtime: never download; trust Opsily's proxy headers so upload/result URLs come back as https://;
# keep uploads/results 1 hour instead of 24 h (ephemeral disk).
ENV MINERU_MODEL_SOURCE=local \
    FORWARDED_ALLOW_IPS=* \
    MINERU_API_RETENTION_SECONDS=3600

# Conservative memory settings (36 pages at once got the container OOM-killed):
# - 4 pages per processing window instead of 64
# - 2 CPU threads for ONNX/OpenMP (fewer threads = fewer per-thread buffers; the box has ~2 cores)
# - limit glibc malloc arenas and trim the heap after jobs so freed memory goes back to the OS
ENV MINERU_PROCESSING_WINDOW_SIZE=4 \
    MINERU_INTRA_OP_NUM_THREADS=2 \
    MINERU_INTER_OP_NUM_THREADS=1 \
    MINERU_CPU_NUM_THREADS=2 \
    OMP_NUM_THREADS=2 \
    MKL_NUM_THREADS=2 \
    MALLOC_ARENA_MAX=2 \
    MINERU_MALLOC_TRIM=1

# 4.2.3 bug: --upload-dir defaults to "" and click rejects it as "not writable", so pass a real directory.
RUN mkdir -p /tmp/mineru-uploads && chmod 1777 /tmp/mineru-uploads

EXPOSE 8000

# One document at a time, give up after 20 min per file, no image analysis.
# Opsily chooses the port and passes it in $PORT. MINERU_API_KEY (set as a secret in the Opsily dashboard)
# becomes the required Bearer token; without it the API is open.
CMD ["sh", "-c", "echo \"Running as $(id); listening on port ${PORT:-8000}\"; [ -w \"$HOME\" ] || export HOME=/tmp; UP=/tmp/mineru-uploads; [ -w \"$UP\" ] || UP=$(mktemp -d); echo \"Upload dir: $UP\"; [ -n \"$MINERU_API_KEY\" ] && echo 'API key enabled' || echo 'WARNING: no MINERU_API_KEY, API is open'; exec mineru-kit api-server --host 0.0.0.0 --port \"${PORT:-8000}\" --upload-dir \"$UP\" --tier basic --concurrency 1 --task-timeout 1200 --disable-image-analysis --preload-models ${MINERU_API_KEY:+--api-key \"$MINERU_API_KEY\"}"]
