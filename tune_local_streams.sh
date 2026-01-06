#!/usr/bin/env bash
set -euo pipefail

# Supports both decode-only and full YOLO pipeline modes
# Usage: ./tune_local_streams.sh -f <input_file> [options]
# Options:
#   -f <file>      Input video file (required)
#   -m <model_dir> Model directory for YOLO detection (enables full pipeline)
#   -b <batch_size> Batch size for YOLO detection (default: 1)
#   -n <number>    Number of streams to test (default: 30)
#   -o             Oneshot mode - run specified streams once without tuning
# Examples:
#   Decode pipeline: ./tune_local_streams.sh -f video.mp4 -n 30
#   Full pipeline:   ./tune_local_streams.sh -f video.mp4 -m /path/to/model -b 2 -n 30
#   Oneshot mode:    ./tune_local_streams.sh -f video.mp4 -o -n 50

# Default values
INPUT_FILE=""
START_STREAMS=30
MODEL_FOLDER=""
BATCH_SIZE=1
ONESHOT_MODE=false
GPU_DEVICE="GPU.1"
PASS_THRESHOLD=23.75
FPS_CHECK_INTERVAL=10
STABILIZATION_TIME=5
TEST_TIMEOUT=60
MAX_STREAMS=0

# Help function
show_help() {
    cat << EOF
Combined GPU Stream Tuning Script

USAGE:
    $0 -f <input_file> [options]

OPTIONS:
    -f <file>       Input video file (required)
    -m <model_dir>  Model directory for YOLO detection (enables full pipeline)
    -b <batch_size> Batch size for YOLO detection (default: 1)
    -g <device>     GPU device (GPU.0, GPU.1, GPU.2, GPU.3) (default: GPU.1)
    -o              Oneshot mode - run specified streams once without tuning
    -n <number>     Number of streams to test in oneshot mode, or starting streams for tuning (default: 30)
    -h              Show this help message


EXAMPLES:
    Decode-only mode:
        $0 -f video.mp4 -n 30
        $0 -f video.mp4 -g GPU.0 -n 30

    Full YOLO pipeline:
        $0 -f video.mp4 -m /path/to/model -n 30
        $0 -f video.mp4 -m /path/to/model -b 2 -g GPU.1 -n 30

    Oneshot mode (no tuning):
        $0 -f video.mp4 -o -n 50
        $0 -f video.mp4 -m /path/to/model -g GPU.2 -o -n 100

NOTES:
    - If -m is not specified, runs in decode-only mode
    - If -m is specified, runs full YOLO detection pipeline
    - If -o is specified, runs oneshot mode without tuning
    - GPU.0 uses vah264dec/vah265dec with vapostproc
    - GPU.1 uses varenderD129* with varenderD129postproc
    - GPU.2 uses varenderD130* with varenderD130postproc
    - GPU.3 uses varenderD131* with varenderD131postproc
    - Model directory should contain XML model file and optionally JSON config
EOF
}

# Parse command line arguments
while getopts "f:m:b:g:n:oh" opt; do
    case $opt in
        f)
            INPUT_FILE="$OPTARG"
            ;;
        m)
            MODEL_FOLDER="$OPTARG"
            ;;
        b)
            BATCH_SIZE="$OPTARG"
            ;;
        g)
            GPU_DEVICE="$OPTARG"
            ;;
        n)
            START_STREAMS="$OPTARG"
            ;;
        o)
            ONESHOT_MODE=true
            ;;
        h)
            show_help
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            echo "Use -h for help" >&2
            exit 1
            ;;
    esac
done

shift $((OPTIND-1))

# Validate required parameters
if [[ -z "$INPUT_FILE" ]]; then
    echo "Error: Input file is required. Use -f to specify the input file."
    echo "Use -h for help."
    exit 1
fi
# Determine mode and set NUM_GROUPS
if [[ -n "$MODEL_FOLDER" ]]; then
    MODE="YOLO"
    NUM_GROUPS=1  # YOLO mode uses single group
else
    MODE="DECODE"
    NUM_GROUPS=$(( (START_STREAMS + 59) / 60 ))  # Decode mode uses dynamic groups
fi
PASS_THRESHOLD=23.75
FPS_CHECK_INTERVAL=10
STABILIZATION_TIME=5
TEST_TIMEOUT=60
MAX_STREAMS=0

# Global variables for function returns
CURRENT_FPS_RESULT="0"
AVERAGE_FPS_RESULT="0"
STREAM_TEST_RESULT=0

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: Input file not found: $INPUT_FILE"
    exit 1
