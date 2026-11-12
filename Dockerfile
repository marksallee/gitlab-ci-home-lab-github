FROM python:3.15-slim
LABEL org.opencontainers.image.source="https://github.com/benc-uk/python-demoapp" \
      org.opencontainers.image.licenses="MIT"
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION PYTHONUNBUFFERED=1
WORKDIR /srv
COPY src/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src/run.py .
COPY src/app ./app
RUN useradd -r app
USER app
EXPOSE 8000
CMD ["gunicorn", "-b", "0.0.0.0:8000", "run:app"]
