FROM python:3.12-slim

# Create non-root user
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

COPY app/main.py .

# Install dependencies
RUN pip install --no-cache-dir flask gunicorn

# Change ownership
RUN chown -R appuser:appuser /app

USER appuser

EXPOSE 3000

CMD ["gunicorn", "--bind", "0.0.0.0:3000", "--workers", "1", "--threads", "4", "--timeout", "120", "main:app"]