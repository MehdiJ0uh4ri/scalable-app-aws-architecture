# =============================================================================
# Dockerfile — Task Manager Application
# Multi-stage build: builder installs dependencies, final image is minimal.
# =============================================================================

# ----- Stage 1: dependency builder -----
FROM python:3.12-slim AS builder

WORKDIR /build

# Install build tools needed for psycopg2-binary
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --prefix=/install --no-cache-dir -r requirements.txt


# ----- Stage 2: production image -----
FROM python:3.12-slim

# Non-root user for security
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

# Install only runtime dependencies for PostgreSQL client
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy installed Python packages from builder
COPY --from=builder /install /usr/local

# Copy application source
COPY . .

# Create log directory and set permissions
RUN mkdir -p /app/logs && chown -R appuser:appuser /app

USER appuser

# Expose Gunicorn port
EXPOSE 5000

# Health check — mirrors the ALB target group health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:5000/health || exit 1

# Production startup command
CMD ["gunicorn", \
     "--workers", "4", \
     "--bind", "0.0.0.0:5000", \
     "--timeout", "120", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "wsgi:app"]
