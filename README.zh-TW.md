# vLLM Docker 針對 DGX Spark（單節點或多節點）優化

此倉庫包含 Docker 設定與啟動腳本，用於在搭配 Ray 的多節點 vLLM 推理叢集上執行。它支援 InfiniBand/RDMA（NCCL）以及自訂環境設定，以提供高效能的部署方式。

雖然此專案最初是為多節點推理而開發，但在單節點環境下同樣適用。

---

## 目錄

- [免責聲明](#免責聲明)
- [快速上手](#快速上手)
- [變更紀錄](#變更紀錄)
- [1. 建置 Docker 映像檔](#1-建置-docker-映像檔)
- [2. 啟動叢集（建議）](#2-啟動叢集-建議)
- [3. 手動執行容器](#3-手動執行容器)
- [4. 使用 `run-cluster-node.sh`（內部）](#4-使用-run-cluster-nodesh-內部)
- [5. 設定細節](#5-設定細節)
- [6. Mods 與 Patch](#6-mods-與-patch)
- [7. 啟動腳本](#7-啟動腳本)
- [8. 使用叢集模式進行推理](#8-使用叢集模式進行推理)
- [9. FastSafeTensors 支援](#9-fastsafetensors-支援)
- [10. 基準測試](#10-基準測試)
- [11. 下載模型](#11-下載模型)

---

## 免責聲明

此倉庫與 NVIDIA 或其子公司無關。這是一個社群貢獻的專案，旨在協助 DGX Spark 使用者在 Spark 叢集或單節點上設定並執行最新版本的 vLLM。

Dockerfile 會從 vLLM 的主分支建置映像檔，若您想指定特定的 vLLM 版本，可使用 `--vllm-ref` 參數。

---

## 快速上手

### 建置

1. 先在本機或 DGX Spark 叢集的主節點（head node）上檢出此專案：

```bash
git clone https://github.com/eugr/spark-vllm-docker.git
cd spark-vllm-docker
```

2. 建置容器（建議使用提供的腳本）：

- 單節點（只有一台 DGX Spark）

```bash
./build-and-copy.sh
```

- 多節點叢集

確保已依照 NVIDIA 的 *Connect Two Sparks Playbook* 設定好密碼免密 SSH，然後執行：

```bash
./build-and-copy.sh -c   # 會自動將映像檔分發至叢集其他節點
```

首次建置大約需要 20~30 分鐘，之後的建置會更快，且會快取預建的 vLLM wheels。

### 執行

#### 單節點

```bash
./launch-cluster.sh --solo exec \
  vllm serve \
  QuantTrio/Qwen3-VL-30B-A3B-Instruct-AWQ \
  --port 8000 --host 0.0.0.0 \
  --gpu-memory-utilization 0.7 \
  --load-format fastsafetensors
```

#### 使用一般 `docker run`

```bash
docker run \
  --privileged \
  --gpus all \
  -it --rm \
  --network host --ipc=host \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  vllm-node \
  bash -c -i "vllm serve \
    QuantTrio/Qwen3-VL-30B-A3B-Instruct-AWQ \
    --port 8000 --host 0.0.0.0 \
    --gpu-memory-utilization 0.7 \
    --load-format fastsafetensors"
```

#### 多節點叢集

1. 先在任一節點下載模型（建議只在一台節點下載），使用 `hf-download.sh` 會自動將模型分發至叢集其他節點。

```bash
./hf-download.sh QuantTrio/MiniMax-M2-AWQ -c --copy-parallel
```

2. 啟動叢集（以下示範使用 `launch-cluster.sh`）：

```bash
./launch-cluster.sh exec vllm serve \
  QuantTrio/MiniMax-M2-AWQ \
  --port 8000 --host 0.0.0.0 \
  --gpu-memory-utilization 0.7 \
  -tp 2 \
  --distributed-executor-backend ray \
  --max-model-len 128000 \
  --load-format fastsafetensors \
  --enable-auto-tool-choice --tool-call-parser minimax_m2 \
  --reasoning-parser minimax_m2_append_think
```

> **注意**：若模型佔用的記憶體超過 0.8 倍的可用 RAM（不含 KV cache），請不要使用 `--load-format fastsafetensors`，以免發生 OOM。

---

## 變更紀錄

- **2026‑02‑18**：`build-and-copy.sh` 會自動下載預建的 FlashInfer wheels，若無法下載則回退至本地建置。`--rebuild-flashinfer` 可強制重新建置。
- **2026‑02‑17**：新增 `--non-privileged` 旗標，支援在不使用 `--privileged` 的情況下執行容器（會自動加上 `--cap-add=IPC_LOCK`、`--shm-size=64g` 等設定）。
- **2026‑02‑16**：加入 `minimax-m2.5-awq` recipe，使用 `./run-recipe.sh minimax-m2.5-awq` 執行。
- **2026‑02‑13**：FlashInfer cubin 快取機制，減少重建時間。
- **2026‑02‑12**：新增 Qwen3‑Coder‑Next‑FP8 mod，解決 Triton allocator、`--enable-prefix-caching` 與 Spark 效能相關的 bug。
- **2026‑02‑11**：`--gpu-arch` 參數可指定目標 GPU 架構（預設 `12.1a`）。
- **2026‑02‑10**：`launch-cluster.sh` 自動掛載 `~/.cache/vllm`、`~/.cache/flashinfer`、`~/.triton` 目錄，提升冷啟動速度（可用 `--no-cache-dirs` 停用）。
- **2025‑12‑24**：加入 `hf-download.sh` 下載模型並平行分發。
- **2025‑12‑23**：新增 `mods/` 目錄，支援自訂 patch 與 mod。
- **2025‑12‑21**：`--pre-tf` 旗標可安裝 Transformers 5.0 以上的 pre‑release 版。
- **2025‑12‑20**：`--use-wheels` 旗標可使用預建的 vLLM wheels，建置時間大幅縮短。
- **2025‑12‑18**：`launch-cluster.sh` 加入 `--non-privileged`、`--mem-limit-gb`、`--shm-size-gb` 等資源限制參數。
- **2025‑12‑15**：`build-and-copy.sh` 新增 `--triton-sha`、`--no-build`、`--gpu-arch` 等選項。
- **2025‑12‑11**：加入 `--apply-vllm-pr` 旗標，可在建置時套用 vLLM PR。
- **2025‑12‑05**：首次加入 `build-and-copy.sh`。

---

## 1. 建置 Docker 映像檔

### 手動建置（已不建議）

因 Dockerfile 較為複雜，請直接使用腳本。

### 使用建置腳本

```bash
./build-and-copy.sh            # 只建置
./build-and-copy.sh -t my-tag   # 指定映像標籤
./build-and-copy.sh -c 192.168.177.12   # 建置並複製至指定節點
./build-and-copy.sh --gpu-arch 12.0f   # 指定 GPU 架構
./build-and-copy.sh --rebuild-vllm   # 強制從原始碼重新建置 vLLM
./build-and-copy.sh --rebuild-flashinfer   # 強制重新建置 FlashInfer
./build-and-copy.sh --no-build --copy-to 192.168.177.12   # 只複製已存在的映像
```

> **重要**：若您使用的是 DGX Spark，建議加上 `--gpu-arch` 以匹配您的 GPU（例如 `12.0f`）。

---

## 2. 啟動叢集（建議）

`launch-cluster.sh` 會自動偵測 InfiniBand、以太網路介面與節點 IP，並以互動模式啟動容器。

```bash
./launch-cluster.sh            # 自動偵測並啟動（單節點或叢集）
./launch-cluster.sh -d        # 背景（daemon）模式
./launch-cluster.sh stop      # 停止容器
./launch-cluster.sh status    # 檢查狀態
```

### 常用旗標

| 旗標 | 說明 |
|------|------|
| `-t <tag>` | 指定 Docker 映像標籤（預設 `vllm-node`） |
| `--solo` | 單節點模式，跳過自動偵測與 Ray 叢集設定 |
| `--non-privileged` | 使用非特權模式（會自動加上 `--cap-add=IPC_LOCK`、`--shm-size=64g`） |
| `--mem-limit-gb <N>` | 設定容器記憶體上限（預設 110） |
| `--shm-size-gb <N>` | 設定共享記憶體大小（預設 64） |
| `--apply-mod <path>` | 套用 `mods/` 目錄下的自訂 patch |
| `--launch-script <script>` | 執行 `examples/` 內的啟動腳本 |

---

## 3. 手動執行容器

```bash
docker run -it --rm \
  --gpus all \
  --net=host \
  --ipc=host \
  --privileged \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  vllm-node bash
```

---

## 4. 使用 `run-cluster-node.sh`（內部）

此腳本用於在容器內部設定環境並啟動 Ray。範例：

```bash
./run-cluster-node.sh \
  --role head \
  --host-ip 192.168.177.11 \
  --eth-if enp1s0f1np1 \
  --ib-if rocep1s0f1,roceP2p0f1
```

---

## 5. 設定細節

- 腳本會自動將環境變數寫入 `~/.bashrc`，方便在新開的終端機中直接使用。
- 若需手動進入容器，可執行 `docker exec -it vllm_node bash`。

---

## 6. Mods 與 Patch

`mods/` 目錄內提供多種預設 mod，例如 `fix-glm-4.7-flash-AWQ`、`fix-qwen3-coder-next`、`fix-Salyut1-GLM-4.7-NVFP4` 等。使用方式：

```bash
./launch-cluster.sh --apply-mod ./mods/fix-glm-4.7-flash-AWQ \
  exec vllm serve <model> [其他參數]
```

若要自行新增 mod，只需在 `mods/` 建立新目錄，放入 `.patch` 檔與 `run.sh`，然後在 `launch-cluster.sh` 加上 `--apply-mod <your-mod>` 即可。

---

## 7. 啟動腳本

`examples/` 目錄提供即用的腳本，例如 `example-vllm-minimax.sh`、`vllm-openai-gpt-oss-120b.sh`、`vllm-glm-4.7-nvfp4.sh`。使用方式：

```bash
./launch-cluster.sh --launch-script example-vllm-minimax.sh
```

---

## 8. 使用叢集模式進行推理

1. 在任一節點下載模型（建議只在一台節點執行 `hf-download.sh`）。
2. 使用 `launch-cluster.sh` 啟動叢集並執行模型，例如：

```bash
./launch-cluster.sh exec vllm serve \
  QuantTrio/MiniMax-M2-AWQ \
  --port 8000 --host 0.0.0.0 \
  --gpu-memory-utilization 0.7 \
  -tp 2 \
  --distributed-executor-backend ray \
  --max-model-len 128000 \
  --load-format fastsafetensors
```

---

## 9. FastSafeTensors 支援

此建置已內建 `fastsafetensors`，可大幅提升模型載入速度。使用方式：在 vLLM 命令中加入 `--load-format fastsafetensors`。

---

## 10. 基準測試

建議使用 `llama-benchy` 進行效能測試：

```bash
git clone https://github.com/eugr/llama-benchy.git
cd llama-benchy
# 依照說明執行基準測試
```

---

## 11. 下載模型

`hf-download.sh` 會自動使用 `uvx` 下載 HuggingFace 模型，並可選擇 `-c` 參數將模型分發至叢集其他節點。

```bash
./hf-download.sh QuantTrio/MiniMax-M2-AWQ          # 只下載本機
./hf-download.sh -c 192.168.177.12 QuantTrio/MiniMax-M2-AWQ   # 下載並分發
```

---

## 常見問題與支援

- **建置時間過長？** 首次建置會下載預建的 FlashInfer wheels，之後會快很多。若網路不佳，可使用 `--rebuild-flashinfer` 強制本地建置。
- **模型載入 OOM？** 請避免在記憶體不足的情況下使用 `--load-format fastsafetensors`，或調整 `--gpu-memory-utilization`。
- **需要使用 NGC 容器？** 使用 `--apply-mod mods/use-ngc-vllm` 旗標即可在叢集上使用 NVIDIA 官方的 vLLM 容器。

---

## 聯絡與貢獻

此專案歡迎 Pull Request，特別是新增模型 recipe、mod 或效能最佳化。若有任何問題，請在 GitHub Issue 中提出。