fi

# Check if input file has supported extension
INPUT_FILE_LOWER=$(echo "$INPUT_FILE" | tr '[:upper:]' '[:lower:]')
if [[ ! "$INPUT_FILE_LOWER" =~ \.(h265|h264|mp4)$ ]]; then
    echo "Error: Input file must have one of the following extensions: .h265, .h264, .mp4"
    echo "Current file: $INPUT_FILE"
    exit 1
fi

# For MP4 files, check codec compatibility using gst-discoverer-1.0
if [[ "$INPUT_FILE_LOWER" =~ \.mp4$ ]]; then
    echo "Checking MP4 codec compatibility..."
    
    # Check if gst-discoverer-1.0 is available
    if ! command -v gst-discoverer-1.0 &> /dev/null; then
        echo "Error: gst-discoverer-1.0 not found. Please install GStreamer tools."
        exit 1
    fi
    
    # Get codec information
    CODEC_INFO=$(gst-discoverer-1.0 "$INPUT_FILE" 2>/dev/null)
    
    if [[ -z "$CODEC_INFO" ]]; then
        echo "Error: Could not analyze MP4 file: $INPUT_FILE"
        echo "Please ensure the file is a valid video file."
        exit 1
    fi
    
    # Check if codec is H.264 or H.265/HEVC
    if echo "$CODEC_INFO" | grep -q "H\.264"; then
        echo "Detected H.264 codec in MP4 file"
        MP4_CODEC="h264"
    elif echo "$CODEC_INFO" | grep -qE "H\.265|HEVC"; then
        echo "Detected H.265/HEVC codec in MP4 file"
        MP4_CODEC="h265"
    else
        echo "Error: Unsupported video codec in MP4 file: $INPUT_FILE"
        echo "Discovered video streams:"
        echo "$CODEC_INFO" | grep -E "video #[0-9]+:"
        echo "Only H.264 and H.265/HEVC codecs are supported."
        exit 1
    fi
fi

if [[ ! "$START_STREAMS" =~ ^[0-9]+$ ]] || [[ "$START_STREAMS" -lt 1 ]]; then
    echo "Error: START_STREAMS must be a positive integer"
    exit 1
fi

if [[ ! "$BATCH_SIZE" =~ ^[0-9]+$ ]] || [[ "$BATCH_SIZE" -lt 1 ]]; then
    echo "Error: BATCH_SIZE must be a positive integer"
    exit 1
fi

# Validate GPU device
if [[ ! "$GPU_DEVICE" =~ ^GPU\.[0-3]$ ]]; then
    echo "Error: GPU_DEVICE must be GPU.0, GPU.1, GPU.2, or GPU.3"
    echo "Current value: $GPU_DEVICE"
    exit 1
fi

# Validate model folder only if YOLO mode is enabled
if [[ "$MODE" == "YOLO" ]]; then
    if [[ ! -d "$MODEL_FOLDER" ]]; then
        echo "Error: Model folder not found: $MODEL_FOLDER"
        exit 1
    fi

    MODEL_XML=$(find "$MODEL_FOLDER" -maxdepth 1 -name "*.xml" -type f | head -1)
    if [[ -z "$MODEL_XML" ]]; then
        echo "Error: No XML model file found in: $MODEL_FOLDER"
        exit 1
    fi

    MODEL_PROC=$(find "$MODEL_FOLDER" -maxdepth 1 -name "*.json" -type f | head -1)
    if [[ -n "$MODEL_PROC" ]]; then
        echo "Found model-proc file: $MODEL_PROC"
        MODEL_PROC="model-proc=$MODEL_PROC"
    else
        echo "No JSON model-proc file found, will run without model-proc"
        MODEL_PROC=""
    fi

    echo "Using XML model file: $MODEL_XML"
fi

INPUT_FILE=$(realpath "$INPUT_FILE")
SCRIPT_DIR=$(dirname "$0")
GROUP_SCRIPTS_DIR="$SCRIPT_DIR/group_scripts"

echo "=== Combined GPU Stream Tuning ==="
echo "Mode: $MODE"
if [[ "$ONESHOT_MODE" == true ]]; then
    echo "Operation: ONESHOT (no tuning)"
else
    echo "Operation: TUNING"
fi
echo "Input file: $INPUT_FILE"
echo "Starting streams: $START_STREAMS"
echo "GPU device: $GPU_DEVICE"
if [[ "$MODE" == "YOLO" ]]; then
    echo "Model folder: $MODEL_FOLDER"
    echo "Batch size: $BATCH_SIZE"
