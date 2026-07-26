import io
import os
import socket
import time
from contextlib import asynccontextmanager
from typing import Any

import torch
from fastapi import FastAPI, File, HTTPException, Query, UploadFile
from PIL import Image, UnidentifiedImageError
from torchvision.models import ResNet18_Weights, resnet18

MODEL_PATH = os.getenv("MODEL_PATH", "/models/resnet18-f37072fd.pth")
DEVICE_NAME = os.getenv("DEVICE", "cpu")
POD_NAME = os.getenv("HOSTNAME", socket.gethostname())

if DEVICE_NAME == "cuda" and not torch.cuda.is_available():
    raise RuntimeError("DEVICE=cuda, but torch.cuda.is_available() is false")

DEVICE = torch.device(DEVICE_NAME)


def load_model() -> tuple[torch.nn.Module, Any, list[str], float, float]:
    load_started = time.perf_counter()

    weights_info = ResNet18_Weights.IMAGENET1K_V1
    model = resnet18(weights=None)

    try:
        state_dict = torch.load(
            MODEL_PATH,
            map_location="cpu",
            weights_only=True,
        )
    except TypeError:
        # Compatibility fallback if the runtime does not support weights_only.
        state_dict = torch.load(MODEL_PATH, map_location="cpu")

    model.load_state_dict(state_dict)
    model.eval()
    model.to(DEVICE)

    transform = weights_info.transforms()
    categories = list(weights_info.meta["categories"])
    model_load_ms = (time.perf_counter() - load_started) * 1000

    warmup_started = time.perf_counter()
    warmup_tensor = torch.zeros((1, 3, 224, 224), device=DEVICE)
    with torch.inference_mode():
        _ = model(warmup_tensor)
        if DEVICE.type == "cuda":
            torch.cuda.synchronize()
    warmup_ms = (time.perf_counter() - warmup_started) * 1000

    return model, transform, categories, model_load_ms, warmup_ms


@asynccontextmanager
async def lifespan(app: FastAPI):
    process_started = time.time()
    model, transform, categories, model_load_ms, warmup_ms = load_model()

    app.state.model = model
    app.state.transform = transform
    app.state.categories = categories
    app.state.model_load_ms = model_load_ms
    app.state.warmup_ms = warmup_ms
    app.state.process_started = process_started
    app.state.synthetic_tensor = torch.zeros((1, 3, 224, 224), device=DEVICE)

    print(
        {
            "event": "model_ready",
            "pod": POD_NAME,
            "device": str(DEVICE),
            "model_load_ms": round(model_load_ms, 3),
            "warmup_ms": round(warmup_ms, 3),
        },
        flush=True,
    )

    yield


app = FastAPI(
    title="Serverless ResNet18 Inference",
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict[str, Any]:
    ready = hasattr(app.state, "model")
    if not ready:
        raise HTTPException(status_code=503, detail="model not ready")

    return {
        "status": "ready",
        "pod": POD_NAME,
        "device": str(DEVICE),
    }


@app.get("/metadata")
def metadata() -> dict[str, Any]:
    return {
        "pod": POD_NAME,
        "device": str(DEVICE),
        "torch_version": torch.__version__,
        "cuda_available": torch.cuda.is_available(),
        "model_path": MODEL_PATH,
        "model_load_ms": round(app.state.model_load_ms, 3),
        "warmup_ms": round(app.state.warmup_ms, 3),
        "uptime_seconds": round(time.time() - app.state.process_started, 3),
    }


def run_inference(tensor: torch.Tensor, repeat: int) -> tuple[torch.Tensor, float]:
    started = time.perf_counter()

    with torch.inference_mode():
        output = None
        for _ in range(repeat):
            output = app.state.model(tensor)

        if DEVICE.type == "cuda":
            torch.cuda.synchronize()

    elapsed_ms = (time.perf_counter() - started) * 1000
    assert output is not None
    return output, elapsed_ms


def format_top5(output: torch.Tensor) -> list[dict[str, Any]]:
    probabilities = torch.nn.functional.softmax(output[0], dim=0)
    values, indices = torch.topk(probabilities, 5)

    results: list[dict[str, Any]] = []
    for probability, class_index in zip(values.tolist(), indices.tolist()):
        results.append(
            {
                "class_id": int(class_index),
                "label": app.state.categories[class_index],
                "probability": round(float(probability), 6),
            }
        )
    return results


@app.get("/infer/synthetic")
def infer_synthetic(
    repeat: int = Query(default=1, ge=1, le=1000),
) -> dict[str, Any]:
    output, inference_ms = run_inference(app.state.synthetic_tensor, repeat)

    return {
        "pod": POD_NAME,
        "device": str(DEVICE),
        "repeat": repeat,
        "inference_ms": round(inference_ms, 3),
        "top5": format_top5(output),
    }


@app.post("/predict")
async def predict(
    file: UploadFile = File(...),
    repeat: int = Query(default=1, ge=1, le=100),
) -> dict[str, Any]:
    try:
        image_bytes = await file.read()
        image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    except (UnidentifiedImageError, OSError) as exc:
        raise HTTPException(status_code=400, detail="invalid image file") from exc

    tensor = app.state.transform(image).unsqueeze(0).to(DEVICE)
    output, inference_ms = run_inference(tensor, repeat)

    return {
        "pod": POD_NAME,
        "device": str(DEVICE),
        "filename": file.filename,
        "repeat": repeat,
        "inference_ms": round(inference_ms, 3),
        "top5": format_top5(output),
    }
