FROM python:3.12-slim

# 1. Create user FIRST
RUN groupadd -r appuser && useradd -r -g appuser appuser

# 2. Create directories AFTER user exists
RUN mkdir -p /home/appuser && chown -R appuser:appuser /home/appuser

WORKDIR /app

# 3. Copy app
COPY app/main.py .

# 4. Install dependencies
RUN pip install --no-cache-dir flask gunicorn

# 5. Set ownership AFTER files exist
RUN chown -R appuser:appuser /app

USER appuser

EXPOSE 3000

CMD ["gunicorn", "--bind", "0.0.0.0:3000", "--workers", "1", "--threads", "4", "--timeout", "120", "main:app"]