# Serverless DNN Inference on K3s and Knative

## 1. 项目简介

本项目在单节点 K3s 和 Knative Serving 平台上部署基于 PyTorch 与 FastAPI 的 ResNet18 图像分类推理服务，用于验证 Serverless 模型推理中的以下功能：

* 普通 Kubernetes 模型服务部署；
* Knative Service 部署；
* 空闲缩容至零；
* 从零冷启动；
* 基于并发请求的横向扩容；
* 负载结束后的自动缩容；
* 模型加载、预热与推理时延采集；
* Pod 副本变化过程记录。

当前版本首先使用 CPU 版 ResNet18 验证系统链路，后续将扩展至 GPU DNN 推理和大模型推理服务。

## 2. 系统环境

* Operating System: Ubuntu 20.04
* Kubernetes Distribution: K3s
* Serverless Platform: Knative Serving
* Ingress: Kourier
* Model: ResNet18
* Framework: PyTorch 2.4.0
* API Framework: FastAPI
* Container Runtime: containerd
* Image Architecture: linux/amd64

## 3. 项目结构

```text
dnn-resnet18-knative/
├── app/
│   └── main.py
├── k8s/
│   └── deployment-cpu.yaml
├── knative/
│   └── service-cpu.yaml
├── scripts/
│   ├── run_dnn_experiments.sh
│   └── load_test.py
├── results/
├── Dockerfile
├── requirements-app.txt
└── README.md
```

## 4. 推理接口

服务提供以下接口：

```text
GET  /healthz
GET  /readyz
GET  /metadata
GET  /infer/synthetic
POST /predict
```

其中：

* `/healthz`：检查 HTTP 服务是否运行；
* `/readyz`：检查模型是否加载完成；
* `/metadata`：返回模型加载、预热、运行设备等信息；
* `/infer/synthetic`：使用合成张量执行 ResNet18 前向推理；
* `/predict`：上传真实图片并返回 ImageNet Top-5 分类结果。

## 5. 镜像信息

镜像名称：

```text
local.registry/serverless-dnn-resnet18:cpu-v1
```

检查镜像是否已导入 K3s：

```bash
sudo k3s ctr \
  -n k8s.io \
  images list -q |
  grep -Fx \
  'local.registry/serverless-dnn-resnet18:cpu-v1'
```

## 6. 普通 Kubernetes 部署

部署：

```bash
sudo k3s kubectl apply \
  -f k8s/deployment-cpu.yaml
```

等待就绪：

```bash
sudo k3s kubectl rollout status \
  deployment/dnn-resnet18-cpu \
  --timeout=300s
```

查看 Pod：

```bash
sudo k3s kubectl get pods \
  -l app=dnn-resnet18-cpu \
  -o wide
```

删除：

```bash
sudo k3s kubectl delete \
  -f k8s/deployment-cpu.yaml
```

## 7. Knative Service 部署

确保 Knative 跳过本地镜像仓库的 Tag 解析：

```bash
sudo k3s kubectl get configmap \
  config-deployment \
  -n knative-serving \
  -o jsonpath='{.data.registries-skipping-tag-resolving}' \
  && echo
```

输出应包含：

```text
local.registry
```

部署 Knative Service：

```bash
sudo k3s kubectl apply \
  -f knative/service-cpu.yaml
```

等待服务就绪：

```bash
sudo k3s kubectl wait \
  --for=condition=Ready \
  --timeout=300s \
  ksvc/dnn-resnet18-cpu
```

查看服务：

```bash
sudo k3s kubectl get ksvc \
  dnn-resnet18-cpu
```

获取 URL：

```bash
URL="$(
  sudo k3s kubectl get ksvc \
    dnn-resnet18-cpu \
    -o jsonpath='{.status.url}'
)"

echo "$URL"
```

测试推理：

```bash
curl -sS \
  "$URL/infer/synthetic?repeat=1" |
  python3 -m json.tool
```

## 8. 自动实验

运行自动实验：

```bash
cd /srv/serverless-llm/experiments/dnn-resnet18-knative

REQUESTS=20 \
CONCURRENCY=10 \
REPEAT=5 \
bash scripts/run_dnn_experiments.sh
```

参数说明：

```text
REQUESTS
总请求数量。

CONCURRENCY
最大并发请求数量。

REPEAT
每个请求执行的 ResNet18 前向计算次数。
```

推荐基础功能验证参数：

```bash
REQUESTS=20 \
CONCURRENCY=10 \
REPEAT=5 \
bash scripts/run_dnn_experiments.sh
```

推荐轻负载参数：

```bash
REQUESTS=10 \
CONCURRENCY=2 \
REPEAT=1 \
bash scripts/run_dnn_experiments.sh
```

## 9. 自动实验流程

脚本自动执行：

```text
等待服务缩容到零
→ 发送冷启动请求
→ 保存冷启动指标
→ 执行热请求
→ 发送并发负载
→ 记录副本数量变化
→ 等待服务重新缩容到零
→ 生成实验汇总
```

## 10. 实验结果

每次实验会创建一个带时间戳的目录：

```text
results/dnn-resnet18-cpu-YYYYMMDD-HHMMSS/
```

主要文件：

```text
summary.md
summary.json
cold-curl-metrics.txt
cold-response.json
metadata-after-cold.json
warm-metrics.csv
autoscale-load-result.txt
replica-timeline.csv
run.log
events.txt
```

查看最新一次实验：

```bash
LATEST_RESULT="$(
  find results \
    -mindepth 1 \
    -maxdepth 1 \
    -type d |
  sort |
  tail -n 1
)"

cat "$LATEST_RESULT/summary.md"
```

查看并发扩容结果：

```bash
cat "$LATEST_RESULT/autoscale-load-result.txt"
```

查看副本变化：

```bash
column -s, -t \
  "$LATEST_RESULT/replica-timeline.csv" |
  less -S
```

## 11. 扩缩容配置

Knative Service 当前配置：

```yaml
autoscaling.knative.dev/metric: concurrency
autoscaling.knative.dev/target: "1"
autoscaling.knative.dev/min-scale: "0"
autoscaling.knative.dev/max-scale: "4"
```

并设置：

```yaml
containerConcurrency: 1
```

含义：

* 无请求时允许缩容到零；
* 每个 Pod 同时处理一个请求；
* 每个副本的目标并发数为 1；
* 最大扩容到 4 个 Pod。

## 12. 当前验证结果

当前 CPU 实验已验证：

```text
无请求时：4 → 2 → 0
冷请求到达：0 → 1
并发请求到达：1 → 4
负载结束：4 → 2 → 0
```

一次代表性结果：

```text
Cold-start total time: 7.415490 s
Warm request mean time: 0.083380 s
Peak observed pods: 4
Requests: 20
Successes: 20
Failures: 0
Returned to zero: True
```

## 13. 后续计划

后续工作包括：

1. 部署 CUDA 版 ResNet18；
2. 验证 NVIDIA Device Plugin 与 GPU 调度；
3. 记录 CUDA 初始化时间；
4. 记录 GPU 显存加载与释放；
5. 比较 CPU 与 GPU 冷启动；
6. 将相同实验方法迁移至 SGLang 或 vLLM；
7. 测试大模型权重加载、TTFT、TPOT 和显存释放；
8. 研究 Serverless LLM 的保活、分阶段激活与分层资源释放机制。
