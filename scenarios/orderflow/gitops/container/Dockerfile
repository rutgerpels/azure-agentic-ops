# Build context: scenarios/orderflow/app. One image serves the portal, API and smoke job;
# Container Apps overrides the command per app.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY requirements.txt .
RUN python -m pip install --no-cache-dir -r requirements.txt

COPY backend.py common.py portal.py smoke.py ./
COPY static/ ./static/

RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin orderflow
USER 10001

EXPOSE 8000 8080

CMD ["gunicorn", "portal:app", "-k", "uvicorn.workers.UvicornWorker", "-w", "1", "-b", "0.0.0.0:8000"]
