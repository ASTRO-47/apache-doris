FROM python:3.11-slim

WORKDIR /app

COPY generator.py .

RUN pip install --no-cache-dir boto3 pymysql

CMD ["python", "generator.py"]
