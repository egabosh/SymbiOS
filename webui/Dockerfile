FROM python:3-slim

RUN addgroup --system --gid 10000 symbios && \
    adduser --system --uid 10000 --ingroup symbios symbios && \
    usermod -a -G adm symbios && \
    usermod -d /app symbios

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    procps \
    gcc \
    libldap2-dev \
    libsasl2-dev \
    ldap-utils \
    ansible \
    sshpass \
    && rm -rf /var/lib/apt/lists/*

COPY webui/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY webui/ .
RUN mkdir -p /log /config && chown -R symbios:symbios /app /log /config

USER symbios
EXPOSE 8080
ENTRYPOINT ["sh", "-c", "python manage.py migrate --noinput && python manage.py initial_setup && exec gunicorn webui.asgi:application -k uvicorn.workers.UvicornWorker --bind 0.0.0.0:8080"]
