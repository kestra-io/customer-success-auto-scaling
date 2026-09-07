FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY scaler ./scaler
# unbuffered stdout so `kubectl logs -f` is live
ENV PYTHONUNBUFFERED=1
CMD ["python", "-m", "scaler.controller"]