fi
echo "Number of groups: $NUM_GROUPS"
echo "FPS threshold: $PASS_THRESHOLD"
echo "Test timeout: ${TEST_TIMEOUT}s"
echo "==========================================="

log() {
    local level="$1"
    local message="$2"
    echo "[$level] $(date '+%H:%M:%S') $message"
}

# Initial cleanup - clean up any leftover files from previous runs
initial_cleanup() {
    log "INFO" "Cleaning up leftover files from previous runs..."
    pkill -f "gst-launch-1.0" 2>/dev/null || true
    pkill -f "group_script_" 2>/dev/null || true
    rm -rf "$GROUP_SCRIPTS_DIR" 2>/dev/null || true
    rm -f group_*.log 2>/dev/null || true
    sleep 2
    pkill -9 -f "gst-launch-1.0" 2>/dev/null || true
    pkill -9 -f "group_script_" 2>/dev/null || true
}

# Exit cleanup - only clean up processes, keep files for batch script
cleanup_processes() {
    log "INFO" "Cleaning up processes..."
    pkill -f "gst-launch-1.0" 2>/dev/null || true
    pkill -f "group_script_" 2>/dev/null || true
    sleep 2
    pkill -9 -f "gst-launch-1.0" 2>/dev/null || true
    pkill -9 -f "group_script_" 2>/dev/null || true
}

trap cleanup_processes EXIT

# Perform initial cleanup
initial_cleanup

get_current_fps() {
    local log_file="$1"
    
    if [[ ! -f "$log_file" ]]; then
        CURRENT_FPS_RESULT="0"
        return
    fi
    
    local fps=$(grep "FpsCounter(average" "$log_file" 2>/dev/null | tail -1 | grep -oP 'per-stream=\K[\d.]+' || echo "0")
    CURRENT_FPS_RESULT="$fps"
}

calculate_average_fps() {
    local num_groups="$1"
    local total_fps=0
    local valid_count=0
    
    for i in $(seq 0 $((num_groups - 1))); do
        local log_file="group_${i}.log"
        get_current_fps "$log_file"
        local fps="$CURRENT_FPS_RESULT"
        
        if [[ "$fps" != "0" && -n "$fps" && "$fps" != "0.00" ]]; then
            # Use awk instead of bc for more reliable arithmetic
            total_fps=$(awk "BEGIN {print $total_fps + $fps}")
            valid_count=$((valid_count + 1))
            # log "DEBUG" "Group $i FPS: $fps, Running total: $total_fps, Count: $valid_count"
        fi
    done
    
    if [[ $valid_count -gt 0 ]]; then
        # Use awk for more reliable floating point arithmetic
        local avg=$(awk "BEGIN {printf \"%.2f\", $total_fps / $valid_count}")
        # log "DEBUG" "Average FPS calculation: $total_fps / $valid_count = $avg"
        AVERAGE_FPS_RESULT="$avg"
    else
        # log "DEBUG" "No valid FPS values found"
        AVERAGE_FPS_RESULT="0"
    fi
}

# Determine decoder and postprocessor based on GPU device and codec
# Returns: DECODER_ELEMENT and POSTPROC_ELEMENT
get_decoder_elements() {
    local gpu_device="$1"
    local codec="$2"  # h264 or h265
    
    case "$gpu_device" in
        GPU.0)
            POSTPROC_ELEMENT="vapostproc"
            if [[ "$codec" == "h264" ]]; then
                DECODER_ELEMENT="vah264dec"
            else
                DECODER_ELEMENT="vah265dec"
            fi
            ;;
        GPU.1)
            POSTPROC_ELEMENT="varenderD129postproc"
            if [[ "$codec" == "h264" ]]; then
                DECODER_ELEMENT="varenderD129h264dec"
            else
                DECODER_ELEMENT="varenderD129h265dec"
            fi
            ;;
        GPU.2)
            POSTPROC_ELEMENT="varenderD130postproc"
            if [[ "$codec" == "h264" ]]; then
                DECODER_ELEMENT="varenderD130h264dec"
            else
                DECODER_ELEMENT="varenderD130h265dec"
            fi
            ;;
        GPU.3)
            POSTPROC_ELEMENT="varenderD131postproc"
            if [[ "$codec" == "h264" ]]; then
                DECODER_ELEMENT="varenderD131h264dec"
            else
                DECODER_ELEMENT="varenderD131h265dec"
            fi
            ;;
    esac
}

