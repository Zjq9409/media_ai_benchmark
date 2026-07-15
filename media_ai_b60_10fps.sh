#!/usr/bin/env bash
# media_ai_b60_10fps.sh
# 针对 "每路 >=10 FPS" 目标的优化版多路 YOLO 基准脚本 (B60, 单张 GPU)
# 关键优化:
#   - inference-interval=N : 源视频 25fps, 只在每 N 帧上做检测, 吞吐近似 xN
#   - 每组 2~3 路 : 多进程/多模型实例并行, 比单组(单实例)吞吐更高
#   - PASS_THRESHOLD=10 : 判定阈值改为 10 FPS/路
# 说明: batch-size 固定为 1 (va-surface-sharing 后端不支持 batching, 属硬限制)
#       FP16 与 FP32/静态动态在实际流水线中吞吐一致, 无需切换
set -uo pipefail

# ---------- 默认参数 ----------
INPUT_FILE="./video/1920x1080_25fps.h265"
MODEL_FOLDER="./models/yolo11m-seg_openvino_model"
GPU_DEVICE="GPU.0"
STREAMS=62               # 目标路数 (ii=2 时单卡约 62 路 @ >=10fps)
INFER_INTERVAL=2         # 检测间隔: 1=每帧(~30路) 2=每2帧(~62路) 3=(~99路)
NUM_GROUPS=0             # 0=自动 (约每组 3 路)
PASS_THRESHOLD=10        # 每路 FPS 达标阈值
RUN_SECONDS=45           # 采样时长

show_help() {
  cat << HELP
用法: $0 [选项]
  -f <file>    输入视频 (默认 $INPUT_FILE)
  -m <dir>     模型目录 (默认 $MODEL_FOLDER)
  -g <device>  GPU 设备 GPU.0..3 (默认 $GPU_DEVICE)
  -n <num>     并发路数 (默认 $STREAMS)
  -i <num>     inference-interval, 每 N 帧检测一次 (默认 $INFER_INTERVAL)
  -G <num>     分组数, 0=自动约每组3路 (默认 auto)
  -t <fps>     每路达标阈值 (默认 $PASS_THRESHOLD)
  -s <sec>     采样时长秒 (默认 $RUN_SECONDS)
  -h           帮助
参考容量 (单张 GPU.0, yolo11m-seg):
  -i 1 -> ~30 路 | -i 2 -> ~62 路 | -i 3 -> ~99 路 | -i 4 -> ~130 路
HELP
}

while getopts "f:m:g:n:i:G:t:s:h" opt; do
  case $opt in
    f) INPUT_FILE="$OPTARG" ;;
    m) MODEL_FOLDER="$OPTARG" ;;
    g) GPU_DEVICE="$OPTARG" ;;
    n) STREAMS="$OPTARG" ;;
    i) INFER_INTERVAL="$OPTARG" ;;
    G) NUM_GROUPS="$OPTARG" ;;
    t) PASS_THRESHOLD="$OPTARG" ;;
    s) RUN_SECONDS="$OPTARG" ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done

# ---------- 校验 ----------
[[ -f "$INPUT_FILE" ]] || { echo "错误: 找不到视频文件 $INPUT_FILE"; exit 1; }
MODEL_XML=$(find "$MODEL_FOLDER" -maxdepth 1 -name "*.xml" -type f | head -1)
[[ -n "$MODEL_XML" ]] || { echo "错误: $MODEL_FOLDER 下没有 .xml 模型"; exit 1; }
[[ "$GPU_DEVICE" =~ ^GPU\.[0-3]$ ]] || { echo "错误: GPU 设备须为 GPU.0..3"; exit 1; }

# 解码器/后处理元件 (按 GPU 设备选择)
case "$GPU_DEVICE" in
  GPU.0) DEC=vah265dec;            PP=vapostproc ;;
  GPU.1) DEC=varenderD129h265dec;  PP=varenderD129postproc ;;
  GPU.2) DEC=varenderD130h265dec;  PP=varenderD130postproc ;;
  GPU.3) DEC=varenderD131h265dec;  PP=varenderD131postproc ;;
esac

