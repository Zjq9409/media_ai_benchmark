# Media AI Benchmark on B60

**备注：** `export_yolov8.py` 是将 YOLO 模型转换为 OpenVINO 格式的参考脚本，需要时可运行更新模型。

## 1. 启动 Docker 容器

在主机上执行以下脚本启动 DLStreamer 镜像（以 device0 为例）：

```bash
bash run_docker_b60_device0.sh
```

该脚本会自动：
- 检查镜像是否存在，若不存在则自动 pull
- 清理已有的旧容器
- 启动新容器，将当前目录挂载到 `/home/dlstreamer/work`
- 映射 `/dev/dri/renderD128`（GPU.0）

## 2. 进入容器

```bash
docker exec -it dl_benchmark_b60_2026 bash
cd /home/dlstreamer/work
```

## 3. 执行基准测试

在容器内运行以下命令进行多流推理基准测试：

```bash
./tune_local_streams.sh -f ./video/1280x720_25fps.h265 -m ./yolo11n_seg/ -b 1 -g GPU.0 -n 30 -G 6
```

该命令配置说明：
- `-f ./video/1280x720_25fps.h265` - 使用提供的测试视频
- `-m ./yolo11n_seg/` - 使用 yolo11n-seg 分割模型
- `-b 1` - batch size 为 1（单个推理）
- `-g GPU.0` - 使用 GPU.0 设备
- `-n 30` - 30 个并发流
- `-G 6` - 分为 6 组并行执行

执行后输出日志文件：`group_0.log`、`group_1.log`、...、`group_5.log`（各组推理性能）

## 4. 测试模型性能

也可以单独测试模型推理性能，在容器内运行 `perf_test.sh`：

```bash
# 默认测试 yolo11n-seg 模型（GPU 运行 15 秒）
bash perf_test.sh

# 测试 yolov8n-seg 模型
bash perf_test.sh ./models/yolov8n-seg_openvino_model/yolov8n-seg.xml GPU
```

输出 benchmark_app 的性能数据（吞吐量、延迟等）。

**E2E 路数计算说明：**
- benchmark_app 输出的吞吐量（Throughput，单位 FPS）为模型单独推理的最大性能
- 由于视频是 25fps，可支持的 E2E 并发路数 = 模型 FPS / 25
- 例如：若模型 FPS = 1000，则可支持 1000 / 25 = 40 路并发推理
