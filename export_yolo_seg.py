from ultralytics import YOLO
from pathlib import Path

# SEG_MODEL_NAME = "yolo11n-seg"
SEG_MODEL_NAME = "yolov8n-seg"
models_dir = Path("./models")
models_dir.mkdir(exist_ok=True)
seg_model = YOLO(models_dir / f"{SEG_MODEL_NAME}.pt")

# Export with FP32 for better compatibility with older DL Streamer versions
seg_model.export(
    format="openvino",
    half=False,           # Use FP32 instead of FP16 for compatibility
    dynamic=True,
    imgsz=640,
)

# Get the actual exported directory name
export_dir = models_dir / f"{SEG_MODEL_NAME}_openvino_model"
print(f"✓ Model exported successfully to {export_dir}")