generate_group_script() {
    local group_id="$1"
    local streams_in_group="$2"
    local script_file="$GROUP_SCRIPTS_DIR/group_script_${group_id}.sh"
    
    # Determine pipeline elements based on file extension
    local demux_element=""
    local parse_element=""
    local codec=""
    
    local file_ext=$(echo "$INPUT_FILE" | tr '[:upper:]' '[:lower:]' | grep -oP '\.[^.]*$')
    
    case "$file_ext" in
        .h265)
            parse_element="h265parse"
            codec="h265"
            ;;
        .h264)
            parse_element="h264parse"
            codec="h264"
            ;;
        .mp4)
            demux_element="qtdemux !"
            if [[ "$MP4_CODEC" == "h264" ]]; then
                parse_element="h264parse"
                codec="h264"
            else
                parse_element="h265parse"
                codec="h265"
            fi
            ;;
        *)
            parse_element="h265parse"
            codec="h265"
            ;;
    esac
    
    # Get decoder and postprocessor elements based on GPU device
    get_decoder_elements "$GPU_DEVICE" "$codec"
    local decode_element="$DECODER_ELEMENT"
    local postproc_element="$POSTPROC_ELEMENT"
    
    # Build the complete pipeline string
    local pipeline="gst-launch-1.0 -e"
    
    for ((j=1; j<=streams_in_group; j++)); do
        pipeline="$pipeline multifilesrc location=\"$INPUT_FILE\" loop=true !"
        if [[ -n "$demux_element" ]]; then
            pipeline="$pipeline $demux_element"
        fi
        pipeline="$pipeline $parse_element ! $decode_element ! $postproc_element ! \"video/x-raw(memory:VAMemory)\" !"
        
        # Add mode-specific pipeline elements
        if [[ "$MODE" == "YOLO" ]]; then
            pipeline="$pipeline gvadetect model=\"$MODEL_XML\" $MODEL_PROC device=$GPU_DEVICE pre-process-backend=va-surface-sharing scale-method=default batch-size=$BATCH_SIZE model-instance-id=yolo-${group_id} !"
            pipeline="$pipeline queue !"
        fi
        
        pipeline="$pipeline gvafpscounter starting-frame=1000 !"
        pipeline="$pipeline fakesink sync=false async=false"
        
        if [[ $j -lt $streams_in_group ]]; then
            pipeline="$pipeline "
        fi
    done
    
    # Write the final script with the complete pipeline
    cat > "$script_file" << EOF
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="group_${group_id}.log"
> "\$LOG_FILE"

$pipeline 2>&1 > "\$LOG_FILE"
EOF

    chmod +x "$script_file"
}

