import asyncio
import base64

import cv2
import numpy as np
import pytest

import obstacle
from obstacle import (
    COCO_NAMES,
    ObstacleProcessor,
    _center_region_contains,
    _decode_frame,
    _hog_detect_person,
    _yolo_detect,
)


def _jpeg_b64(img: np.ndarray) -> str:
    ok, buf = cv2.imencode(".jpg", img)
    assert ok
    return base64.b64encode(buf.tobytes()).decode()


def _noise(h=240, w=320):
    return np.random.default_rng(0).integers(0, 255, (h, w, 3), dtype=np.uint8)


# --- frame decoding ---------------------------------------------------------

def test_decode_frame_roundtrip_shape():
    img = _decode_frame(_jpeg_b64(_noise()))
    assert img is not None and img.shape == (240, 320, 3)


@pytest.mark.parametrize("b64", ["not base64!!", base64.b64encode(b"tiny").decode(), ""])
def test_decode_frame_rejects_garbage_or_short(b64):
    assert _decode_frame(b64) is None


def test_decode_frame_non_image_bytes_returns_none():
    assert _decode_frame(base64.b64encode(b"x" * 500).decode()) is None


# --- centre region ----------------------------------------------------------

@pytest.mark.parametrize(
    "box, expected",
    [
        ([300, 300, 40, 40], True),    # centre (320, 320) is in path
        ([0, 300, 40, 40], False),     # far left
        ([600, 300, 40, 40], False),   # far right
        ([300, 0, 40, 40], False),     # top (sky)
        ([300, 600, 40, 40], True),    # bottom edge, cy=620 < 640
        ([108, 300, 40, 40], True),    # cx=128, exactly on the 0.2 boundary
    ],
)
def test_center_region_contains(box, expected):
    assert _center_region_contains((640, 640), box) is expected


def test_center_region_applies_scale():
    # Box centre (100, 100) is outside the 1280x1280 path region (x 256..1024, y 320..1280);
    # scaled x4 it lands at (400, 400), inside.
    assert not _center_region_contains((1280, 1280), [80, 80, 40, 40])
    assert _center_region_contains((1280, 1280), [80, 80, 40, 40], scale=4.0)


# --- YOLO post-processing (fake net, no model file) -------------------------

class _FakeNet:
    """Mimics cv2.dnn.Net: forward() returns (1, 84, N) YOLOv8 output."""

    def __init__(self, detections):
        out = np.zeros((1, 84, max(len(detections), 1)), dtype=np.float32)
        for i, (cx, cy, w, h, cls, score) in enumerate(detections):
            out[0, 0:4, i] = (cx, cy, w, h)
            out[0, 4 + cls, i] = score
        self._out = out

    def setInput(self, blob):
        assert blob.shape == (1, 3, 640, 640)

    def forward(self):
        return self._out


IMG = np.zeros((640, 640, 3), dtype=np.uint8)


def test_yolo_detects_obstacle_in_center():
    net = _FakeNet([(320, 400, 80, 160, 0, 0.9)])  # person, centre
    assert _yolo_detect(net, IMG) == ("person",)


def test_yolo_names_non_person_class():
    net = _FakeNet([(320, 400, 80, 80, 56, 0.8)])  # chair
    assert _yolo_detect(net, IMG) == (COCO_NAMES[56],)


def test_yolo_ignores_off_center_box():
    net = _FakeNet([(20, 400, 30, 30, 0, 0.9)])
    assert _yolo_detect(net, IMG) is None


def test_yolo_ignores_low_confidence():
    net = _FakeNet([(320, 400, 80, 160, 0, 0.2)])
    assert _yolo_detect(net, IMG) is None


def test_yolo_ignores_non_obstacle_class():
    non_obstacle = next(i for i in range(80) if i not in obstacle.OBSTACLE_CLASS_IDS)
    net = _FakeNet([(320, 400, 80, 160, non_obstacle, 0.9)])
    assert _yolo_detect(net, IMG) is None


def test_yolo_scales_non_square_image():
    # 480x960 frame pads to 960x960, scale 1.5. Box centre (320, 320) in 640-space -> (480, 480).
    img = np.zeros((480, 960, 3), dtype=np.uint8)
    assert _yolo_detect(_FakeNet([(320, 320, 40, 40, 2, 0.9)]), img) == ("car",)


