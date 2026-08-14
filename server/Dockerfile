# ESP32 Power Meter API server
FROM python:3.12-slim

# Don't buffer stdout/stderr (logs show up immediately in `docker logs`)
# and skip .pyc files inside the container.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Install dependencies first so Docker can cache this layer between builds.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# SQLite database lives here; mount a volume at /app/data to persist it.
RUN mkdir -p /app/data

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
