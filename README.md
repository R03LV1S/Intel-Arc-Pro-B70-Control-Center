# Intel Arc Pro B70 (32GB) Direct-Driver & Auto-Pilot Control Center (v2.2)

A **zero-dependency**, single-file PowerShell control center and dynamic phase-scaling daemon (`B70-ControlCenter.ps1` v2.2) for **Intel Arc Pro B70 32GB (`BMG-G31`, PCI ID `8086:e223`)** and Battlemage workstation GPUs on Windows 11.

Instead of relying on third-party executables or background services, `B70-ControlCenter.ps1` compiles an in-memory C# P/Invoke bridge directly to Intel's pre-installed Windows driver library (**`C:\Windows\System32\ze_loader.dll`** — Intel Level Zero Sysman API) to program hardware `PL1` (Sustained) and `PL2` (Burst) power registers, sample real-time microjoule energy counters, and automatically scale between **`150W` $\leftrightarrow$ `165W` $\leftrightarrow$ `180W` $\leftrightarrow$ `230W`** across any application (LM Studio, OpenCode, `llama.cpp`, ComfyUI, Blender, or WSL2 `vLLM XPU`).

---

## Key Features in v2.2

1. **Solves the Workstation "70W Power Sag" Bottleneck:**
   Intel Graphics Software hides the Performance/Tuning tab on workstation "Arc Pro" cards. During single-stream LLM token generation, the stock firmware misinterprets brief GDDR6 memory-wait intervals as light load and lets board power sag to **`60W–80W`**, costing **15% to 35% of your token generation speed**.
2. **Universal Multi-Mode Telemetry Auto-Pilot (`[6]` & `[7]`):**
   By sampling the GPU's hardware microjoule accumulator (`zesPowerGetEnergyCounter`) every 250 ms, the Auto-Pilot detects workload phases automatically—without needing any plugin or integration in LM Studio, OpenCode, or Ollama:
   * **Idle / Reading (`< 36W` draw):** Parks at **`150W PL1 / 185W PL2` (Eco Standby)**.
   * **Token Streaming Decode (`36W–135W` draw):** Locks **`165W PL1 / 210W PL2` (Peak Efficiency)** so clocks never sag to 70W.
   * **Sustained Heavy Compute (`135W–156W` draw):** Steps up to **`180W PL1 / 220W PL2`**.
   * **XMX Prefill / Parallel Batch Surge (`>= 156W` draw):** Automatically unlocks **`230W PL1 / 230W PL2` (Max Hardware Burst)** during large prompt prefills (`8K–262K` tokens), parallel code tournaments, or diffusion passes—then automatically drops back to **`165W`** within 1.25 seconds of prefill completion as token decode becomes memory-bandwidth-bound again.
3. **Detached Background Auto-Pilot Daemon (`[7]`):**
   Start the Auto-Pilot as a silent background process (`[7]`), **close the PowerShell window**, and work normally. Reopen `B70-ControlCenter.ps1` anytime to view the active daemon PID and current power tier, or press **`[0]`** to stop the daemon and restore factory `Stock Normal`.
4. **Level Zero Immediate CommandLists ("Redline" Dispatch Path):**
   Configures `UR_L0_USE_IMMEDIATE_COMMANDLISTS=1`, `SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=1`, and `SYCL_CACHE_PERSISTENT=0` in your Windows User Environment for direct XMX hardware doorbell dispatch.

---

## Interactive Menu & Power Profiles

