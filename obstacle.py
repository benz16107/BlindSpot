"""
Obstacle detection for blind pedestrians.
Uses OpenCV only (free, no API key): HOG person detector by default, or YOLOv8n ONNX if available.
Receives camera frames (base64 JPEG), runs detection, calls on_obstacle(description, is_new) or on_clear().
"""

import asyncio
import base64
import logging
import os
from pathlib import Path
from typing import Awaitable, Callable, Optional

import cv2
import numpy as np

logger = logging.getLogger("obstacle")

# COCO class names (index 0-79) for YOLOv8
COCO_NAMES = (
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train",
    "truck", "boat", "traffic light", "fire hydrant", "stop sign", "parking meter",
    "bench", "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear",
    "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase",
    "frisbee", "skis", "snowboard", "sports ball", "kite", "baseball bat",
    "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle",
    "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
    "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut",
    "cake", "chair", "couch", "potted plant", "bed", "dining table", "toilet",
    "tv", "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave",
    "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase",
    "scissors", "teddy bear", "hair drier", "toothbrush",
)

# Classes we care about as "obstacles in path" (person, vehicles, street furniture, animals, etc.)
# COCO indices: 0 person, 1 bicycle, 2 car, 3 motorcycle, 4 airplane, 5 bus, 6 train, 7 truck, 8 boat
# 9 traffic light, 10 fire hydrant, 11 stop sign, 12 parking meter, 13 bench
# 14 bird, 15 cat, 16 dog, 17 horse, 24 backpack, 25 umbrella, 26 handbag, 28 suitcase
# 36 skateboard, 39 bottle, 41 cup, 45 bowl
# 56 chair, 57 couch, 58 potted plant, 59 bed, 60 dining table, 61 toilet
# 62 tv, 63 laptop, 64 mouse, 65 remote, 66 keyboard, 67 cell phone
# 68 microwave, 70 toaster, 71 sink, 72 refrigerator, 73 book, 74 clock, 75 vase, 76 scissors, 77 teddy bear
OBSTACLE_CLASS_IDS = {
    0, 1, 2, 3, 4, 5, 6, 7, 8,       # person, vehicles
    9, 10, 11, 12, 13,                # traffic light, fire hydrant, stop sign, parking meter, bench
    14, 15, 16, 17,                   # bird, cat, dog, horse
    24, 25, 26, 28,                   # backpack, umbrella, handbag, suitcase
    36, 39, 41, 45,                   # skateboard, bottle, cup, bowl
    56, 57, 58, 59, 60, 61,           # chair, couch, potted plant, bed, dining table, toilet
    62, 63, 64, 65, 66, 67,           # tv, laptop, mouse, remote, keyboard, cell phone
    68, 70, 71, 72, 73, 74, 75, 76, 77,  # microwave, toaster, sink, refrigerator, book, clock, vase, scissors, teddy bear
}

# Center region: fraction of image that counts as "path ahead" (wider for phone/camera)
CENTER_X_FRAC = (0.2, 0.8)   # middle 60% horizontally
CENTER_Y_FRAC = (0.25, 1.0)  # lower 75% (skip sky)


def _decode_frame(b64: str) -> Optional[np.ndarray]:
    try:
        raw = base64.b64decode(b64)
    except Exception:
        return None
    if len(raw) < 100:
        return None
    arr = np.frombuffer(raw, dtype=np.uint8)
    img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    return img


def _center_region_contains(img_shape: tuple, box: list, scale: float = 1.0) -> bool:
    """True if box center falls in the "path ahead" region."""
    h, w = img_shape[:2]
    # box: [x_center - w/2, y_center - h/2, width, height] in 640 space, then * scale
    cx = (box[0] + box[2] / 2) * scale
    cy = (box[1] + box[3] / 2) * scale
    x_lo, x_hi = w * CENTER_X_FRAC[0], w * CENTER_X_FRAC[1]
    y_lo, y_hi = h * CENTER_Y_FRAC[0], h * CENTER_Y_FRAC[1]
    return x_lo <= cx <= x_hi and y_lo <= cy <= y_hi


def _hog_detect_person(img: np.ndarray) -> Optional[tuple]:
    """Returns (description, ) if person in center region else None. Uses OpenCV HOG."""
    try:
        hog = cv2.HOGDescriptor()
        hog.setSVMDetector(cv2.HOGDescriptor_getDefaultPeopleDetector())
    except Exception:
        return None
    h, w = img.shape[:2]
    (rects, _weights) = hog.detectMultiScale(img, winStride=(4, 4), padding=(8, 8), scale=1.05)
    x_lo, x_hi = w * CENTER_X_FRAC[0], w * CENTER_X_FRAC[1]
    y_lo, y_hi = h * CENTER_Y_FRAC[0], h * CENTER_Y_FRAC[1]
    for (rx, ry, rw, rh) in rects:
        cx = rx + rw / 2
        cy = ry + rh / 2
        if x_lo <= cx <= x_hi and y_lo <= cy <= y_hi:
            return ("person",)
    return None


