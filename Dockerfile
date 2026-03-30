FROM python:3.12-slim

WORKDIR /app

# System deps for OpenCV headless
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1-mesa-glx libglib2.0-0 curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Create dirs for runtime data
RUN mkdir -p data outputs uploads

# Default config if none mounted
RUN [ ! -f config.yaml ] && cp config.example.yaml config.yaml || true

EXPOSE 7860

CMD ["python", "server.py"]
