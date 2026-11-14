# Intel Arc Pro B70 (32GB) Power, Fan & SYCL XMX Control Center

An interactive, crash-safe PowerShell control center for **Intel Arc Pro B70 32GB (`BMG-G31`, PCI ID `8086:e223`)** and Battlemage workstation GPUs on Windows 11.

## Why Does the Arc Pro B70 Need This?

1. **Hidden Workstation Tuning Tab & The "70W Power Sag" Bug:**
   Unlike consumer Intel Arc cards (A770/B580), Intel's workstation driver hides the Performance/Tuning tab on the Arc Pro B70. During single-stream LLM generation (`llama.cpp`, LM Studio, OpenCode, vLLM), the card transitions from compute-bound prefill to memory-bandwidth-bound token decode, and the stock firmware often lets board power sag to **`60W–80W`**, costing **15% to 35% of your token generation speed**.
2. **Level Zero Immediate CommandLists (`Redline` Equivalent):**
   Enabling `UR_L0_USE_IMMEDIATE_COMMANDLISTS=1` and `SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=1` bypasses OS command-queue batching for direct XMX doorbell dispatch while setting `SYCL_CACHE_PERSISTENT=0` prevents the known `ggml-sycl` dynamic teardown crash.
3. **Persistent Cross-Session State Memory:**
   Lock your GPU to `165W` or `180W`, **close the PowerShell window**, and run your workloads. When you reopen `B70-ControlCenter.ps1` hours or days later, it reads the persisted lease from `C:\ProgramData\B70PowerLease\`, displays your active profile and live wattage, and lets you press **`[0]`** to restore factory `Stock Normal` settings in one keystroke.

---

## Which Power Profile Should I Choose?

| Key | Profile | Power Limit | Best Workloads & Use Cases | Why It Works on the B70 (`BMG-G31`) |
| :---: | :--- | :---: | :--- | :--- |
| **`[0]`** | **Stock Normal** | Factory Auto (`150W` / `~15W` Idle) | Desktop use, browsing, idle, gaming, or when finished with AI workloads | Restores factory firmware power management and zero-RPM/quiet `fan auto` curves. |
| **`[1]`** | **Eco Mode** | **`150W`** | **MoE Models (`30B-A3B`, `35B-A3B`)**, `1.7B–9B` dense models, low-noise rooms | MoE models only activate ~3B parameters per token; `150W` saturates the 608 GB/s GDDR6 bus with minimal heat. |
| **`[2]`** | **Peak Efficiency** | **`165W`** | **Daily 9B–27B Interactive Chat & Coding** (`Q4_K_S` / `Q4_K_M` + MTP) | **Sweet Spot (`0.148 tok/s/W`):** Eliminates the 70W clock sag while sitting at the knee of the Xe2 efficiency curve. |
| **`[3]`** | **Sustained Heavy** | **`180W`** | **27B–32B Deep Reasoning, `32K–128K` Code Repo Ingestion**, Voice TTS + LLM, Flux/Wan Diffusion | Long-context prefill and diffusion hammer all **256 XMX engines** simultaneously; `180W` prevents boost clock throttling. |
| **`[4]`** | **Max Burst** | **`230W`** | **`64K–262K` Prompt Prefills**, Multi-Agent Batching (`vLLM`), `imatrix` / `AutoRound` Quantization, Blender 3D | Unlocks the physical 230W ceiling of the B70 for 100% sustained XMX systolic array saturation. |

---

## Prerequisites

1. **Windows 11** with **Resizable BAR (ReBAR)** enabled in motherboard BIOS.
2. **Intel Graphics Driver `32.0.101.8860` or newer**.
3. **`arc-gpu.exe` CLI** ([exzile/intel-arc-pro-fan-control](https://github.com/exzile/intel-arc-pro-fan-control) — grab `ArcGpuControl-Setup.exe` from [Releases](https://github.com/exzile/intel-arc-pro-fan-control/releases), which installs `arc-gpu.exe` to `C:\Program Files\ArcFanControl\`).

---

## Quick Start

### 1. Interactive Menu Mode (Recommended)
Right-click **`B70-ControlCenter.ps1`** and select **Run with PowerShell** (it will automatically prompt for Administrator elevation), or run from an elevated terminal:

```powershell
.\B70-ControlCenter.ps1
```

* Press **`2`** to lock **`165W Peak Efficiency`** or **`3`** to lock **`180W Sustained Heavy`**.
* Press **`Q`** (or close the window) and run your AI/compute apps.
* Reopen **`.\B70-ControlCenter.ps1`** anytime and press **`0`** to reset back to **Stock Normal**.

### 2. Command-Line Automation (Scripts & Shortcuts)

```powershell
# Lock to 180W Sustained from a script or shortcut
.\B70-ControlCenter.ps1 -Action Lock -Profile Sustained180W

# Hold Mode: Locks GPU and automatically resets to Stock Normal when you press Ctrl+C
.\B70-ControlCenter.ps1 -Action Hold -Profile Peak165W

# Reset back to Stock Normal (150W + Firmware Auto Fan)
.\B70-ControlCenter.ps1 -Action Reset
```

---

## Recommended `llama.cpp` (`llama-server`) Flags for Arc Pro B70 32GB

When paired with `B70-ControlCenter.ps1` (`[2]` 165W or `[3]` 180W), launch `llama-server` with FlashAttention and quantized KV cache enabled:

```powershell
llama-server `
  -m .\models\your-27b-model-Q4_K_S-MTP.gguf `
  -dev SYCL0 -ngl 999 -ncmoe 0 `
  -fa on -ctk q8_0 -ctv q4_1 `
  --spec-type draft-mtp --spec-draft-n-max 2 `
  -b 8192 -ub 4096 -c 32768 `
  --temp 0.65 --repeat-penalty 1.0
```
