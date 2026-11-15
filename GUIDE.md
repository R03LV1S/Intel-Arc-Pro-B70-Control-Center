# Intel Arc Pro B70 (32GB) Direct-Driver & Auto-Pilot Technical Guide (v2.2)

This technical guide explains the hardware physics of the **Intel Arc Pro B70 32GB (`BMG-G31`, PCI ID `8086:e223`)**, how `B70-ControlCenter.ps1` (v2.2) communicates directly with **`C:\Windows\System32\ze_loader.dll`** with zero third-party tools, how the **Universal Telemetry Auto-Pilot** distinguishes compute-bound prompt prefills from memory-bound token decode, and how to tune **`llama.cpp` (SYCL & Vulkan)**, **LM Studio**, **OpenCode**, **Ollama**, and **WSL2 (`vLLM XPU`)**.

---

## Table of Contents

1. [Hardware Architecture & Why the "70W Power Sag" Happens](#1-hardware-architecture--why-the-70w-power-sag-happens)
2. [How the Zero-Dependency `ze_loader.dll` Direct-Driver Bridge Works](#2-how-the-zero-dependency-ze_loaderdll-direct-driver-bridge-works)
3. [How the v2.2 Telemetry Auto-Pilot Scales 150W ↔ 165W ↔ 180W ↔ 230W Automatically](#3-how-the-v22-telemetry-auto-pilot-scales-150w--165w--180w--230w-automatically)
4. [Static Power Tier Physics: When to Lock 150W, 165W, 180W, or 230W Manually](#4-static-power-tier-physics-when-to-lock-150w-165w-180w-or-230w-manually)
5. [Mandatory Hardware & BIOS Checklist](#5-mandatory-hardware--bios-checklist)
6. [Engine-Specific Optimization Guides](#6-engine-specific-optimization-guides)
   - [6.1 `llama.cpp` / `llama-server` (SYCL vs. Vulkan, MTP & DeltaNet Batch Sizing)](#61-llamacpp--llama-server-sycl-vs-vulkan-mtp--deltanet-batch-sizing)
   - [6.2 LM Studio, OpenCode & Desktop GUI Applications](#62-lm-studio-opencode--desktop-gui-applications)
   - [6.3 WSL2 Ubuntu + `vLLM XPU` Setup](#63-wsl2-ubuntu--vllm-xpu-setup)
7. [Safe VRAM Allocation & KV-Cache Memory Planning on 32GB GPUs](#7-safe-vram-allocation--kv-cache-memory-planning-on-32gb-gpus)
8. [Troubleshooting & Level Zero Sysman Diagnostics](#8-troubleshooting--level-zero-sysman-diagnostics)

---

## 1. Hardware Architecture & Why the "70W Power Sag" Happens

The **Intel Arc Pro B70 32GB** is built on the full **Battlemage `BMG-G31`** silicon die:
* **Compute Units:** 32 Xe2-HPG Cores / **256 XMX (Xe Matrix eXtensions) systolic arrays**
* **Memory Subsystem:** 32 GB GDDR6 ECC on a **256-bit bus (608 GB/s bandwidth)**
* **Host Interface:** PCIe Gen 5.0 x16 (~64 GB/s bidirectional bandwidth)

### Compute-Bound Prefill vs. Memory-Bound Decode
Every local LLM turn alternates between two fundamentally different hardware regimes:
1. **Prompt Prefill & Parallel Batching (`GEMM` — 100% XMX Compute-Bound):** Processing an input prompt (`8K–262K` tokens) or evaluating 4–8 parallel streams multiplies dense matrices across thousands of tokens simultaneously, saturating all 256 XMX systolic arrays. Here, raw core boost clocks and power headroom (`180W–230W`) directly dictate speed.
2. **Single-Stream Token Decode (`GEMV` — Memory-Bandwidth-Bound):** Generating one token at a time requires streaming all `15–20 GB` of model weights across the **608 GB/s GDDR6 bus** for every step. Because the XMX units wait microsecond intervals between memory reads, stock workstation firmware misinterprets the workload as light and **drops core clocks and board power down to `60W–85W`**, costing 15% to 35% of your decode speed.

---

## 2. How the Zero-Dependency `ze_loader.dll` Direct-Driver Bridge Works

Every Intel Arc graphics driver on Windows 11 installs **`C:\Windows\System32\ze_loader.dll`**, which exposes the **Intel Level Zero Sysman (System Management) C API**.

When you launch `B70-ControlCenter.ps1` (v2.2):
1. It sets `$env:ZES_ENABLE_SYSMAN = "1"` in the process environment before loading the driver DLL.
2. It compiles an inline C# class (`IntelLevelZeroSysman`) in memory via PowerShell's native `Add-Type` P/Invoke mechanism—requiring **zero external `.exe` files or third-party installers**.
3. It caches the primary discrete GPU power domain handle (`zesDeviceEnumPowerDomains`) and calls:
   * **`zesPowerGetLimits()`**: Reads the factory sustained limit (`zes_power_sustained_limit_t`) before applying any lock and saves it to `C:\ProgramData\B70PowerLease\b70_direct_lease.json`.
   * **`zesPowerSetLimits()`**: Programs both **`PL1` (Sustained Power in milliwatts)** and **`PL2` (Short-Term Burst Power in milliwatts)** directly into the driver.
   * **`zesPowerGetEnergyCounter()`**: Samples the hardware microjoule (`uJ`) accumulator across a 120–250 ms window ($\Delta E / \Delta t$) to measure real-time board power draw in Watts with sub-watt precision.

---

## 3. How the v2.2 Telemetry Auto-Pilot Scales 150W ↔ 165W ↔ 180W ↔ 230W Automatically

Options **`[6]` (Live Console Auto-Pilot)** and **`[7]` (Background Auto-Pilot Daemon)** implement a 4-tier hardware telemetry state machine that works with **any** application (LM Studio, OpenCode, Ollama, ComfyUI, or WSL2 containers) without needing software hooks inside those apps.

```text
====================================================================================================
      v2.2 UNIVERSAL TELEMETRY AUTO-PILOT STATE MACHINE (250ms Microjoule Sampling Loop)
====================================================================================================

  [ TIER 0: ECO STANDBY (PL1 = 150W / PL2 = 185W) ]
       │
       │  (GPU activity detected: LiveDraw >= 36W)
       ▼
  [ TIER 1: ACTIVE DECODE LOCK (PL1 = 165W / PL2 = 210W) ]  <── Eliminates the 70W Workstation Sag
       │                                      ▲
       │ (XMX Surge: LiveDraw >= 156W         │ (Prefill done: LiveDraw drops below 178W for 1.25s
       │  for 500ms -> Prefill/Batch started) │  as workload becomes GDDR6 memory-bound again)
       ▼                                      │
  [ TIER 2/3: SUSTAINED / MAX BURST (PL1 = 180W -> PL1 = 230W / PL2 = 230W) ]
       • Holds 230W while XMX arrays actively draw >= 178W (up to 90s thermal safety cap)
====================================================================================================
```

### Why the Automatic Step-Down from `230W` to `165W` Works Physically
1. **Detecting the Prefill / Batch Surge (`165W` $\to$ `230W`):**
   While in `165W` Decode Lock (`PL1 = 165W / PL2 = 210W`), submitting a large prompt or batch job causes all 256 XMX engines to fire at 100%, pushing live power draw past `156W` into the `210W PL2` burst window. Seeing two consecutive 250 ms samples above `156W` immediately promotes the card to **`230W Max Burst` (`PL1 = 230W / PL2 = 230W`)**.
2. **Detecting the Transition to Token Decode (`230W` $\to$ `165W`):**
   Even when the hardware limit is unlocked at `230W`, **single-stream token decode cannot physically draw 230W** because the XMX cores spend ~80% of each cycle waiting on the **608 GB/s GDDR6 memory bus**. The instant prompt prefill finishes and token-by-token streaming begins, actual board power draw naturally drops from `195W–228W` down to **`145W–172W`**.
3. **Clean Hysteresis & Thermal Guardrail:**
   Once the Auto-Pilot sees 5 consecutive samples (`1.25 seconds`) below `178W`, it knows the compute-bound prefill phase is complete and steps `PL1` back down to **`165W Peak Efficiency`** (`PL1 = 165W / PL2 = 210W`). If you run a continuous multi-minute 3D render or quantization job that stays above `178W` non-stop, a **90-second thermal timer** smoothly steps the lock down to **`180W Sustained`** (`PL1 = 180W / PL2 = 220W`) to protect GDDR6 ECC memory junction temperatures.

---

## 4. Static Power Tier Physics: When to Lock 150W, 165W, 180W, or 230W Manually

If you prefer a fixed static lock (`[1]`–`[5]`) instead of the dynamic Auto-Pilot (`[6]`/`[7]`):

* **`[1]` 150W Eco (`PL1 = 150W / PL2 = 185W`):** Best for **MoE models (`30B-A3B`, `35B-A3B`)** and `1.7B–9B` dense models. MoE models only activate ~3B parameters per token, saturating the memory bus at 150W with minimal heat.
* **`[2]` 165W Peak Efficiency (`PL1 = 165W / PL2 = 210W`):** Best static lock for **daily single-user 9B–27B interactive chat & coding** (`0.148 tok/s/W`). Includes a `210W PL2` burst window so short prompt prefills still get hardware turbo headroom.
* **`[3]` 180W Sustained Heavy (`PL1 = 180W / PL2 = 220W`):** Best static lock for **continuous multi-hour compute sessions**, `32K–128K` codebase ingestion, and running multiple models concurrently.
* **`[4]` 230W Max Hardware Burst (`PL1 = 230W / PL2 = 230W`):** Best for **`64K–262K` prompt prefills (+20.5% faster TTFT)**, **multi-stream parallel batching (`--parallel 4..8`, +18–24% throughput)**, **bulk embedding/RAG indexing**, **Flux/Wan image/video diffusion**, and **Blender Cycles rendering**.

---

## 5. Mandatory Hardware & BIOS Checklist

1. **Enable Resizable BAR (ReBAR) & Above 4G Decoding in BIOS:**
   * Without ReBAR, Windows limits PCIe BAR mapping to 256 MB segments, cutting `llama.cpp` and `vLLM` performance by up to 50%.
   * *Verify:* Open **Intel Graphics Software** -> **System** (or GPU-Z) and confirm **Resizable BAR** is **Enabled**.
2. **Disable PCIe Link State Power Management (ASPM) in Windows Power Options:**
   * Go to **Control Panel** -> **Power Options** -> **Change plan settings** -> **Change advanced power settings** -> **PCI Express** -> **Link State Power Management** -> **Off**.
3. **Use Intel Graphics Driver `32.0.101.8860` or Newer:**
   * Driver `8860+` includes Battlemage (`BMG-G31`) FlashAttention shader optimizations and Level Zero Sysman stability updates.

---

## 6. Engine-Specific Optimization Guides

### 6.1 `llama.cpp` / `llama-server` (SYCL vs. Vulkan, MTP & DeltaNet Batch Sizing)

When you activate any static profile (`[1]`–`[5]`) or Auto-Pilot mode (`[6]`–`[7]`), `B70-ControlCenter.ps1` automatically writes these SYCL optimization variables to your **Windows User Environment**:
```text
ONEAPI_DEVICE_SELECTOR                        = level_zero:0
SYCL_CACHE_PERSISTENT                         = 0
SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS = 1
UR_L0_USE_IMMEDIATE_COMMANDLISTS              = 1
ZES_ENABLE_SYSMAN                             = 1
```

#### Optimal `llama-server` Command for `Qwen3.5` / `Qwen3.8` Hybrid DeltaNet Models
```powershell
llama-server `
  -m .\models\your-model-Q4_K_S-MTP.gguf `
  -dev SYCL0 -ngl 999 -ncmoe 0 `
  -fa on -ctk q8_0 -ctv q4_1 `
  --spec-type draft-mtp --spec-draft-n-max 2 `
  -b 4096 -ub 1024 -c 65536 `
  --temp 0.65 --repeat-penalty 1.0 `
  --port 8080
```

* **Critical DeltaNet Micro-Batch Rule (`-ub 1024` or `-ub 4096`):** On hybrid Gated-DeltaNet architectures (`Qwen3.5` / `Qwen3.8`), never set physical micro-batch size to `-ub 512` (which triggers a shader truncation bug in `llama.cpp`). Always use **`-b 4096 -ub 1024`** or **`-b 8192 -ub 4096`**.
* **MAX-MTP Sampler Rules (`--repeat-penalty 1.0` & `--temp <= 1.0`):** On models with 16-bit `MAX` output tensors and `Q8_0` Multi-Token Prediction (MTP) heads, keep `repeat_penalty` at **`1.0`** (disabled) and `temperature` at or below **`1.0`** so 2-token draft acceptance stays above 60%.

---

### 6.2 LM Studio, OpenCode & Desktop GUI Applications

1. Open `B70-ControlCenter.ps1` and press **`[7]` (`Start Background Auto-Pilot Daemon`)**, then press **`[Q]`** to close the terminal.
2. Launch **LM Studio**, **OpenCode**, or your preferred GUI app—it automatically inherits the User SYCL environment variables, while the background daemon scales the B70 between `150W` (idle), `230W` (prompt prefill), and `165W` (token streaming).
3. In your GUI app settings:
   * Enable **Flash Attention**.
   * Set **K-Cache Quantization** to **`Q8_0`** and **V-Cache Quantization** to **`Q4_1`** (or **`Q8_0`**).
   * Set **Repeat Penalty** to **`1.0`** if running a `MAX-MTP` GGUF.
4. When finished for the day, reopen `B70-ControlCenter.ps1` and press **`[0]`** to stop the background daemon and reset back to Stock Normal.

---

### 6.3 WSL2 Ubuntu + `vLLM XPU` Setup

Inside WSL2 Ubuntu, `/dev/dxg` paravirtualizes GPU compute calls to the Windows host driver, **but Linux tools inside WSL2 cannot modify physical hardware power limits**.
* **How to Run:** Start the **Background Auto-Pilot Daemon (`[7]`)** in `B70-ControlCenter.ps1` on your **Windows 11 host**. Because `ze_loader.dll` samples the physical PCIe card's microjoule counters on the Windows host, it detects compute surges from your WSL2 Ubuntu `vLLM XPU` container automatically and scales the physical card between `150W`, `165W`, `180W`, and `230W` in real time.

---

## 7. Safe VRAM Allocation & KV-Cache Memory Planning on 32GB GPUs

To prevent Windows WDDM from paging VRAM into shared system DDR5 RAM (which causes desktop stuttering and severe inference slowdowns), always reserve **`1.60 GB to 2.40 GB`** of physical VRAM for the Windows desktop compositor:

| GPU Physical VRAM | Recommended Max VRAM Allocation % | Max Usable AI VRAM | Reserved OS / WDDM Safety Buffer |
| :---: | :---: | :---: | :---: |
| **8 GB** | 80% | **6.40 GB** | 1.60 GB |
| **12 GB** | 85% | **10.20 GB** | 1.80 GB |
| **16 GB** | 90% | **14.40 GB** | 1.60 GB |
| **24 GB** | 90% | **21.60 GB** | 2.40 GB |
| **32 GB (Arc Pro B70)** | **95%** | **30.40 GB** | **1.60 GB** |

### Why `Qwen3.5` & `Qwen3.8` Use Half the KV Cache of Older Models
In `Qwen3.5-27B` and `Qwen3.8-27B` (64 layers total), **48 layers are Gated-DeltaNet linear attention layers** whose recurrent state is fixed at **`~150 MB` regardless of context length**. Only **16 layers** (+ 1 MTP layer) use growing KV caches (`4 KV heads`, `head_dim = 256`):
* With `-fa on -ctk q8_0 -ctv q4_1`, a 27B model (`~17.10 GB` weights in `Q4_K_S`) consumes only **`~25.5 KB per token`** (+ `0.15 GB` fixed state):
  * **32K Context (`32,768`):** `~0.95 GB` KV cache (`~18.05 GB` total VRAM)
  * **64K Context (`65,536`):** `~1.75 GB` KV cache (`~18.85 GB` total VRAM)
  * **128K Context (`131,072`):** `~3.35 GB` KV cache (`~20.45 GB` total VRAM)
  * **262K Context (`262,144`):** `~6.55 GB` KV cache (`~23.65 GB` total VRAM — fits easily inside the B70's `30.40 GB` usable ceiling!)

---

## 8. Troubleshooting & Level Zero Sysman Diagnostics

* **`DRIVER PL1 READBACK : Driver N/A` in the Status Header:**
  * **Cause:** PowerShell was launched without Administrator privileges. Right-click `B70-ControlCenter.ps1` and select **Run with PowerShell** so the automatic UAC elevation prompt runs.
* **How to Verify If the Background Auto-Pilot Daemon (`[7]`) Is Running:**
  * Open `B70-ControlCenter.ps1`. If the background daemon is running, the top banner displays in magenta:
    `ACTIVE PROFILE : [AUTO-PILOT DAEMON PID xxxx] SMART AUTO-PILOT [...]`
  * Pressing **`[0]`** (`Reset to Stock Normal`) or switching to any static profile (`[1]`–`[5]`) automatically terminates the background daemon PID before applying your new selection.
