FROM python:3-slim

RUN addgroup --system --gid 10000 symbios && \
    adduser --system --uid 10000 --ingroup symbios symbios && \
    usermod -a -G adm symbios

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    procps \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir django gunicorn uvicorn whitenoise ipaddress

USER symbios
ENTRYPOINT ["gunicorn", "webui.asgi:application", "-k", "uvicorn.workers.UvicornWorker", "--bind", "0.0.0.0:8080"]
