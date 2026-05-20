FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/data/hf-cache \
    TRANSFORMERS_NO_ADVISORY_WARNINGS=1 \
    SENTENCE_TRANSFORMERS_HOME=/data/hf-cache

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
# torch is pulled in transitively by sentence-transformers; pin the CPU wheel
# explicitly so we don't drag CUDA runtimes into the image.
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.5.1 \
 && pip install --no-cache-dir -r requirements.txt

COPY app.py ./

VOLUME ["/data"]
EXPOSE 8088

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://localhost:8088/health || exit 1

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8088"]
