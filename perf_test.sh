#!/bin/bash
# 性能测试脚本 - 使用 benchmark_app 测试模型性能

MODEL_PATH="${1:-.}/yolo11n_seg/yolo11n-seg.xml"
DEVICE="${2:-GPU}"

echo "=========================================="
echo "Model Performance Test"
echo "=========================================="
echo "Model: $MODEL_PATH"
echo "Device: $DEVICE"
echo ""

# 检查模型文件是否存在
if [ ! -f "$MODEL_PATH" ]; then
    echo "❌ 错误：模型文件不存在: $MODEL_PATH"
    exit 1
fi

# 运行 benchmark_app
benchmark_app -m "$MODEL_PATH" -d "$DEVICE" -api async -shape "[1,3,640,640]" -t 15

echo "=========================================="
