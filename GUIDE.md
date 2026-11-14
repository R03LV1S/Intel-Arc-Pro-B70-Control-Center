# Intel Arc Pro B70 (32GB) Tuning, Workload & SYCL Optimization Guide

This guide explains the hardware physics behind the **Intel Arc Pro B70 32GB (`BMG-G31`, PCI ID `8086:e223`)**, how to eliminate the workstation driver's **"70W Power Sag"** during local AI inference, which power tier to choose for your specific workload, and how to configure **`llama.cpp` (SYCL & Vulkan)**, **LM Studio**, **OpenVINO**, and **WSL2 (`vLLM XPU`)** for maximum token throughput.

---

## Table of Contents

1. [Understanding the Arc Pro B70 Hardware & The "70W Power Sag"](#1-understanding-the-arc-pro-b70-hardware--the-70w-power-sag)
2. [Mandatory Hardware & BIOS Checklist (Before You Tune)](#2-mandatory-hardware--bios-checklist-before-you-tune)
3. [Power Profile Decision Matrix: When to Use 150W, 165W, 180W, or 230W](#3-power-profile-decision-matrix-when-to-use-150w-165w-180w-or-230w)
4. [Using `B70-ControlCenter.ps1` (Interactive, Persistent & Crash-Safe Modes)](#4-using-b70-controlcenterps1-interactive-persistent--crash-safe-modes)
5. [Engine-Specific Optimization Guides](#5-engine-specific-optimization-guides)
   - [5.1 `llama.cpp` / `llama-server` (SYCL vs. Vulkan & MTP Speculative Decoding)](#51-llamacpp--llama-server-sycl-vs-vulkan--mtp-speculative-decoding)
   - [5.2 LM Studio & Desktop GUI Applications](#52-lm-studio--desktop-gui-applications)
   - [5.3 WSL2 Ubuntu + `vLLM XPU` Hybrid Setup](#53-wsl2-ubuntu--vllm-xpu-hybrid-setup)
6. [Quantization Selection Guide for 32GB VRAM](#6-quantization-selection-guide-for-32gb-vram)
7. [Safety Architecture: How State Persistence & Crash Recovery Work](#7-safety-architecture-how-state-persistence--crash-recovery-work)
8. [Troubleshooting & Common IGCL Error Codes](#8-troubleshooting--common-igcl-error-codes)

---

## 1. Understanding the Arc Pro B70 Hardware & The "70W Power Sag"

The **Intel Arc Pro B70 32GB** is built on the full **Battlemage `BMG-G31`** silicon die:
* **Compute Units:** 32 Xe2-HPG Cores / **256 XMX (Xe Matrix eXtensions) systolic engines**
* **Memory Subsystem:** 32 GB GDDR6 (with ECC support) on a **256-bit bus (608 GB/s bandwidth)**
* **Host Interface:** PCIe Gen 5.0 x16 (~64 GB/s bidirectional bandwidth)

### Why Workstation Cards Sag During AI Inference
Unlike consumer Intel Arc cards (such as the Arc B580 or A770), **Intel Graphics Software hides the Performance & Power Tuning tab on workstation "Arc Pro" cards**.

LLM inference has two distinct hardware phases:
1. **Prompt Prefill (Compute-Bound):** All 256 XMX matrix engines fire simultaneously to process your input context. The GPU naturally boosts to `150W–180W+`.
2. **Token Decode (Memory-Bandwidth-Bound):** As the model generates one token (or 2–3 MTP draft tokens) at a time, the XMX compute units spend brief microsecond intervals waiting for weight tensors to stream across the 608 GB/s GDDR6 bus.

Because XMX utilization pulses between memory reads during token decode, the stock B70 workstation firmware misinterprets the workload as "light" and **downclocks the GPU core, dropping board power from `165W` down to `60W–85W`**. This clock sag reduces single-stream token generation speed by **15% to 35%**.

### The Two-Part Fix
`B70-ControlCenter.ps1` solves this bottleneck by combining:
1. **IGCL Hardware Power & Fan Locking:** Uses Intel's native Graphics Control Library (`ControlLib.dll` via `arc-gpu`) to lock the sustained package power ceiling (`150W` / `165W` / `180W` / `230W`) and apply a proactive thermal fan curve before thermal throttling can occur.
2. **Level Zero Immediate CommandLists (Intel's "Redline" Path):** Sets `UR_L0_USE_IMMEDIATE_COMMANDLISTS=1` and `SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=1` in your Windows User Environment so SYCL kernels dispatch directly to the B70 hardware doorbells without OS command-queue batching lag, while setting `SYCL_CACHE_PERSISTENT=0` to prevent a known `ggml-sycl` dynamic teardown crash.

---

## 2. Mandatory Hardware & BIOS Checklist (Before You Tune)

Before running benchmarks, verify these four system settings—missing #1 alone can cut your speed in half:

1. **Enable Resizable BAR (ReBAR) & Above 4G Decoding in BIOS:**
   * Intel Arc GPUs **require** Resizable BAR to map the full 32 GB VRAM aperture over PCIe. Without ReBAR, `llama.cpp` and `vLLM` fall back to segmented staging buffers and lose up to 50% throughput.
   * *Verify:* Open **Intel Graphics Software** $\to$ **System** (or GPU-Z) and confirm **Resizable BAR** says **Enabled**.
2. **Disable PCIe Link State Power Management (ASPM) on Windows:**
   * Open **Control Panel** $\to$ **Power Options** $\to$ **Change plan settings** $\to$ **Change advanced power settings** $\to$ **PCI Express** $\to$ **Link State Power Management** $\to$ Set to **Off**.
   * This prevents Windows from putting the PCIe Gen 5 x16 link into L1 sleep between conversational turns.
3. **Install Intel Graphics Driver `32.0.101.8860` or Newer:**
   * Driver `8860+` includes critical Battlemage (`BMG-G31`) Vulkan FlashAttention prefill optimizations and Level Zero XMX stability fixes.
4. **Install `arc-gpu.exe` (`intel-arc-pro-fan-control`):**
   * Place `arc-gpu.exe` in the same folder as `B70-ControlCenter.ps1`, in `C:\Program Files\ArcGpuControl\`, or anywhere on your system `PATH`.

---

## 3. Power Profile Decision Matrix: When to Use 150W, 165W, 180W, or 230W

More watts does not always mean more tokens per second. Once the **608 GB/s GDDR6 memory bus** is 100% saturated during single-user token generation, pushing extra power only generates heat. Use this guide to pick the exact tier for your workload:

### `[0]` Stock Normal (Unlocked / Factory Auto)
* **Power Draw:** `~12W–18W` at idle; `150W` default factory cap under 3D load
* **Fan Behavior:** Firmware Auto (Zero-RPM / silent at idle)
* **When to Use:**
  * Everyday desktop work, web browsing, media playback, or idle standby.
  * Standard 3D gaming (where continuous raster/raytracing load naturally keeps clocks high).
  * Whenever you finish your AI/compute session.

### `[1]` 150W — Eco Mode (MoE & Quiet Operation)
* **Power Limit:** `150W` + Quiet Fan Curve (`45°C:30%` $\to$ `85°C:100%`)
* **When to Use:**
  * **Mixture-of-Experts (MoE) LLMs (`Qwen3-30B-A3B`, `Qwen3.6-35B-A3B`):** MoE models only activate ~3B parameters per token. At `150W`, the B70 hits ~100% of its maximum MoE token decode speed (`70–130 tok/s`) while running cool and quiet.
  * **Small to Medium Dense Models (`1.5B` to `9B`):** Ideal for background coding assistants, Whisper STT, and Kokoro TTS.
  * Small form-factor (SFF) cases or warm rooms where low noise is the priority.

### `[2]` 165W — Peak Efficiency Mode (The Daily Sweet Spot)
* **Power Limit:** `165W` + Balanced Fan Curve (`45°C:30%` $\to$ `85°C:100%`)
* **Efficiency:** **`0.148 tok/s per Watt`** (Peak tokens-per-watt on Battlemage `BMG-G31`)
* **When to Use:**
  * **Daily Interactive Chat & Coding with Dense 9B–27B Models (`Qwen3.5-9B`, `Qwen3.6-27B`, `Qwen3.8-27B` with MTP):** Eliminates the 70W power sag and delivers **~98% of maximum single-stream token decode speed** without the fan noise or heat of 180W–230W.
  * If you want one "set and forget" profile for interactive AI work, choose **`[2] 165W`**.

### `[3]` 180W — Sustained Heavy Mode (Long Context & Autonomous Agents)
* **Power Limit:** `180W` + Aggressive Fan Curve (`45°C:35%` $\to$ `85°C:100%`)
* **When to Use:**
  * **Long-Context Codebase Ingestion (`32K` to `128K` tokens):** Processing tens of thousands of prompt tokens (`prefill`) is 100% compute-bound on all 256 XMX engines. `180W` prevents clock throttling during multi-second prefills.
  * **Unattended Autonomous Agent Loops:** Continuous back-to-back reasoning, AST code rewriting, and test generation.
  * **Multi-Modal Co-Execution:** Running a 27B LLM + F5-TTS Diffusion Voice Cloning + Whisper STT in VRAM at the same time.
  * **Image & Video Diffusion (`Flux.1`, `Wan2.1`, `SDXL`):** Diffusion denoise steps hammer XMX compute continuously from start to finish.

### `[4]` 230W — Max Hardware Burst Mode (Batch Compute, Training & 3D Rendering)
* **Power Limit:** `230W` (Physical board ceiling) + MaxCool Fan Curve (`40°C:45%` $\to$ `70°C+:100%`)
* **When to Use:**
  * **Massive Context Prefills (`64K` to `262K` tokens):** Shaves seconds off time-to-first-token when ingesting entire repositories or books.
  * **High-Concurrency Batch Serving (`vLLM XPU` / `llama-server --parallel 4..8`):** When 4 to 8 agent threads query the GPU simultaneously, arithmetic intensity rises and the workload shifts from memory-bound to XMX-compute-bound.
  * **Model Quantization & Fine-Tuning (`AutoRound`, `llama-imatrix` calibration, QLoRA):** Sustains maximum XMX throughput over multi-hour runs.
  * **3D Path Tracing (Blender Cycles OneAPI, OctaneRender).**
  * *Note:* For single-user 1-stream token chatting, `230W` only gives ~3–4% more `tok/s` than `180W` for 50W more heat—use `165W` or `180W` for single-stream chat instead.

---

## 4. Using `B70-ControlCenter.ps1` (Interactive, Persistent & Crash-Safe Modes)

### Mode A: Interactive Console (Lock, Close Window, Reopen Later)
1. Launch `.\B70-ControlCenter.ps1` (it will automatically prompt for Administrator elevation if needed).
2. Press **`2`** (`165W Peak Efficiency`) or **`3`** (`180W Sustained Heavy`).
3. **You can now press `Q` or close the PowerShell window completely.**
   * Your power lock, fan curve, and User SYCL environment variables remain active.
   * Your active profile and pre-lock factory baseline are saved to `C:\ProgramData\B70PowerLease\b70_lease_e223.json`.
4. Whenever you finish working—even hours or days later—reopen `.\B70-ControlCenter.ps1`.
   * The top banner will immediately recognize and display:
     `ACTIVE PROFILE : [LOCKED] 165W Peak Efficiency (165W Ceiling)`
     along with your **Live Power Draw (W)**, **GPU Temp (°C)**, and **Fan Speed**.
5. Press **`0`** to restore **Stock Normal** (`150W` factory power + `fan auto` + clean environment variables).

### Mode B: Live Hold Mode (`[6]` or `-Action Hold`)
If you prefer the GPU to **automatically reset itself to Stock Normal the moment you close the terminal or press `Ctrl+C`**, press **`6`** in the menu or run:
```powershell
.\B70-ControlCenter.ps1 -Action Hold -Profile Sustained180W
```

### Mode C: Non-Interactive CLI (For Batch Scripts, Task Scheduler, or App Launchers)
You can wrap any application in a 3-line script so the B70 locks before the app starts and resets to normal as soon as the app closes:
```powershell
# Example wrapper for any local AI or 3D application
.\B70-ControlCenter.ps1 -Action Lock -Profile Sustained180W
Start-Process -FilePath "C:\Path\To\YourApp.exe" -Wait
.\B70-ControlCenter.ps1 -Action Reset
```

---

## 5. Engine-Specific Optimization Guides

### 5.1 `llama.cpp` / `llama-server` (SYCL vs. Vulkan & MTP Speculative Decoding)

On the Arc Pro B70 32GB, `llama.cpp` offers two fast backends—**SYCL** and **Vulkan**—with different strengths:

* **When to Use `SYCL` (`-dev SYCL0`):**
  * Best for **Dense 14B–32B models** (`Qwen3.6-27B`, `Qwen3.8-27B`), especially when context length exceeds **16,384 tokens** (where SYCL XMX prefill is up to **2× faster** than Vulkan).
* **When to Use `Vulkan` (`-dev Vulkan0`):**
  * Great for **Mixture-of-Experts (`30B-A3B` / `35B-A3B`)** models if you are on an older SYCL build without fused MoE kernels.

#### Recommended B70 `llama-server` Command (With FlashAttention, Quantized KV & MTP)
Once you have locked `[2] 165W` or `[3] 180W` in `B70-ControlCenter.ps1`, run:

```powershell
llama-server `
  -m .\models\Qwen3.8-27B-TURBO-Q4_K_S-MTP.gguf `
  -dev SYCL0 -ngl 999 -ncmoe 0 `
  -fa on -ctk q8_0 -ctv q4_1 `
  --spec-type draft-mtp --spec-draft-n-max 2 `
  -b 8192 -ub 4096 -c 32768 `
  --temp 0.65 --repeat-penalty 1.0 `
  --port 8080
```

**Why Each Flag Matters on the B70:**
* `-fa on -ctk q8_0 -ctv q4_1`: Enables hardware FlashAttention and quantizes the Key cache to 8-bit (`q8_0`) and Value cache to 4-bit (`q4_1`). This cuts 32K–128K KV-cache VRAM consumption by **~55%** and reduces memory bandwidth pressure during decode with near-zero quality loss (`KLD ~ 0.003`).
* `--spec-type draft-mtp --spec-draft-n-max 2`: Activates built-in Multi-Token Prediction (MTP) heads on `-MTP` GGUF models, boosting B70 decode speed by **40% to 90%**.
* `--repeat-penalty 1.0 --temp 0.65`: Keep `repeat-penalty` at `1.0` (disabled) and `temp <= 1.0` when using `MAX-MTP` models so the 16-bit output head and `Q8_0` MTP draft heads maintain a **>60% token acceptance rate**.

---

### 5.2 LM Studio & Desktop GUI Applications

Because `B70-ControlCenter.ps1` writes the SYCL optimization flags (`UR_L0_USE_IMMEDIATE_COMMANDLISTS=1`, `SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=1`, `SYCL_CACHE_PERSISTENT=0`) to your **Windows User Environment** when you lock a profile:
1. Run `B70-ControlCenter.ps1` and press **`2` (`165W`)** or **`3` (`180W`)** *before* opening your GUI application.
2. Launch your GUI application normally from the Start Menu or Desktop—Windows automatically passes the new User Environment variables to the newly spawned process.
3. In your GUI app's model settings:
   * Enable **Flash Attention**.
   * Set **GPU Offload** to **Max / All Layers**.
   * Set **Repeat Penalty** to **`1.0`** if running a `MAX-MTP` model.
4. When finished, close your GUI app, open `B70-ControlCenter.ps1`, and press **`0`** to reset the B70 back to Stock Normal.

---

### 5.3 WSL2 Ubuntu + `vLLM XPU` Hybrid Setup

Inside WSL2 Ubuntu, `/dev/dxg` passes compute calls to the Windows host driver, **but Linux tools inside WSL2 cannot directly change hardware fan curves or IGCL power limits**.
* **The Solution:** Run `B70-ControlCenter.ps1` on your **Windows 11 host** and lock **`[3] 180W`** or **`[4] 230W`**. The hardware power and fan lock applies at the physical PCIe card level, so your WSL2 Ubuntu `vLLM XPU` or Linux `llama.cpp` containers immediately benefit from the unlocked power ceiling and cooling curve.

---

## 6. Quantization Selection Guide for 32GB VRAM

On the Arc Pro B70's Xe2 architecture, **`_K` super-block quants (`Q4_K_S`, `Q4_K_M`, `Q5_K_S`)** execute faster than non-linear codebook lookup quants (`IQ4_XS`, `IQ4_NL`, `IQ3_M`) because affine scale/min math maps directly to SIMD/XMX instructions without lookup-table gather latency:

| Model Size Class | Best Single-Model Quant on B70 (32GB) | Best Dual Co-Resident Quant (e.g., 9B + 27B in VRAM Together) |
|---|---|---|
| **9B Models (`Qwen3.5-9B`)** | `MTP Q5_K_M` (`7.67 GB`) or `MTP Q6_K` (`8.56 GB`) | **`MTP Q4_K_S` (`6.55 GB`)** or `MTP Q4_K_M` (`6.83 GB`) |
| **27B–32B Dense (`Qwen3.8-27B`)** | `MTP Q5_K_M` (`20.7 GB`) or `MTP Q6_K` (`23.6 GB`) | **`MTP Q4_K_S` (`17.1 GB`)** or `MTP Q4_K_M` (`18.0 GB`) |
| **30B–35B MoE (`A3B`)** | `MTP Q5_K_M` (`~22 GB`) | `MTP Q4_K_M` (`~18.5 GB`) |

* **Co-Resident Math (`9B + 27B` Loaded Simultaneously):** `6.55 GB` (`9B MTP Q4_K_S`) + `17.10 GB` (`27B MTP Q4_K_S`) = **`23.65 GB`** for model weights, leaving **`8.35 GB` of physical VRAM** on your 32GB B70 for long-context KV caches, voice models, and desktop display buffers with zero PCIe swapping.

---

## 7. Safety Architecture: How State Persistence & Crash Recovery Work

1. **Non-Destructive Service Backup:**
   Before applying your first lock, `B70-ControlCenter.ps1` backs up `%ProgramData%\ArcFanControl\config.ini` to `C:\ProgramData\B70PowerLease\ArcFanControl_config_e223.ini.bak` and records your factory wattage in `b70_lease_e223.json`. Nested locks (switching from `165W` $\to$ `180W` $\to$ `230W`) never overwrite your original factory baseline backup.
2. **Why `fan auto` Table Mode Is Used Instead of Raw `ctlFanSetDefaultMode`:**
   In Intel's IGCL C API, calling raw `ctlFanSetDefaultMode()` surrenders software fan table ownership until a system reboot or `pnputil /restart-device`. By calling `arc-gpu --gpu e223 fan auto`, the card returns to quiet firmware-equivalent automatic thermal control while allowing you to re-lock manual curves anytime without restarting the display driver.

---

## 8. Troubleshooting & Common IGCL Error Codes

* **`IGCL returned 0x4000000a (Access Denied / Waiver Rejected)`**
  * **Cause:** Intel's IGCL driver API rejects power and fan register writes from non-elevated processes.
  * **Fix:** Right-click PowerShell and select **Run as Administrator** (or let `B70-ControlCenter.ps1` auto-elevate via the UAC prompt).
* **`IGCL returned 0x4000000b` (Transient Busy / Conflict)**
  * **Cause:** The background `arc-fan-service` polled the GPU sensor registers at the exact millisecond your command ran.
  * **Fix:** `B70-ControlCenter.ps1` automatically catches `0x4000000b` and retries up to 3 times with a 1.2-second backoff.
* **Multi-GPU Systems (e.g., Dual B70 or Integrated Intel iGPU + Discrete B70):**
  * `B70-ControlCenter.ps1` automatically searches WMI for PCI Device ID `DEV_E223` (Arc Pro B70) so it never accidentally targets an Intel integrated CPU graphics adapter. If you have **two** Arc Pro B70 cards installed, press **`[G]`** in the menu to list all adapters and select which card index or PCI ID to tune.
