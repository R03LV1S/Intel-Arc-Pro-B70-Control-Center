# Intel Arc Pro B70 (32GB) Direct-Driver Tuning, Workload & SYCL Optimization Guide

This technical guide explains the hardware architecture of the **Intel Arc Pro B70 32GB (`BMG-G31`, PCI ID `8086:e223`)**, how `B70-ControlCenter.ps1` (v2.0 Direct-Driver Edition) communicates directly with **`C:\Windows\System32\ze_loader.dll`** without third-party utilities, when to use each power tier (`150W`, `165W`, `180W`, `230W`), and how to tune **`llama.cpp` (SYCL & Vulkan)**, **LM Studio**, and **WSL2 (`vLLM XPU`)**.

---

## Table of Contents

1. [Hardware Architecture & Why the "70W Power Sag" Happens](#1-hardware-architecture--why-the-70w-power-sag-happens)
2. [How the Zero-Dependency `ze_loader.dll` Direct-Driver Bridge Works](#2-how-the-zero-dependency-ze_loaderdll-direct-driver-bridge-works)
3. [Mandatory Hardware & BIOS Checklist](#3-mandatory-hardware--bios-checklist)
4. [Power Tier Physics: When to Use 150W, 165W, 180W, or 230W](#4-power-tier-physics-when-to-use-150w-165w-180w-or-230w)
5. [Engine-Specific Optimization Guides](#5-engine-specific-optimization-guides)
   - [5.1 `llama.cpp` / `llama-server` (SYCL vs. Vulkan, MTP & DeltaNet Batch Sizing)](#51-llamacpp--llama-server-sycl-vs-vulkan-mtp--deltanet-batch-sizing)
   - [5.2 LM Studio, OpenCode & Desktop GUI Applications](#52-lm-studio-opencode--desktop-gui-applications)
   - [5.3 WSL2 Ubuntu + `vLLM XPU` Hybrid Setup](#53-wsl2-ubuntu--vllm-xpu-hybrid-setup)
6. [VRAM Ceiling Tiers & Hybrid Gated-DeltaNet KV-Cache Math](#6-vram-ceiling-tiers--hybrid-gated-deltanet-kv-cache-math)
7. [Troubleshooting & Level Zero Sysman Diagnostics](#7-troubleshooting--level-zero-sysman-diagnostics)

---

## 1. Hardware Architecture & Why the "70W Power Sag" Happens

The **Intel Arc Pro B70 32GB** is built on the full **Battlemage `BMG-G31`** silicon die:
* **Compute Units:** 32 Xe2-HPG Cores / **256 XMX (Xe Matrix eXtensions) systolic arrays**
* **Memory Subsystem:** 32 GB GDDR6 ECC on a **256-bit bus (608 GB/s bandwidth)**
* **Host Interface:** PCIe Gen 5.0 x16 (~64 GB/s bidirectional bandwidth)

### Compute-Bound Prefill vs. Memory-Bound Decode
Every local LLM turn alternates between two distinct hardware regimes:
1. **Prompt Prefill (`GEMM` — 100% XMX Compute-Bound):** Processing your input prompt multiplies matrices across thousands of tokens in parallel, saturating all 256 XMX engines. The GPU naturally draws `165W–230W`.
2. **Single-Stream Token Decode (`GEMV` — Memory-Bandwidth-Bound):** Generating one token at a time requires reading all `17+ GB` of model weights across the **608 GB/s GDDR6 bus** for every step. Because the XMX units wait microsecond intervals between memory reads, stock workstation firmware misinterprets the workload as idle/light and **drops core clocks and board power down to `60W–85W`**.

Because Intel Graphics Software hides the Performance/Tuning tab on workstation "Arc Pro" cards, users cannot raise the minimum sustained power envelope through the standard GUI.

---

## 2. How the Zero-Dependency `ze_loader.dll` Direct-Driver Bridge Works

Every Intel Arc graphics driver on Windows 11 installs **`C:\Windows\System32\ze_loader.dll`**, which exposes the **Intel Level Zero Sysman (System Management) C API**.

When you launch `B70-ControlCenter.ps1` (v2.0):
1. It sets `$env:ZES_ENABLE_SYSMAN = "1"` in the process environment before loading the driver DLL.
2. It compiles an inline C# class (`IntelLevelZeroSysman`) in memory via PowerShell's native `Add-Type` P/Invoke mechanism—requiring **zero external `.exe` files or third-party installers**.
3. It enumerates the primary discrete GPU power domain (`zesDeviceEnumPowerDomains`) and calls:
   * **`zesPowerGetLimits()`**: Reads the factory sustained limit (`zes_power_sustained_limit_t`) before applying any lock and saves it to `C:\ProgramData\B70PowerLease\b70_direct_lease.json`.
   * **`zesPowerSetLimits()`**: Programs both **`PL1` (Sustained Power in milliwatts)** and **`PL2` (Burst Power in milliwatts, set to `PL1 + 20W` up to `230,000 mW`)** directly into the driver.
   * **`zesPowerGetEnergyCounter()`**: Samples the hardware microjoule (`uJ`) accumulator across a 120 ms window ($\Delta E / \Delta t$) to report real-time GPU power draw in Watts.

---

## 3. Mandatory Hardware & BIOS Checklist

Before tuning power limits, verify these three system settings:

1. **Enable Resizable BAR (ReBAR) & Above 4G Decoding in BIOS:**
   * Without ReBAR, Windows limits PCIe BAR mapping to 256 MB segments, cutting `llama.cpp` and `vLLM` performance by up to 50%.
   * *Verify:* Open **Intel Graphics Software** -> **System** (or GPU-Z) and confirm **Resizable BAR** is **Enabled**.
2. **Disable PCIe Link State Power Management (ASPM) in Windows Power Options:**
   * Go to **Control Panel** -> **Power Options** -> **Change plan settings** -> **Change advanced power settings** -> **PCI Express** -> **Link State Power Management** -> **Off**.
   * This prevents Windows from dropping the PCIe Gen 5 x16 bus into L1 sleep between prompt turns.
3. **Use Intel Graphics Driver `32.0.101.8860` or Newer:**
   * Driver `8860+` includes Battlemage (`BMG-G31`) FlashAttention shader optimizations and Level Zero Sysman stability updates.

---

## 4. Power Tier Physics: When to Use 150W, 165W, 180W, or 230W

Because single-stream token decode is bottlenecked by the **608 GB/s GDDR6 memory bus** while prompt prefill and parallel batching are bottlenecked by **256 XMX compute engines**, each power tier serves a specific workload:

### `[0]` Stock Normal (Unlocked / Factory Baseline)
* **Power Envelope:** `~12W–18W` at desktop idle; `150W` factory default PL1 ceiling.
* **Best For:** Everyday desktop use, web browsing, video playback, gaming, or overnight standby when no AI tasks are active.

### `[1]` 150W — Eco Mode (`PL1 = 150W` / `PL2 = 170W`)
* **Best For:**
  * **Mixture-of-Experts (MoE) Models (`Qwen3-30B-A3B`, `Qwen3.6-35B-A3B`):** MoE architectures only activate ~3B parameters per token. At `150W`, the B70 saturates 100% of the memory bus on 3B active weights (`70–130 tok/s`) with minimal heat and noise.
  * **Small to Medium Dense Models (`1.5B` to `9B`):** Fast coding autocomplete, Whisper STT, and Kokoro TTS.

### `[2]` 165W — Peak Efficiency Mode (`PL1 = 165W` / `PL2 = 185W`)
* **Efficiency:** **`0.148 tok/s per Watt`** (Peak efficiency sweet spot on `BMG-G31`).
* **Best For:**
  * **Daily Single-User Chat & Coding with Dense 9B–27B Models (`Qwen3.5-9B`, `Qwen3.8-27B` with MTP):** Eliminates the 70W workstation clock sag and achieves **~98% of maximum single-stream token decode speed** while running `8–10°C` cooler than 230W.

### `[3]` 180W — Sustained Heavy Mode (`PL1 = 180W` / `PL2 = 200W`)
* **Best For:**
  * **Long-Context Codebase Ingestion (`32K–128K` tokens)** and **Unattended Overnight Autonomous Agents:** Gives the 256 XMX engines `180W` sustained power (with `200W` PL2 burst headroom) so long prefills and multi-hour reasoning loops never clock-throttle, while keeping GDDR6 ECC memory junction temperatures safe (`~65–68°C`) for 8+ hour runs.
  * **Multi-Modal Co-Execution:** Running a 27B LLM + F5-TTS Diffusion Voice Cloning + 3D WebGL telemetry simultaneously.

### `[4]` 230W — Max Hardware Burst Mode (`PL1 = 230W` / `PL2 = 230W`)
* **Best For:**
  * **Massive Prompt Prefills (`64K–262K` tokens):** Prefill is 100% XMX compute-bound (`GEMM`). Unlocking `230W` boosts prefill throughput from `~925 tok/s` to **`~1,115 tok/s` (+20.5% faster Time-To-First-Token)**.
  * **Parallel Code Tournaments & Multi-Agent Batching (`llama-server --parallel 4..8` or `vLLM XPU`):** Evaluating 4 to 8 candidate streams simultaneously reads the `17.1 GB` weights once from VRAM and applies them across 4–8 streams, quadrupling arithmetic intensity and making decode XMX-compute-bound again (**+18–24% aggregate throughput** at `230W`).
  * **Bulk Vector-Store RAG Embedding, Image/Video Diffusion (`Flux.1`, `Wan2.1`), `AutoRound` / `imatrix` Quantization, and Blender Cycles 3D Rendering.**
  * *Note:* For single-stream (`--parallel 1`) token decode, `230W` only adds ~2.9% speed over `180W` because the 608 GB/s memory bus is already full—use `165W` or `180W` for single-stream chatting.

---

## 5. Engine-Specific Optimization Guides

### 5.1 `llama.cpp` / `llama-server` (SYCL vs. Vulkan, MTP & DeltaNet Batch Sizing)

When you lock any profile (`[1]`–`[5]`) in `B70-ControlCenter.ps1`, the script automatically writes these SYCL optimization variables to your **Windows User Environment**:
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
  -m .\models\Qwen3.8-27B-TURBO-Q4_K_S-MTP.gguf `
  -dev SYCL0 -ngl 999 -ncmoe 0 `
  -fa on -ctk q8_0 -ctv q4_1 `
  --spec-type draft-mtp --spec-draft-n-max 2 `
  -b 4096 -ub 1024 -c 65536 `
  --temp 0.65 --repeat-penalty 1.0 `
  --port 8080
```

* **Critical DeltaNet Micro-Batch Rule (`-ub 1024` or `-ub 4096`):** On hybrid Gated-DeltaNet architectures (`Qwen3.5` / `Qwen3.8`), never set physical micro-batch size to `-ub 512` (which can trigger a shader truncation bug in `llama.cpp`). Always use **`-b 4096 -ub 1024`** or **`-b 8192 -ub 4096`**.
* **MAX-MTP Sampler Rules (`--repeat-penalty 1.0` & `--temp <= 1.0`):** On models with 16-bit `MAX` output tensors and `Q8_0` Multi-Token Prediction (MTP) heads, keep `repeat_penalty` at **`1.0`** (disabled) and `temperature` at or below **`1.0`** so 2-token draft acceptance stays above 60%.

---

### 5.2 LM Studio, OpenCode & Desktop GUI Applications

1. Run `B70-ControlCenter.ps1` and lock **`[2] 165W`** (or **`[3] 180W`**) **before** launching your GUI app.
2. Because `B70-ControlCenter.ps1` persists the SYCL Immediate-CommandList flags in your Windows User Environment, any GUI application launched afterward inherits them automatically.
3. In your GUI app settings:
   * Enable **Flash Attention**.
   * Set **K-Cache Quantization** to **`Q8_0`** and **V-Cache Quantization** to **`Q4_1`** (or **`Q8_0`**).
   * Set **Repeat Penalty** to **`1.0`** if running a `MAX-MTP` GGUF.
4. When finished, reopen `B70-ControlCenter.ps1` and press **`[0]`** to reset back to Stock Normal.

---

### 5.3 WSL2 Ubuntu + `vLLM XPU` Hybrid Setup

Inside WSL2 Ubuntu, `/dev/dxg` paravirtualizes GPU compute calls to the Windows host driver, **but Linux tools inside WSL2 cannot modify physical hardware power limits**.
* **How to Run:** Run `B70-ControlCenter.ps1` on your **Windows 11 host** and lock **`[3] 180W`** or **`[4] 230W`**. Because `ze_loader.dll` programs the physical PCIe card's power controller on the Windows host, your WSL2 `vLLM XPU` container immediately receives the full `180W–230W` hardware power envelope.

---

## 6. VRAM Ceiling Tiers & Hybrid Gated-DeltaNet KV-Cache Math

To prevent Windows WDDM from paging VRAM into shared system DDR5 RAM (which causes system-wide stuttering), leave **`1.50 GB to 1.60 GB`** of physical VRAM free for the OS compositor:

| GPU Physical VRAM | Recommended Max Ceiling % | Max Usable AI VRAM | Reserved OS / WDDM Buffer |
| :---: | :---: | :---: | :---: |
| **8 GB** | 80% | **6.40 GB** | 1.60 GB |
| **12 GB** | 85% | **10.20 GB** | 1.80 GB |
| **16 GB** | 90% | **14.40 GB** | 1.60 GB |
| **24 GB** | 90% | **21.60 GB** | 2.40 GB |
| **32 GB (Arc Pro B70)** | **95%** (Interactive) / **90%** (Overnight) | **30.40 GB** / **28.80 GB** | **1.60 GB** / **3.20 GB** |

### Why `Qwen3.5` & `Qwen3.8` Use Half the KV Cache of Older Models
In `Qwen3.5-27B` and `Qwen3.8-27B` (64 layers total), **48 layers are Gated-DeltaNet linear attention layers** whose recurrent state is fixed at **`~150 MB` regardless of context length**. Only **16 layers** (+ 1 MTP layer) use growing KV caches (`4 KV heads`, `head_dim = 256`):
* With `-fa on -ctk q8_0 -ctv q4_1`, the 27B model only consumes **`~25.5 KB per token`** (+ `0.15 GB` fixed state):
  * **32K Context (`32,768`):** `~0.95 GB` KV cache
  * **64K Context (`65,536`):** `~1.75 GB` KV cache
  * **128K Context (`131,072`):** `~3.35 GB` KV cache (Fits with **both** a 9B [`6.55 GB`] and 27B [`17.10 GB`] model co-resident inside the B70's `30.40 GB` 95% ceiling!)
  * **262K Context (`262,144`):** `~6.55 GB` KV cache (Fits with 4.9 GB to spare when the 27B model runs solo in Autonomous Mode!)

---

## 7. Troubleshooting & Level Zero Sysman Diagnostics

* **`DRIVER PL1 LIMIT : Driver N/A` in the Status Header:**
  * **Cause 1:** PowerShell was launched without Administrator privileges (Sysman power domain enumeration requires elevation). Right-click `B70-ControlCenter.ps1` and run as Administrator.
  * **Cause 2:** An Intel integrated GPU (iGPU) was enumerated before the discrete Arc Pro B70. The script automatically scans all Level Zero driver handles for a valid discrete power domain (`zesDeviceEnumPowerDomains`).
* **Resetting After an Unclean System Shutdown:**
  * Hardware power limits programmed via `zesPowerSetLimits()` are held in volatile driver/firmware state and reset on a cold reboot, while the script's state file (`C:\ProgramData\B70PowerLease\b70_direct_lease.json`) and User SYCL environment variables persist on disk. Simply open `B70-ControlCenter.ps1` and press **`[0]`** to synchronize and clear everything back to Stock Normal.
