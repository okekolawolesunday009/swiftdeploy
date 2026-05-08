FROM python:3.12-slim

RUN apt-get update && apt-get install -y curl

# Create user
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Create home dir
RUN mkdir -p /home/appuser && chown -R appuser:appuser /home/appuser

WORKDIR /app

# Copy app
COPY app/main.py .

# Install dependencies
RUN pip install --no-cache-dir flask gunicorn prometheus_client

# Set ownership
RUN chown -R appuser:appuser /app

USER appuser

EXPOSE 3000

CMD ["gunicorn", "--bind", "0.0.0.0:3000", "--workers", "1", "--threads", "4", "--timeout", "120", "main:app"]