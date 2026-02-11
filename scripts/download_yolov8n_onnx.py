#!/usr/bin/env python3
"""Download YOLOv8n and export to ONNX in project root."""
from pathlib import Path

def main():
    try:
        from ultralytics import YOLO
    except ImportError:
        print("Install: uv add ultralytics  OR  uv run --with ultralytics python scripts/download_yolov8n_onnx.py")
        raise SystemExit(1)
    root = Path(__file__).resolve().parent.parent
    out = root / "yolov8n.onnx"
    if out.is_file():
        print(out, "already exists.")
        return
    print("Loading YOLOv8n...")
    model = YOLO("yolov8n.pt")
    print("Exporting to ONNX...")
    model.export(format="onnx", imgsz=640, opset=12)
    cwd_onnx = Path("yolov8n.onnx")
    if cwd_onnx.is_file() and cwd_onnx.resolve() != out.resolve():
        cwd_onnx.rename(out)
    print("Done:", out)

if __name__ == "__main__": main()
