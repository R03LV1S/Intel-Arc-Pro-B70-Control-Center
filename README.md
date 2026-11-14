# Intel Arc Pro B70 (32GB) Direct-Driver Power & SYCL XMX Control Center

A **zero-dependency**, single-file PowerShell control center (`B70-ControlCenter.ps1` v2.0) for **Intel Arc Pro B70 32GB (`BMG-G31`, PCI ID `8086:e223`)** and Battlemage workstation GPUs on Windows 11.

Instead of relying on third-party executables or background services, `B70-ControlCenter.ps1` compiles an in-memory C# P/Invoke bridge directly to Intel's pre-installed Windows driver library (**`C:\Windows\System32\ze_loader.dll`** — Intel Level Zero Sysman API) to read and lock hardware `PL1` (Sustained) and `PL2` (Burst) power registers, sample live microjoule energy counters, and configure SYCL Immediate CommandLists.

---

## Why Does the Arc Pro B70 Need This?

1. **Hidden Workstation Tuning Tab & The "70W Power Sag" Bug:**
   Unlike consumer Intel Arc cards (A770/B580), Intel Graphics Software hides the Performance/Tuning tab on workstation "Arc Pro" cards. During single-stream LLM generation (`llama.cpp`, LM Studio, OpenCode, vLLM), the GPU alternates between compute-bound prompt prefill and memory-bandwidth-bound token decode. During decode, the stock workstation firmware misinterprets brief memory-wait intervals as light load and lets board power sag to **`60W–80W`**, costing **15% to 35% of your token generation speed**.
2. **Direct-Driver `PL1 / PL2` Hardware Locking (Zero External Apps):**
   Calls `zesPowerGetLimits()` and `zesPowerSetLimits()` in `ze_loader.dll` to lock both Sustained (`PL1`) and Burst (`PL2`) power limits in milliwatts, and samples `zesPowerGetEnergyCounter()` to calculate real-time board power draw in Watts.
3. **Level Zero Immediate CommandLists ("Redline" Dispatch Path):**
   Configures `UR_L0_USE_IMMEDIATE_COMMANDLISTS=1` and `SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=1` in your Windows User Environment to bypass OS command-queue batching for direct XMX hardware doorbell dispatch, while setting `SYCL_CACHE_PERSISTENT=0` to prevent the `ggml-sycl` dynamic teardown crash.
4. **Persistent Cross-Session State Memory:**
   Lock your GPU to `165W` or `180W`, **close the PowerShell window**, and run your workloads. When you reopen `B70-ControlCenter.ps1` hours or days later, it reads the persisted lease from `C:\ProgramData\B70PowerLease\b70_direct_lease.json`, queries the live `ze_loader.dll` driver ceiling, and lets you press **`[0]`** to restore factory `Stock Normal` settings in one keystroke.

---

## Which Power Profile Should I Choose?

| Key | Profile | `PL1` Sustained / `PL2` Burst | Best Workloads & Use Cases | Hardware Physics on `BMG-G31` (256 XMX / 608 GB/s) |
| :---: | :--- | :---: | :--- | :--- |
| **`[0]`** | **Stock Normal** | Factory Baseline (`150W` / `~15W` Idle) | Desktop use, browsing, idle, gaming, or when finished with AI workloads | Restores factory firmware power management and clears SYCL environment overrides. |
| **`[1]`** | **Eco Mode** | **`150W` / `170W`** | **MoE Models (`30B-A3B`, `35B-A3B`)**, `1.7B–9B` dense models, low-noise rooms | MoE models only activate ~3B parameters per token; `150W` saturates the 608 GB/s GDDR6 bus with minimal heat. |
| **`[2]`** | **Peak Efficiency** | **`165W` / `185W`** | **Daily 9B–27B Interactive Chat & Coding** (`Q4_K_S` / `Q4_K_M` + MTP) | **Sweet Spot (`0.148 tok/s/W`):** Eliminates the 70W clock sag while sitting at the knee of the Xe2 voltage-frequency curve. |
| **`[3]`** | **Sustained Heavy** | **`180W` / `200W`** | **27B–32B Deep Reasoning, `32K–128K` Repo Ingestion**, Unattended Overnight Agents, Voice TTS + LLM | Long-context prefill and multi-modal loads stress all **256 XMX engines**; `180W` prevents core boost throttling over multi-hour runs. |
| **`[4]`** | **Max Hardware Burst** | **`230W` / `230W`** | **`64K–262K` Prompt Prefills**, Parallel Code Tournaments (`--parallel 4..8`), Diffusion (Flux/Wan), Blender 3D | Unlocks the physical 230W board ceiling for 100% compute-bound XMX systolic array saturation (shaves 15–22% off large prefill TTFT). |

---

## Prerequisites

* **OS:** Windows 11 (64-bit).
* **BIOS:** **Resizable BAR (ReBAR)** and **Above 4G Decoding** enabled in motherboard BIOS.
* **Driver:** Intel Graphics Driver **`32.0.101.8860` or newer** (which installs `C:\Windows\System32\ze_loader.dll` automatically).
* **External Dependencies:** **None.** Only the single `B70-ControlCenter.ps1` file is required.

---

## Quick Start

### 1. Interactive Menu Mode
Right-click **`B70-ControlCenter.ps1`** and select **Run with PowerShell** (it automatically prompts for Administrator UAC elevation to access Level Zero Sysman hardware registers), or run from an elevated terminal:

```powershell
.\B70-ControlCenter.ps1
```

* Press **`2`** to lock **`165W Peak Efficiency`** or **`3`** to lock **`180W Sustained Heavy`**.
* Press **`Q`** (or close the terminal window) and run your AI/compute applications.
* Reopen **`.\B70-ControlCenter.ps1`** anytime to inspect live wattage draw (`[R]`) or press **`0`** to reset back to **Stock Normal**.

### 2. Command-Line Automation (Scripts & Shortcuts)

```powershell
# Lock to 180W Sustained from a batch script or shortcut
.\B70-ControlCenter.ps1 -Action Lock -Profile Sustained180W

# Lock to a custom wattage (e.g., 185W)
.\B70-ControlCenter.ps1 -Action Lock -Watts 185

# Reset back to factory Stock Normal and clear SYCL overrides
.\B70-ControlCenter.ps1 -Action Reset
```

---

## Recommended `llama.cpp` (`llama-server`) Flags for Arc Pro B70 32GB

When paired with `B70-ControlCenter.ps1`, launch `llama-server` on the SYCL backend with FlashAttention, quantized KV cache (`q8_0 / q4_1`), and `-ub 1024` (or `4096`) enabled:

```powershell
llama-server `
  -m .\models\your-27b-model-Q4_K_S-MTP.gguf `
  -dev SYCL0 -ngl 999 -ncmoe 0 `
  -fa on -ctk q8_0 -ctv q4_1 `
  --spec-type draft-mtp --spec-draft-n-max 2 `
  -b 4096 -ub 1024 -c 65536 `
  --temp 0.65 --repeat-penalty 1.0
```

For a deep dive into the hardware physics, hybrid Gated-DeltaNet KV-cache math, and WSL2 `vLLM XPU` tuning, read **[GUIDE.md](./GUIDE.md)**.
