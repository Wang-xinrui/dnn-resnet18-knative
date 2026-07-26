FROM python:3.11-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    MODEL_PATH=/models/resnet18-f37072fd.pth \
    DEVICE=cpu \
    PORT=8080

WORKDIR /srv/app

RUN python -m pip install --upgrade pip setuptools wheel && \
    python -m pip install \
      torch==2.4.0 \
      torchvision==0.19.0 \
      --index-url https://download.pytorch.org/whl/cpu

COPY requirements-app.txt /tmp/requirements-app.txt

RUN python -m pip install -r /tmp/requirements-app.txt

RUN mkdir -p /models && \
    python - <<'PY'
import hashlib
import pathlib
import urllib.request

url = "https://download.pytorch.org/models/resnet18-f37072fd.pth"
target = pathlib.Path("/models/resnet18-f37072fd.pth")
expected_prefix = "f37072fd"

urllib.request.urlretrieve(url, target)

digest = hashlib.sha256(target.read_bytes()).hexdigest()
if not digest.startswith(expected_prefix):
    raise RuntimeError(
        f"Unexpected model checksum: {digest}; expected prefix {expected_prefix}"
    )

print(f"Downloaded {target} sha256={digest}")
PY

COPY app /srv/app/app

EXPOSE 8080

CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --workers 1"]
