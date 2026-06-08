# CUDA and System Updates

## Overview

This document covers running OS, CUDA, and apt system updates on the DGX Spark after first boot.

## Prerequisites

- Both DGX Sparks powered on and connected to the internet
- Monitor connected to Spark 1
- Initial first-boot setup wizard completed

## Method 1: DGX Dashboard (Recommended)

The DGX Dashboard is the recommended update method as it handles OS, CUDA, drivers, and firmware automatically.

### Launching the Dashboard

1. Find the `dgx-spark-dashboard.desktop` file on the desktop
2. Right-click → **Allow Launching** (first time only)
3. Double-click to open — the dashboard loads in the browser
4. Alternatively, navigate directly to `http://localhost` in a browser

### Running Updates

1. Log in to the DGX Dashboard
2. Look for the **"Update Available"** button on the main screen
3. Click **"Update Now"**
4. Do not power off during the update — it may reboot automatically
5. After reboot, check for updates again — multiple rounds may be required

> **Note:** It is normal to see "Update Available" multiple times. Some updates only become visible after previous ones are installed. Keep clicking "Update Now" until no more updates appear.

## Method 2: Terminal (Alternative)

```bash
sudo apt update
sudo apt dist-upgrade -y
sudo fwupdmgr refresh
sudo fwupdmgr upgrade
sudo reboot
```

## Verifying Updates

After updates complete, verify the system state:

```bash
# Check OS version
cat /etc/os-release

# Check CUDA version
nvidia-smi

# Check driver version
nvidia-smi --query-gpu=driver_version --format=csv,noheader
```

## Expected Versions (Post-Update)

- OS: Ubuntu 24.04.4 LTS
- Kernel: 6.17.0-1018-nvidia
- CUDA Driver: 580.159.03
- CUDA Runtime: 13.0

## Notes

- Updates must be run on **both Sparks** independently
- Spark 2 can be updated via SSH from Spark 1 using the terminal method
- The DGX Dashboard method only applies to the Spark it is run on
