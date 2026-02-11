#!/usr/bin/env python3
"""
Test obstacle detection locally using your computer's camera and OpenCV (free, no API key).

Uses the same logic as obstacle.py: HOG person detector by default, or YOLOv8n ONNX
if you place yolov8n.onnx in the project root.

  uv sync
  uv run python test_obstacle_local.py

A window shows the camera. Every 1 second a frame is analyzed; the terminal prints
"Obstacle: <thing>" or "Path clear". Press 'q' in the window to quit.
"""

import sys
import time
from pathlib import Path

import cv2

# Use the same OpenCV-based detection as the agent
from obstacle import _decode_frame, _hog_detect_person, _yolo_detect

INTERVAL_SEC = 1.0


def main() -> None:
    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        print("Error: Could not open default camera (index 0).", file=sys.stderr)
        sys.exit(1)

    # Load detector: same as ObstacleProcessor (HOG or YOLOv8n if yolov8n.onnx present)
    project_root = Path(__file__).resolve().parent
    model_path = project_root / "yolov8n.onnx"
    net = None
    use_hog = True
    if model_path.is_file():
        try:
            net = cv2.dnn.readNetFromONNX(str(model_path))
            use_hog = False
            print("Using YOLOv8n ONNX (multiple classes).")
        except Exception as e:
            print("YOLOv8n load failed, using HOG (person only):", e)
    else:
        print("No yolov8n.onnx found. Using OpenCV HOG (person only). Place yolov8n.onnx in project root for more classes.")

    print("Point camera at path ahead. Press 'q' in the window to quit.")
    print(f"Checking every {INTERVAL_SEC}s...\n")

    frame_count = 0
    last_check = 0.0

    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                time.sleep(0.2)
                continue

            cv2.imshow("Obstacle test (q=quit)", frame)

            now = time.monotonic()
            if now - last_check >= INTERVAL_SEC:
                last_check = now
                frame_count += 1

                import base64
                jpeg_bytes = cv2.imencode(".jpg", frame)[1].tobytes()
                b64_str = base64.b64encode(jpeg_bytes).decode("ascii")
                img = _decode_frame(b64_str)
                if img is None:
                    continue
                if use_hog:
                    result = _hog_detect_person(img)
                else:
                    result = _yolo_detect(net, img) if net else None

                if result:
                    print(f"[frame {frame_count}] Obstacle: {result[0]}")
                else:
                    print(f"[frame {frame_count}] Path clear")

            if cv2.waitKey(1) & 0xFF == ord("q"):
                break
    finally:
        cap.release()
        cv2.destroyAllWindows()
    print("Done.")


if __name__ == "__main__":
    main()
