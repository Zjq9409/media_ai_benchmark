#!/usr/bin/env bash
# media_ai_b60_10fps_videorate.sh
# "10FPS = 真限帧" 版本: 用 videorate 把每路内容帧率降到 FRAMERATE (默认10),
# 然后每帧都检测 (即每路 10 次/秒真实检测). 与 inference-interval 版对照.
#   降帧位置: 解码后、检测前 -> 推理只处理 10fps, 但解码仍全帧(解码不是瓶颈)
# batch-size 固定 1 (va-surface-sharing 不支持 batching)
set -uo pipefail

INPUT_FILE="./video/1920x1080_25fps.h265"
MODEL_FOLDER="./models/yolo11m-seg_openvino_model"
GPU_DEVICE="GPU.0"
STREAMS=30
FRAMERATE=10             # 目标限帧 (每路内容帧率)
NUM_GROUPS=0             # 0=自动约每组3路
PASS_THRESHOLD=10        # 每路 wall-clock FPS 达标阈值
RUN_SECONDS=45

show_help() {
  cat << HELP
用法: $0 [选项]
  -f <file>   输入视频 (默认 $INPUT_FILE)
  -m <dir>    模型目录 (默认 $MODEL_FOLDER)
  -g <dev>    GPU 设备 GPU.0..3 (默认 $GPU_DEVICE)
  -n <num>    并发路数 (默认 $STREAMS)
  -r <fps>    videorate 限帧 (默认 $FRAMERATE)
  -G <num>    分组数, 0=自动 (默认 auto)
  -t <fps>    达标阈值 (默认 $PASS_THRESHOLD)
  -s <sec>    采样时长 (默认 $RUN_SECONDS)
  -h          帮助
HELP
}

while getopts "f:m:g:n:r:G:t:s:h" opt; do
  case $opt in
    f) INPUT_FILE="$OPTARG" ;;
    m) MODEL_FOLDER="$OPTARG" ;;
    g) GPU_DEVICE="$OPTARG" ;;
    n) STREAMS="$OPTARG" ;;
    r) FRAMERATE="$OPTARG" ;;
    G) NUM_GROUPS="$OPTARG" ;;
    t) PASS_THRESHOLD="$OPTARG" ;;
    s) RUN_SECONDS="$OPTARG" ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done

[[ -f "$INPUT_FILE" ]] || { echo "错误: 找不到视频 $INPUT_FILE"; exit 1; }
MODEL_XML=$(find "$MODEL_FOLDER" -maxdepth 1 -name "*.xml" -type f | head -1)
[[ -n "$MODEL_XML" ]] || { echo "错误: $MODEL_FOLDER 下无 .xml"; exit 1; }
[[ "$GPU_DEVICE" =~ ^GPU\.[0-3]$ ]] || { echo "错误: GPU 须为 GPU.0..3"; exit 1; }

case "$GPU_DEVICE" in
  GPU.0) DEC=vah265dec;            PP=vapostproc ;;
  GPU.1) DEC=varenderD129h265dec;  PP=varenderD129postproc ;;
  GPU.2) DEC=varenderD130h265dec;  PP=varenderD130postproc ;;
  GPU.3) DEC=varenderD131h265dec;  PP=varenderD131postproc ;;
esac

if [[ "$NUM_GROUPS" -le 0 ]]; then
  NUM_GROUPS=$(( (STREAMS + 2) / 3 )); [[ $NUM_GROUPS -lt 1 ]] && NUM_GROUPS=1
fi
[[ $NUM_GROUPS -gt $STREAMS ]] && NUM_GROUPS=$STREAMS

INPUT_FILE=$(realpath "$INPUT_FILE")
SCRIPTS_DIR="$(pwd)/group_scripts_vr10"
BASE=$(( STREAMS / NUM_GROUPS )); REM=$(( STREAMS % NUM_GROUPS ))

echo "=========================================="
echo "Media AI B60 - 10FPS (videorate 限帧版)"
echo "  视频:     $INPUT_FILE"
echo "  模型:     $MODEL_XML"
echo "  GPU:      $GPU_DEVICE ($DEC / $PP)"
echo "  路数:     $STREAMS   分组: $NUM_GROUPS (均衡 $REM×$((BASE+1)) + $((NUM_GROUPS-REM))×$BASE)"
echo "  限帧:     ${FRAMERATE}fps (每帧检测 -> ${FRAMERATE} 次/秒真实检测)"
echo "  阈值:     $PASS_THRESHOLD FPS/路"
echo "=========================================="

cleanup() { pkill -f "group_vr10_" 2>/dev/null || true; pkill -f "gst-launch-1.0" 2>/dev/null || true; }
trap cleanup EXIT
cleanup; sleep 1
rm -rf "$SCRIPTS_DIR"; mkdir -p "$SCRIPTS_DIR"; rm -f group_vr10_*.log

pids=(); gcount=0
for ((g=0; g<NUM_GROUPS; g++)); do
  n=$BASE; [[ $g -lt $REM ]] && n=$((BASE+1)); [[ $n -le 0 ]] && continue
  P="gst-launch-1.0 -e"
  for ((j=0; j<n; j++)); do
    P="$P multifilesrc location=\"$INPUT_FILE\" loop=true ! h265parse ! $DEC ! $PP ! \"video/x-raw(memory:VAMemory)\" !"
    P="$P videorate ! \"video/x-raw(memory:VAMemory),framerate=$FRAMERATE/1\" !"
    P="$P gvadetect model=\"$MODEL_XML\" device=$GPU_DEVICE pre-process-backend=va-surface-sharing batch-size=1 model-instance-id=yolovr10-$g !"
    P="$P queue ! gvafpscounter starting-frame=100 ! fakesink sync=false async=false"
  done
  echo "$P" > "$SCRIPTS_DIR/group_vr10_$g.sh"
  bash "$SCRIPTS_DIR/group_vr10_$g.sh" > "group_vr10_$g.log" 2>&1 &
  pids+=($!); gcount=$((gcount+1)); sleep 1
done

echo "已启动 $gcount 组, 采样 ${RUN_SECONDS}s ..."
sleep "$RUN_SECONDS"

total=0
for ((g=0; g<gcount; g++)); do
  [[ -f "group_vr10_$g.log" ]] || continue
  f=$(grep "FpsCounter(average" "group_vr10_$g.log" | tail -1 | grep -oP "total=\K[0-9.]+" || echo 0)
  total=$(awk "BEGIN{print $total + ${f:-0}}")
done
cleanup

per_stream=$(awk "BEGIN{printf \"%.2f\", $total/$STREAMS}")
pass=$(awk "BEGIN{print ($per_stream >= $PASS_THRESHOLD) ? \"PASS\" : \"FAIL\"}")
echo "=========================================="
echo "结果: 路数=$STREAMS  总吞吐=${total} FPS  每路=${per_stream} FPS  阈值=${PASS_THRESHOLD}  判定=$pass"
echo "=========================================="