def test_obstacle_class_ids_are_valid_coco_indices():
    assert len(COCO_NAMES) == 80
    assert all(0 <= i < 80 for i in obstacle.OBSTACLE_CLASS_IDS)


# --- HOG and the processor loop ---------------------------------------------

def test_hog_blank_image_is_clear():
    assert _hog_detect_person(np.zeros((256, 256, 3), dtype=np.uint8)) is None


def test_hog_real_detector_runs_on_blank_image():
    # Guards the opencv<5 cap: HOGDescriptor was dropped in opencv 5.0.
    assert hasattr(cv2, "HOGDescriptor")
    assert _hog_detect_person(np.full((240, 320, 3), 127, np.uint8)) is None


class _FakeHog:
    rects: list = []

    def setSVMDetector(self, _):
        pass

    def detectMultiScale(self, img, **_):
        return np.array(self.rects), np.ones(len(self.rects))


@pytest.fixture
def fake_hog(monkeypatch):
    monkeypatch.setattr(cv2, "HOGDescriptor", _FakeHog, raising=False)
    monkeypatch.setattr(cv2, "HOGDescriptor_getDefaultPeopleDetector", lambda: None, raising=False)
    return _FakeHog


@pytest.mark.parametrize(
    "rect, expected",
    [
        ((280, 200, 80, 160), ("person",)),  # centre (320, 280)
        ((0, 200, 60, 160), None),           # centre x=30, left edge
        ((580, 200, 60, 160), None),         # centre x=610, right edge
    ],
)
def test_hog_filters_by_region(fake_hog, rect, expected):
    fake_hog.rects = [rect]
    assert _hog_detect_person(np.zeros((480, 640, 3), np.uint8)) == expected


def test_put_frame_keeps_only_newest_two(monkeypatch):
    monkeypatch.setenv("OBSTACLE_MODEL_PATH", "/nonexistent/yolov8n.onnx")

    async def noop(*_):
        pass

    async def run():
        proc = ObstacleProcessor(noop, noop)
        proc._running = True  # accept frames without starting the loop
        for b64 in ("a", "b\n", "c\r\n", "   "):
            proc.put_frame(b64)
        return [proc._queue.get_nowait()[1] for _ in range(proc._queue.qsize())]

    assert asyncio.run(run()) == ["b", "c"]


def test_processor_reports_clear_for_blank_frame(monkeypatch):
    monkeypatch.setenv("OBSTACLE_MODEL_PATH", "/nonexistent/yolov8n.onnx")  # force HOG
    events = []

    async def on_obstacle(desc, is_new):
        events.append(("obstacle", desc, is_new))

    async def on_clear():
        events.append(("clear",))

    async def run():
        proc = ObstacleProcessor(on_obstacle, on_clear)
        assert proc._use_hog
        proc.put_frame("ignored before start")
        proc.start()
        proc.put_frame(_jpeg_b64(np.zeros((256, 256, 3), dtype=np.uint8)))
        for _ in range(100):
            if events:
                break
            await asyncio.sleep(0.02)
        proc.stop()

    asyncio.run(run())
    assert events == [("clear",)]


def test_processor_is_new_flag(monkeypatch):
    monkeypatch.setenv("OBSTACLE_MODEL_PATH", "/nonexistent/yolov8n.onnx")
    results = iter([("person",), ("person",), None, ("dog",)])
    monkeypatch.setattr(obstacle, "_hog_detect_person", lambda img: next(results))
    events = []

    async def on_obstacle(desc, is_new):
        events.append((desc, is_new))

    async def on_clear():
        events.append("clear")

    async def run():
        proc = ObstacleProcessor(on_obstacle, on_clear)
        proc.start()
        frame = _jpeg_b64(_noise())
        for _ in range(4):
            proc.put_frame(frame)
            for _ in range(100):
                if len(events) == proc._frames_processed and proc._queue.empty():
                    break
                await asyncio.sleep(0.02)
        proc.stop()

    asyncio.run(run())
    assert events == [("person", True), ("person", False), "clear", ("dog", True)]
