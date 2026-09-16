"""
application/wsgi.py
WSGI entry point for Gunicorn (production) and Flask CLI (development).

Gunicorn command (from application/):
    gunicorn --workers 4 --bind 0.0.0.0:5000 wsgi:app

Flask CLI (from application/):
    flask --app wsgi run
"""

import os

from dotenv import load_dotenv

# Load .env file for local development. On EC2, environment variables are
# injected by the launch template user-data script or AWS Systems Manager.
load_dotenv()

from app import create_app  # noqa: E402  (import after dotenv)

app = create_app(os.getenv("FLASK_ENV", "development"))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
