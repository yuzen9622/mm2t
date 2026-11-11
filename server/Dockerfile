# RTX 50 series (Blackwell, sm_120) needs cuBLAS from CUDA >= 12.8; the ctranslate2
# 4.8.5 Linux wheel is itself built against CUDA 12.8 and loads cuBLAS from this image.
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04@sha256:ac55d124da4882b497f732d8dfd9a702d5447a5f29d08d56da6f64f0a1eb34bc

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH \
    HF_HOME=/models

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/venv

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY mm2t_server ./mm2t_server

EXPOSE 8000
CMD ["python", "-m", "mm2t_server"]
