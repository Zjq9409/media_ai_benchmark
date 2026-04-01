# Media AI Benchmark on B60

## 1. 启动 Docker 容器

在主机上执行以下脚本启动 DLStreamer 镜像（以 device0 为例）：

```bash
bash run_docker_b60_device0.sh
```

该脚本会将当前目录挂载到容器内的 `/home/dlstreamer/work`，并映射 `/dev/dri/renderD128`（GPU.0）。

## 2. 进入容器

```bash
docker exec -it dl_benchmark_b60_device0 bash
cd /home/dlstreamer/work
```

## 3. 执行基准测试

```bash
bash media_ai_b60.sh
```

该脚本实际调用：

```bash
./tune_local_streams.sh -f ./video/1280x720_25fps.h265 -m ./FP16/ -b 4 -g GPU -n 66 -G 6 -o
```

## 4. tune_local_streams.sh 参数说明

| 参数 | 含义 |
|------|------|
| `-f <file>` | 输入视频文件路径（必填） |
| `-m <model_dir>` | YOLO 模型目录，指定后启用完整推理流水线；不指定则仅解码 |
| `-b <batch_size>` | YOLO 推理的 batch size，默认 1 |
| `-g <device>` | 使用的 GPU 设备 |
| `-n <number>` | 测试的并发流数量；调优模式下为起始流数，Oneshot 模式下为固定流数，默认 30 |
| `-G <groups>` | 将总流数拆分为几组并行运行 |
| `-o` | Oneshot 模式：直接按 `-n` 指定的流数运行一次，不进行自动调优 |
| `-h` | 显示帮助信息 |

**当前命令解读：** 使用 `./video/1280x720_25fps.h265` 作为输入，加载 `./FP16/` 目录下的模型，batch size 为 4，在 GPU.0 上以 66 路并发流、6 个分组运行一次（Oneshot 模式）。
