FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt /app/publisher/requirements.txt
RUN pip install --no-cache-dir -r /app/publisher/requirements.txt \
    && useradd --uid 10001 --create-home publisher
COPY . /app/publisher/
USER 10001
EXPOSE 8080
CMD ["uvicorn", "publisher.server:create_runtime_app", "--factory", "--host", "0.0.0.0", "--port", "8080", "--no-access-log", "--no-proxy-headers"]