def _yolo_detect(net: cv2.dnn.Net, img: np.ndarray, conf_thresh: float = 0.35) -> Optional[tuple]:
    """Returns (class_name, ) for first obstacle in center region else None."""
    h, w = img.shape[:2]
    length = max(h, w)
    padded = np.zeros((length, length, 3), dtype=np.uint8)
    padded[0:h, 0:w] = img
    scale = length / 640.0
    blob = cv2.dnn.blobFromImage(padded, scalefactor=1 / 255, size=(640, 640), swapRB=True)
    net.setInput(blob)
    outputs = net.forward()
    outputs = np.array([cv2.transpose(outputs[0])])
    rows = outputs.shape[1]
    boxes, scores, class_ids = [], [], []
    for i in range(rows):
        classes_scores = outputs[0][i][4:]
        (_, max_score, _, (_, max_idx)) = cv2.minMaxLoc(classes_scores)
        if max_score >= conf_thresh and max_idx in OBSTACLE_CLASS_IDS:
            box = [
                outputs[0][i][0] - 0.5 * outputs[0][i][2],
                outputs[0][i][1] - 0.5 * outputs[0][i][3],
                outputs[0][i][2],
                outputs[0][i][3],
            ]
            boxes.append(box)
            scores.append(float(max_score))
            class_ids.append(max_idx)
    if not boxes:
        return None
    # NMS
    try:
        indices = cv2.dnn.NMSBoxes(boxes, scores, conf_thresh, 0.45, 0.5)
        indices = np.array(indices).flatten()
    except Exception:
        indices = [0]
    for idx in indices:
        idx = int(idx)
        if idx >= len(boxes):
            continue
        box = boxes[idx]
        if _center_region_contains((h, w), box, scale):
            cid = class_ids[idx]
            name = COCO_NAMES[cid] if cid < len(COCO_NAMES) else "object"
            return (name,)
    return None


class ObstacleProcessor:
    """Processes frames with OpenCV (HOG or YOLOv8n ONNX); calls on_obstacle or on_clear."""

    def __init__(
        self,
        on_obstacle: Callable[[str, bool], Awaitable[None]],
        on_clear: Callable[[], Awaitable[None]],
    ) -> None:
        self._on_obstacle = on_obstacle
        self._on_clear = on_clear
        self._net: Optional[cv2.dnn.Net] = None
        self._use_hog = True
        self._queue: asyncio.Queue[Optional[tuple]] = asyncio.Queue(maxsize=2)
        self._task: Optional[asyncio.Task] = None
        self._running = False
        self._last_obstacle = False
        self._frames_processed = 0
        self._load_model()

    def _load_model(self) -> None:
        project_root = Path(__file__).resolve().parent
        model_path = os.environ.get("OBSTACLE_MODEL_PATH") or str(project_root / "yolov8n.onnx")
        if Path(model_path).is_file():
            try:
                self._net = cv2.dnn.readNetFromONNX(model_path)
                self._use_hog = False
                logger.info("Obstacle detection using YOLOv8n ONNX: %s", model_path)
            except Exception as e:
                logger.warning("Failed to load YOLOv8n ONNX (%s), using HOG person detector: %s", model_path, e)
                self._net = None
                self._use_hog = True
        else:
            logger.info("No yolov8n.onnx found (optional). Using OpenCV HOG person detector (person only).")
            self._use_hog = True

    def put_frame(self, data_base64: str) -> None:
        if not self._running:
            logger.debug("put_frame ignored (not running)")
            return
        b64 = (data_base64 or "").strip().replace("\n", "").replace("\r", "")
        if not b64:
            return
        try:
            if self._queue.full():
                try:
                    self._queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            self._queue.put_nowait(("image/jpeg", b64))
        except Exception as e:
            logger.debug("put_frame: %s", e)

    def start(self) -> None:
        if self._task and not self._task.done():
            return
        self._running = True
        self._task = asyncio.create_task(self._loop())
        mode = "HOG (person only)" if self._use_hog else "YOLOv8n ONNX"
        logger.info("Obstacle processor started (OpenCV %s)", mode)

    def stop(self) -> None:
        self._running = False
        try:
            self._queue.put_nowait(None)
        except asyncio.QueueFull:
            pass
        if self._task and not self._task.done():
            self._task.cancel()
        logger.info("Obstacle processor stopped (processed %d frames)", self._frames_processed)

    async def _loop(self) -> None:
        try:
            while self._running:
                try:
                    item = await asyncio.wait_for(self._queue.get(), timeout=0.5)
                except asyncio.TimeoutError:
                    continue
                if item is None or not self._running:
                    break
                _, b64 = item
                img = await asyncio.to_thread(_decode_frame, b64)
                if img is None:
                    logger.debug("obstacle frame decode failed (b64 len=%d)", len(b64))
                    continue
                if len(img.shape) < 2 or img.size < 100:
                    continue
                if self._frames_processed == 0 or self._frames_processed % 30 == 1:
                    logger.info("obstacle frame shape: %s (h=%d w=%d)", img.shape, img.shape[0], img.shape[1])
                if self._use_hog:
                    result = await asyncio.to_thread(_hog_detect_person, img)
                else:
                    result = await asyncio.to_thread(_yolo_detect, self._net, img) if self._net else None
                self._frames_processed += 1
                if self._frames_processed % 25 == 0:
                    logger.info("Obstacle pipeline alive: processed %d frames", self._frames_processed)
                if result:
                    desc = result[0]
                    is_new = not self._last_obstacle
                    self._last_obstacle = True
                    logger.info("Obstacle detected: %s (new=%s, frame#%d)", desc, is_new, self._frames_processed)
                    try:
                        await self._on_obstacle(desc, is_new)
                    except Exception as e:
                        logger.warning("on_obstacle: %s", e)
                else:
                    self._last_obstacle = False
                    logger.debug("Path clear (frame#%d)", self._frames_processed)
                    try:
                        await self._on_clear()
                    except Exception as e:
                        logger.warning("on_clear: %s", e)
        except asyncio.CancelledError:
            pass
        finally:
            self._running = False