# 自动分组: 约每组 3 路 (实测每组 2~3 路吞吐最高)
if [[ "$NUM_GROUPS" -le 0 ]]; then
  NUM_GROUPS=$(( (STREAMS + 2) / 3 ))
  [[ $NUM_GROUPS -lt 1 ]] && NUM_GROUPS=1
fi
# 组数不能超过路数
[[ $NUM_GROUPS -gt $STREAMS ]] && NUM_GROUPS=$STREAMS

INPUT_FILE=$(realpath "$INPUT_FILE")
WORKDIR=$(pwd)
SCRIPTS_DIR="$WORKDIR/group_scripts_10fps"

# 均衡分组: 基数 base, 余数 rem 摊到前 rem 组 (每组最多差 1 路)
BASE=$(( STREAMS / NUM_GROUPS ))
REM=$(( STREAMS % NUM_GROUPS ))

echo "=========================================="
echo "Media AI B60 - 10FPS 优化基准"
echo "  视频:        $INPUT_FILE"
echo "  模型:        $MODEL_XML"
echo "  GPU:         $GPU_DEVICE ($DEC / $PP)"
echo "  路数:        $STREAMS"
echo "  分组:        $NUM_GROUPS (均衡: $REM 组 $((BASE+1)) 路, $((NUM_GROUPS-REM)) 组 $BASE 路)"
echo "  检测间隔:    $INFER_INTERVAL (检测频率约 $(awk "BEGIN{printf \"%.1f\", 25/$INFER_INTERVAL}") 次/秒)"
echo "  达标阈值:    $PASS_THRESHOLD FPS/路"
echo "=========================================="

cleanup() {
  pkill -f "group_10fps_" 2>/dev/null || true
  pkill -f "gst-launch-1.0" 2>/dev/null || true
}
trap cleanup EXIT
cleanup; sleep 1
rm -rf "$SCRIPTS_DIR"; mkdir -p "$SCRIPTS_DIR"
rm -f group_10fps_*.log

pids=(); gcount=0
for ((g=0; g<NUM_GROUPS; g++)); do
  # 均衡分配: 前 REM 组各 BASE+1 路, 其余各 BASE 路
  n=$BASE
  [[ $g -lt $REM ]] && n=$((BASE+1))
  [[ $n -le 0 ]] && continue
  P="gst-launch-1.0 -e"
  for ((j=0; j<n; j++)); do
    P="$P multifilesrc location=\"$INPUT_FILE\" loop=true ! h265parse ! $DEC ! $PP ! \"video/x-raw(memory:VAMemory)\" !"
    P="$P gvadetect model=\"$MODEL_XML\" device=$GPU_DEVICE pre-process-backend=va-surface-sharing batch-size=1 inference-interval=$INFER_INTERVAL model-instance-id=yolo10fps-$g !"
    P="$P queue ! gvafpscounter starting-frame=500 ! fakesink sync=false async=false"
  done
  echo "$P" > "$SCRIPTS_DIR/group_10fps_$g.sh"
  bash "$SCRIPTS_DIR/group_10fps_$g.sh" > "group_10fps_$g.log" 2>&1 &
  pids+=($!); gcount=$((gcount+1)); sleep 1
done

echo "已启动 $gcount 组, 采样 ${RUN_SECONDS}s ..."
sleep "$RUN_SECONDS"

total=0
for ((g=0; g<gcount; g++)); do
  [[ -f "group_10fps_$g.log" ]] || continue
  f=$(grep "FpsCounter(average" "group_10fps_$g.log" | tail -1 | grep -oP "total=\K[0-9.]+" || echo 0)
  total=$(awk "BEGIN{print $total + ${f:-0}}")
done
cleanup

per_stream=$(awk "BEGIN{printf \"%.2f\", $total/$STREAMS}")
pass=$(awk "BEGIN{print ($per_stream >= $PASS_THRESHOLD) ? \"PASS\" : \"FAIL\"}")
echo "=========================================="
echo "结果: 路数=$STREAMS  总吞吐=${total} FPS  每路=${per_stream} FPS  阈值=${PASS_THRESHOLD}  判定=$pass"
echo "=========================================="
