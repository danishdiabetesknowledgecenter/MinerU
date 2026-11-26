# Opsily deploy of the MinerU 4.x API server for OpenWebUI (CPU only).
# The official docker/global/Dockerfile is a ~10 GB GPU/vLLM image, so this builds a slim CPU image instead:
# base "mineru" package (ONNX Runtime) + the "basic" tier models baked in at build time.
FROM python:3.12-slim

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    MINERU_MODEL_SMALL_BACKEND=onnx \
    MINERU_MODEL_ONNX_DEVICE=cpu \
    MINERU_TELEMETRY_DISABLED=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 curl \
 && rm -rf /var/lib/apt/lists/*

# Pinned: 4.0 and 4.1 both changed the HTTP API.
RUN pip install "mineru==4.2.3"

# Bake the basic-tier ONNX models (~860 MB) into the image so the first upload doesn't download them.
RUN mineru-kit models download --tier basic --small-backend onnx --source huggingface \
 && mineru-kit models verify --tier basic --small-backend onnx

# Runtime: never download; trust Opsily's proxy headers so upload/result URLs come back as https://;
# keep uploads/results 1 hour instead of 24 h (ephemeral disk); trim heap after jobs.
ENV MINERU_MODEL_SOURCE=local \
    FORWARDED_ALLOW_IPS=* \
    MINERU_API_RETENTION_SECONDS=3600 \
    MINERU_MALLOC_TRIM=1

EXPOSE 8000

# Opsily chooses the port and passes it in $PORT. MINERU_API_KEY (set as a secret in the Opsily dashboard)
# becomes the required Bearer token; without it the API is open.
CMD ["sh", "-c", "echo \"Listening on port ${PORT:-8000}\"; [ -n \"$MINERU_API_KEY\" ] && echo 'API key enabled' || echo 'WARNING: no MINERU_API_KEY, API is open'; exec mineru-kit api-server --host 0.0.0.0 --port \"${PORT:-8000}\" --tier basic --concurrency 1 --preload-models ${MINERU_API_KEY:+--api-key \"$MINERU_API_KEY\"}"]
