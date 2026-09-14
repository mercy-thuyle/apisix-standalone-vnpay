# dashboard-hub — chạy trên máy LOCAL (Mac/laptop admin), KHÔNG deploy lên VM APISIX
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir "fastapi~=0.115.0" "uvicorn~=0.30.6" \
    "httpx~=0.27.0" "PyYAML~=6.0.1"
COPY app.py /app/app.py
ENV PYTHONUNBUFFERED=1
EXPOSE 18000
CMD ["python", "/app/app.py"]