| Key | Mode / Profile | `PL1` Sustained / `PL2` Burst | Best Workloads & Behavior |
| :---: | :--- | :---: | :--- |
| **`[0]`** | **Reset to Stock Normal** | Factory Baseline (`150W` / `~15W` Idle) | Stops any running Auto-Pilot daemon, restores factory power limits, and clears SYCL environment overrides. |
| **`[1]`** | **Static Eco Lock** | **`150W` / `185W`** | **MoE Models (`30B-A3B`, `35B-A3B`)**, `1.7B–9B` dense models, low-noise rooms. |
| **`[2]`** | **Static Peak Efficiency** | **`165W` / `210W`** | **Daily 9B–27B Interactive Chat & Coding** (`0.148 tok/s/W` efficiency sweet spot). |
| **`[3]`** | **Static Sustained Heavy** | **`180W` / `220W`** | **27B–32B Deep Reasoning, `32K–128K` Repo Ingestion**, Unattended Overnight Agents, Voice TTS + LLM. |
| **`[4]`** | **Static Max Burst** | **`230W` / `230W`** | **`64K–262K` Prompt Prefills**, Parallel Batching (`--parallel 4..8`), Diffusion (Flux/Wan), Blender 3D. |
| **`[5]`** | **Custom Wattage Lock** | **`100W–230W` / `+25W`** | User-defined sustained `PL1` ceiling with an automatic `+25W` `PL2` burst window. |
| **`[6]`** | **Smart Auto-Pilot (Console)** | **Dynamic `150W ↔ 165W ↔ 180W ↔ 230W`** | Live real-time telemetry console that scales power per workload phase and resets on `Ctrl+C`. |
| **`[7]`** | **Background Auto-Pilot Daemon** | **Dynamic `150W ↔ 165W ↔ 180W ↔ 230W`** | Spawns the Smart Auto-Pilot as a hidden background process that persists after you close the window. |

---

## Prerequisites

* **OS:** Windows 11 (64-bit).
* **BIOS:** **Resizable BAR (ReBAR)** and **Above 4G Decoding** enabled in motherboard BIOS.
* **Driver:** Intel Graphics Driver **`32.0.101.8860` or newer** (which installs `C:\Windows\System32\ze_loader.dll` automatically).
* **External Dependencies:** **None.** Only the single `B70-ControlCenter.ps1` script is required.

---

## Quick Start

### 1. Interactive Menu Mode (Recommended)
Right-click **`B70-ControlCenter.ps1`** and select **Run with PowerShell** (it automatically prompts for Administrator UAC elevation), or run from an elevated terminal:

```powershell
.\B70-ControlCenter.ps1
```

* **For Automatic Multi-Mode Scaling:** Press **`7`** (**Start Background Auto-Pilot Daemon**), then press **`Q`** to close the window. The daemon will automatically shift between `150W`, `165W`, `180W`, and `230W` while you use LM Studio, OpenCode, or `llama.cpp`.
* **For a Fixed Lock:** Press **`2`** (`165W Peak Efficiency`) or **`3`** (`180W Sustained Heavy`), then close the window.
* **To Return to Factory Normal:** Reopen **`.\B70-ControlCenter.ps1`** anytime and press **`0`**.

### 2. Command-Line Automation (Scripts & Shortcuts)

```powershell
# Start the hidden Background Auto-Pilot Daemon from a script or startup shortcut
.\B70-ControlCenter.ps1 -Action BackgroundDaemon

# Run the live interactive Auto-Pilot monitor in the current terminal (resets on Ctrl+C)
.\B70-ControlCenter.ps1 -Action AutoPilot

# Apply a static 180W PL1 / 220W PL2 lock
.\B70-ControlCenter.ps1 -Action Lock -Profile Sustained180W

# Stop any running daemon, restore factory Stock Normal, and clear SYCL overrides
.\B70-ControlCenter.ps1 -Action Reset
```

---

## Recommended `llama.cpp` (`llama-server`) Flags for Arc Pro B70 32GB

When paired with `B70-ControlCenter.ps1`, launch `llama-server` on the SYCL backend with FlashAttention, quantized KV cache (`q8_0 / q4_1`), and `-ub 1024` (or `4096`):

```powershell
llama-server `
  -m .\models\your-27b-model-Q4_K_S-MTP.gguf `
  -dev SYCL0 -ngl 999 -ncmoe 0 `
  -fa on -ctk q8_0 -ctv q4_1 `
  --spec-type draft-mtp --spec-draft-n-max 2 `
  -b 4096 -ub 1024 -c 65536 `
  --temp 0.65 --repeat-penalty 1.0
```

For a deep dive into the Auto-Pilot telemetry state machine, hardware physics, hybrid Gated-DeltaNet KV-cache math, and WSL2 `vLLM XPU` tuning, read **[GUIDE.md](./GUIDE.md)**.
