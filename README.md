# PTBurn Status Monitor

**Unofficial AutoIt GUI for Primera PTBurn disc publishing robots**

A clean, modern status monitor and control interface for Primera Disc Publisher hardware (DP-4100, 4200, XRP, SE-3, Pro, 405x series, etc.).

## Features

- Real-time robot status, drive status, bin levels, and ink levels
- Live job monitoring with color-coded rows
- Supports all hardware from PTBurn SDK v3.4.4 (including DP 4200 XRP and SE-3)
- One-click commands: Check Bins, Align Printer, Abort Job, Ignore Ink Low
- Job completion cache (survives PTBurnService rotation)

## Requirements

- Primera PTBurn Service installed and running on the server
- `\\<server>\PTBurnJobs` share must be reachable

## Installation & Setup

1. Download the latest release.
2. **Robot Images (required)**  
   The GUI needs several PNG files (`DPII.png`, `DPPRO.png`, `DPSE.png`, `DPXRP.png`, `DPXR.png`, `DPXRn.png`, `NoneFound.png`).  
   These images are copyrighted by Primera and **not included** in this repository.  
   - Download the official **PTBurn SDK v3.4.4** zip.  
   - Extract the `Images` folder from: `Version_3_4_4\Client\Application\Images\`  
   - Copy the entire `Images` folder into the same directory as `PTBurnStatusGUI.exe` (or the `.au3` file).

3. Run `PTBurnStatusGUI.exe` (or open `PTBurnStatusGUI.au3`).

## Usage

- Select your robot from the dropdown.
- Monitor drives, jobs, bins, and ink in real time.
- Use the footer buttons for common commands.

## License

MIT License — see [LICENSE](LICENSE) for details.

**Important**: This is an *unofficial* third-party tool. It is not affiliated with, endorsed by, or supported by Primera Technology. You must have a valid PTBurn Service license from Primera.

## Credits

Developed by Gerard Pinzone.  
Based purely on the documented PTBurn SDK file-based interface (no Primera source code or binaries were used).