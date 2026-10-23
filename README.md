# Intel Braswell / Bay Trail Chromebook (`chtrt5650` / `snd_intel_sst_acpi`) PipeWire Silent Audio Dropout Fix

**Forensic Root-Cause Analysis & Automated Remediation for Debian 12/13, Ubuntu, Fedora, and Arch Linux**

[![License: MIT](https://img.shields.io/badge/License-MIT-CC5500.svg)](LICENSE)
[![Subsystem: PipeWire + WirePlumber](https://img.shields.io/badge/Audio-PipeWire%201.x%20%7C%20WirePlumber%200.5%2B-000000.svg)](#2-forensic-root-cause-quantum-collapse--capture-clock-hijacking)
[![Hardware: Intel SST DSP + Realtek RT5645/RT5650](https://img.shields.io/badge/Platform-Intel%20Braswell%20%2F%20Cherry%20Trail%20SST-CC5500.svg)](#affected-hardware--software-matrix)

---

## 1. Executive Summary & Symptoms

Chromebooks and low-power laptops equipped with **Intel Braswell / Cherry Trail (`cht-bsw`)** or **Bay Trail (`bytcr`)** SoCs utilizing the **Intel SST Audio DSP (`snd_intel_sst_acpi`)** and **Realtek RT5645 / RT5650 (`chtrt5650`)** codecs experience a reproducible **"silent audio black-hole"** under modern **PipeWire + WirePlumber** stacks:

1. **Single-Stream Playback Works Normally:** Playing audio from a single media client (`mpv`, `ytm-player`, browser, or `pw-play`) produces clean audio through the internal speakers or 3.5mm headphones.
2. **Opening a Second Audio/GUI Client Silences Physical Output:** The moment a second application opens an audio stream, probes input/capture devices, or attaches peak-level meters—such as **PulseAudio Volume Control (`pavucontrol`)**, desktop audio settings panels, **RustDesk**, **Steam Link**, or WebRTC/VoIP apps—**all physical sound from the speakers and headphone jack stops immediately**.
3. **Software Meters Falsely Report Active Playback:** The GUI volume meters still bounce as if audio is playing, no sink mute is triggered, and physical audio only returns after closing the second application.
4. **Kernel `dmesg` Mailbox Errors:** Opening and closing audio clients logs repeated DSP mailbox errors:
   ```text
   intel_sst_acpi 808622A8:00: sst: Busy wait failed, can't send this msg
   ```

### Affected Hardware & Software Matrix

| Component | Affected Specification |
| :--- | :--- |
| **SoC / Platform** | Intel Celeron N3050 / N3060 / N3150 / N3160 (Braswell / Cherry Trail / Bay Trail) |
| **DSP Driver** | `snd_intel_sst_acpi` (`808622A8:00` / `80860F28:00`, FW `01.0b.02.02` `fw_sst_22a8.bin`) |
| **ASoC Machine Driver** | `snd_soc_sst_cht_bsw_rt5645` (`chtrt5650` / `cht-bsw-rt5645` / `bytcr-rt5640`) |
| **Verified Reference Chassis** | HP Chromebook 11 G5 (`GOOGLE-Setzer-1.0`), Intel Celeron N3060 |
| **OS / Audio Stack** | Debian 13 (Trixie) / Kernel `6.12.x`, PipeWire `1.4.x`, WirePlumber `0.5.x` (and Ubuntu 24.04+) |

---

## 2. Forensic Root Cause (Quantum Collapse & Capture Clock Hijacking)

Inspecting `/proc/asound/card1/pcm0p/sub0/hw_params`, `/proc/asound/card1/pcm0p/sub0/status`, and `pw-top` simultaneously during the failure exposes a three-part collision between PipeWire's dynamic quantum scaling, WirePlumber's default ALSA driver priorities, and the Intel SST DSP firmware's fixed DMA period constraints:

### Stage 1: Fixed `1008`-Frame Hardware Period on the Intel SST DSP
The `snd_intel_sst_acpi` / `snd_soc_sst_atom_hifi2_platform` hardware DMA engine locks `pcm0p` (Speaker/Headphones) and `pcm0c` (Internal/Headset Mic) to a fixed hardware `period_size` of **`1008` frames** (`21 ms` at `48000 Hz`):

```text
==> /proc/asound/card1/pcm0p/sub0/hw_params <==
access: MMAP_INTERLEAVED
format: S16_LE
channels: 2
rate: 48000 (48000/1)
period_size: 1008
buffer_size: 34272
```

### Stage 2: Dynamic Quantum Collapse (`2048` $\rightarrow$ `256` / `128` Frames)
* When a standard playback stream (`mpv`) runs alone, PipeWire schedules the graph at `clock.quantum = 2048` frames (`2048 > 1008`). Every PipeWire graph cycle feeds more than one full `1008`-frame SST hardware period, keeping `/proc/asound/card1/pcm0p/sub0/status` in **`state: RUNNING`**.
* When `pavucontrol`, RustDesk, or Steam Link opens, it attaches peak-level monitor streams (`F32LE 1 144Hz`) and/or low-latency capture probes requesting a small quantum (`128` to `256` frames).
* Because PipeWire defaults to `clock.min-quantum = 32`, PipeWire dynamically drops the active hardware quantum from **`2048` down to `256` (or `128`)**—which is **smaller than a single `1008`-frame hardware DMA period**.

### Stage 3: Capture Clock Hijack (`priority.driver = 2000`) & Infinite `state: SETUP` XRUN Loop
By default in WirePlumber (`/usr/share/wireplumber/scripts/monitors/alsa.lua`), ALSA capture nodes receive `priority.driver = 2000` while playback sinks receive `priority.driver = 1000`, and the unconfigured capture ring buffer only allocates **2 periods (`2016` frames)**:

```text
# Before opening pavucontrol (Playback alone at Quantum 2048):
R   56   2048  48000  39.6us  34.6us  0.00  0.00  1567  S16LE 2 48000 alsa_output.platform-cht-bsw-rt5645.HiFi__Speaker__sink
S   57      0      0    ---     ---   ---   ---     0                 alsa_input.platform-cht-bsw-rt5645.HiFi__Mic1__source

# After opening pavucontrol (Quantum collapses to 256 & Mic1 becomes active):
R   56    256  48000 161.4us  20.4us  0.03  0.00  1580  S16LE 2 48000 alsa_output.platform-cht-bsw-rt5645.HiFi__Speaker__sink
R   57    256  48000  75.3us   6.5us  0.01  0.00  5251  S16LE 2 48000 alsa_input.platform-cht-bsw-rt5645.HiFi__Mic1__source
```

As soon as `pcm0c` starts driving the graph at quantum `256`, `pcm0p` (playback) suffers immediate ring-buffer starvation and enters a perpetual XRUN reset loop—trapped in **`state: SETUP` (`delay: 0`, `hw_ptr: 1008`)** where the ALSA sink resets before the SST DSP can ever clock out a full `1008`-frame period to the Realtek RT5650 DAC:

```text
==> /proc/asound/card1/pcm0p/sub0/status <==
state: SETUP
owner_pid   : 1228
delay       : 0
avail       : 34512
avail_max   : 0
-----
hw_ptr      : 1008
appl_ptr    : 768
```

Meanwhile, PipeWire's software graph continues pulling buffers from `mpv` and feeding the `pavucontrol` GUI peak meters, making the desktop UI appear as though audio is still playing normally. Furthermore, whenever the nodes go idle for 5 seconds, WirePlumber's `suspend-node.lua` suspends the SST PCM streams, triggering the DSP mailbox timeout:
`intel_sst_acpi 808622A8:00: sst: Busy wait failed, can't send this msg`.

---

## 3. Remediation (`apply_sst_pipewire_fix.sh` or Manual Drop-ins)

### Option A: Automated Remediation Script
Review and run [`apply_sst_pipewire_fix.sh`](apply_sst_pipewire_fix.sh):

```bash
chmod +x apply_sst_pipewire_fix.sh
sudo ./apply_sst_pipewire_fix.sh --apply
```

Supported flags:
* `sudo ./apply_sst_pipewire_fix.sh --status` — Inspect ALSA PCM hardware parameters, subdevice states, and installed drop-ins.
* `sudo ./apply_sst_pipewire_fix.sh --apply` — Deploy `/etc/pipewire/pipewire.conf.d/99-cht-sst-audio-fix.conf` and `/etc/wireplumber/wireplumber.conf.d/99-cht-sst-audio-fix.conf` and restart user PipeWire services.
* `sudo ./apply_sst_pipewire_fix.sh --rollback` — Remove both drop-ins and restore stock defaults.

---

### Option B: Manual Configuration Drop-ins

#### Step 1: Enforce a `1024`-Frame PipeWire Clock Quantum Floor
Create `/etc/pipewire/pipewire.conf.d/99-cht-sst-audio-fix.conf` so no low-latency client (`pavucontrol`, RustDesk, Steam Link, Flatpaks) can pull the graph quantum below the SST DSP's `1008`-frame period:

```bash
sudo mkdir -p /etc/pipewire/pipewire.conf.d
sudo tee /etc/pipewire/pipewire.conf.d/99-cht-sst-audio-fix.conf >/dev/null << 'EOF'
context.properties = {
    default.clock.rate          = 48000
    default.clock.allowed-rates = [ 48000 ]
    default.clock.quantum       = 2048
    default.clock.min-quantum   = 1024
    default.clock.max-quantum   = 4096
}
EOF
```

#### Step 2: Harden WirePlumber ALSA SST Node Buffers, Driver Priority, and Idle Suspend
Create `/etc/wireplumber/wireplumber.conf.d/99-cht-sst-audio-fix.conf` to:
1. Lock `api.alsa.period-size = 1008`, `api.alsa.period-num = 16` (`16128`-frame buffer on both playback and capture), and `api.alsa.headroom = 2048`.
2. Set playback `priority.driver = 2500` higher than capture `priority.driver = 1500` so opening the microphone never hijacks the master clock from active speaker/headphone playback.
3. Disable the 5-second idle suspend (`session.suspend-timeout-seconds = 0`) to eliminate `sst: Busy wait failed` kernel errors.

```bash
sudo mkdir -p /etc/wireplumber/wireplumber.conf.d
sudo tee /etc/wireplumber/wireplumber.conf.d/99-cht-sst-audio-fix.conf >/dev/null << 'EOF'
monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~alsa_output.platform-cht-bsw-.*"
      }
      {
        node.name = "~alsa_output.platform-bytcr-.*"
      }
    ]
    actions = {
      update-props = {
        api.alsa.period-size            = 1008
        api.alsa.period-num             = 16
        api.alsa.headroom               = 2048
        priority.driver                 = 2500
        priority.session                = 2500
        session.suspend-timeout-seconds = 0
        node.pause-on-idle              = false
      }
    }
  }
  {
    matches = [
      {
        node.name = "~alsa_input.platform-cht-bsw-.*"
      }
      {
        node.name = "~alsa_input.platform-bytcr-.*"
      }
    ]
    actions = {
      update-props = {
        api.alsa.period-size            = 1008
        api.alsa.period-num             = 16
        api.alsa.headroom               = 2048
        priority.driver                 = 1500
        priority.session                = 1500
        session.suspend-timeout-seconds = 0
        node.pause-on-idle              = false
      }
    }
  }
]
EOF
```

#### Step 3: Restart PipeWire & Verify Full-Duplex Operation
```bash
systemctl --user restart pipewire wireplumber pipewire-pulse
```

Verify with `pw-top` and `/proc/asound/card1/pcm*/sub0/status` while running media playback and `pavucontrol` simultaneously:
* Quantum remains at **`1024`** (`ERR = 0`).
* Both `pcm0p` and `pcm0c` remain in **`state: RUNNING`** (`buffer_size: 16128`, `period_size: 1008`).
* `dmesg` logs **zero** `sst: Busy wait failed` errors.

---

## 4. License
Released under the [MIT License](LICENSE). Authored by **Bill Fullen** ([@Tethtibis](https://github.com/Tethtibis)).