run_stream_test() {
    local total_streams="$1"
    local num_groups=$NUM_GROUPS
    local group_size=$(( (total_streams + num_groups - 1) / num_groups ))
    local group_pids=()
    
    log "INFO" "Testing $total_streams streams in $num_groups groups (group size: $group_size)"
    
    mkdir -p "$GROUP_SCRIPTS_DIR"
    
    for k in $(seq 0 $((num_groups - 1))); do
        local start_stream=$((k * group_size + 1))
        local end_stream=$(( (k + 1) * group_size ))
        
        if [[ $end_stream -gt $total_streams ]]; then
            end_stream=$total_streams
        fi
        
        local streams_in_group=$((end_stream - start_stream + 1))
        
        # Skip empty groups
        if [[ $streams_in_group -le 0 ]]; then
            continue
        fi
        
        generate_group_script "$k" "$streams_in_group"
        
        log "INFO" "Starting group $k with $streams_in_group streams (streams $start_stream-$end_stream)"
        
        "$GROUP_SCRIPTS_DIR/group_script_${k}.sh" &
        local pid=$!
        group_pids+=($pid)
        
        sleep 1
        if ! kill -0 $pid 2>/dev/null; then
            log "ERROR" "Group $k (PID $pid) failed to start or exited immediately"
            log "ERROR" "Check the generated group script at: $GROUP_SCRIPTS_DIR/group_script_${k}.sh"
            log "ERROR" "Check the group log at: group_${k}.log"
            
            # Clean up any running groups before exiting
            for cleanup_pid in "${group_pids[@]}"; do
                kill -TERM $cleanup_pid 2>/dev/null || true
            done
            sleep 2
            for cleanup_pid in "${group_pids[@]}"; do
                kill -KILL $cleanup_pid 2>/dev/null || true
            done
            
            exit 1
        fi
        sleep 1
    done
    
    local actual_groups=${#group_pids[@]}
    log "INFO" "Started $actual_groups groups with total $total_streams streams"
    
    log "INFO" "Waiting ${FPS_CHECK_INTERVAL}s for streams to start..."
    sleep $FPS_CHECK_INTERVAL
    
    log "INFO" "Waiting ${STABILIZATION_TIME}s for FPS to stabilize..."
    sleep $STABILIZATION_TIME
    
    local remaining_time=$((TEST_TIMEOUT - FPS_CHECK_INTERVAL - STABILIZATION_TIME - 5))
    if [[ $remaining_time -gt 0 ]]; then
        log "INFO" "Monitoring FPS for ${remaining_time}s before timeout... (tail -f group_0.log for gst-launch-1.0 logs)"
        sleep $remaining_time
    fi
    calculate_average_fps "$actual_groups"
    local avg_fps="$AVERAGE_FPS_RESULT"
    local fps_pass=$(awk "BEGIN {print ($avg_fps >= $PASS_THRESHOLD) ? 1 : 0}")
    
    log "INFO" "Total streams: $total_streams, Average FPS: $avg_fps, Threshold: $PASS_THRESHOLD, Pass: $fps_pass"
    
    for pid in "${group_pids[@]}"; do
        kill -TERM $pid 2>/dev/null || true
    done
    sleep 3
    for pid in "${group_pids[@]}"; do
        kill -KILL $pid 2>/dev/null || true
    done
    pkill -KILL -f "group_script_" 2>/dev/null || true
    pkill -KILL -f "gst-launch-1.0" 2>/dev/null || true
    
    for pid in "${group_pids[@]}"; do
        wait $pid 2>/dev/null || true
    done
    
    STREAM_TEST_RESULT="$fps_pass"
}

tune_streams() {
    local current_streams=$START_STREAMS
    local max_streams=0
    local max_streams_average_fps=0
    local step_size=5
    
    log "INFO" "Starting stream tuning from $START_STREAMS streams (step size: $step_size)"
    
    while true; do
        run_stream_test "$current_streams"
        local result="$STREAM_TEST_RESULT"
        
        if [[ "$result" -eq 1 ]]; then
            log "INFO" "✓ $current_streams streams passed FPS threshold"
            max_streams=$current_streams
            max_streams_average_fps="$AVERAGE_FPS_RESULT"
            current_streams=$((current_streams + step_size))
        else
            log "INFO" "✗ $current_streams streams failed FPS threshold"
            
            if [[ $step_size -gt 1 ]]; then
                step_size=1
                current_streams=$((max_streams + step_size))
                log "INFO" "Reducing step size to $step_size, trying $current_streams streams"
            else
                break
            fi
        fi
        
        if [[ $current_streams -gt 1000 ]]; then
            log "WARNING" "Reached safety limit of 1000 streams, stopping"
            break
        fi
    done

    MAX_STREAMS=$max_streams
    MAX_STREAMS_AVERAGE_FPS=$max_streams_average_fps
}

# Main execution logic
if [[ "$ONESHOT_MODE" == true ]]; then
    log "INFO" "Running in oneshot mode with $START_STREAMS streams"
    run_stream_test "$START_STREAMS"
    
    # Set results for oneshot mode
    MAX_STREAMS=$START_STREAMS
    # Capture the FPS result from the test
    oneshot_fps="$AVERAGE_FPS_RESULT"
    MAX_STREAMS_AVERAGE_FPS="$oneshot_fps"
    
    test_result="$STREAM_TEST_RESULT"
    if [[ "$test_result" -eq 1 ]]; then
        log "INFO" "✓ Oneshot test with $START_STREAMS streams passed FPS threshold"
    else
        log "INFO" "✗ Oneshot test with $START_STREAMS streams failed FPS threshold"
    fi
else
    tune_streams
fi

echo ""
echo "========================================="
echo "Local File Stream Tuning Results:"
echo "========================================="
echo "Input file: $INPUT_FILE"
echo "GPU device: $GPU_DEVICE"
echo "Starting streams: $START_STREAMS"
echo "Number of groups: $NUM_GROUPS"
echo "Optimal streams: $MAX_STREAMS"
echo "Average FPS at optimal streams: $MAX_STREAMS_AVERAGE_FPS"
echo "FPS threshold: $PASS_THRESHOLD"
echo "This is the maximum number of streams maintaining FPS >= $PASS_THRESHOLD"
echo "========================================="
