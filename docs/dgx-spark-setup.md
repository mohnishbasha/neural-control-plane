# DGX Spark Setup

## Overview

This document covers the initial hardware setup and first-boot configuration of two NVIDIA DGX Spark units forming a 2-node AI cluster.

## Hardware

- 2× NVIDIA DGX Spark (Grace Blackwell GB10)
- Each unit: 1× GB10 GPU, 128GB unified memory, ARM64 CPU (20 cores)
- Combined: 2× GPUs, 256GB unified memory, 40 CPU cores
- Interconnect: QSFP cable via ConnectX-7 (RDMA capable)
- OS: DGX OS (Ubuntu 24.04.4 LTS)
- Kernel: 6.17.0-1018-nvidia

## Physical Setup

1. Connect both Sparks to power — they power on automatically when plugged in
2. Connect monitor, keyboard, and mouse to **Spark 1 only** via HDMI and USB-C hub
3. Connect the QSFP cable between the two units using the ConnectX-7 port on each
4. Spark 2 is managed headlessly via SSH after initial setup

> **Note:** The DGX Spark only has USB-C ports. A USB-C to USB-A hub is required for standard keyboards and mice.

## First Boot Setup

On first boot, DGX OS launches a setup wizard:

1. Select keyboard layout
2. Accept license agreement
3. Create user account
4. Connect to WiFi or skip (Ethernet recommended)
5. The system automatically downloads and installs the complete software image

> **Warning:** Do not power off during the software download step. It cannot be resumed if interrupted.

## Network Configuration

### Static IP Setup

To prevent IP changes between sessions (critical for cluster stability):

```bash
sudo nmcli con mod "$(nmcli -g NAME con show --active | head -1)" \
  ipv4.addresses <SPARK_IP>/24 \
  ipv4.gateway 192.168.86.1 \
  ipv4.dns 8.8.8.8 \
  ipv4.method manual
sudo nmcli con up "$(nmcli -g NAME con show --active | head -1)"
```

**Assigned static IPs:**
- Spark 1 (master): `192.168.86.30`
- Spark 2 (worker): `192.168.86.26`

### iptables Persistent Rules

Add rules to allow router traffic and prevent SSH from being blocked after k3s operations:

```bash
sudo iptables -I INPUT -s 192.168.86.0/24 -j ACCEPT
sudo iptables -I FORWARD -s 192.168.86.0/24 -j ACCEPT
sudo apt install iptables-persistent -y
sudo netfilter-persistent save
```

### SSH Setup

Enable SSH on Spark 2 for headless management from Spark 1:

```bash
# On Spark 2
sudo systemctl stop ssh.socket
sudo systemctl disable ssh.socket
sudo systemctl enable ssh
sudo systemctl start ssh
```

Enable password authentication in `/etc/ssh/sshd_config`:
```
PasswordAuthentication yes
```

From Spark 1, connect to Spark 2:
```bash
ssh moonlit@192.168.86.26
```

### DNS Troubleshooting

If DNS stops working after a network change:
```bash
sudo resolvectl flush-caches
sudo systemctl restart systemd-resolved
```

### iptables Troubleshooting

If SSH is blocked after a k3s restart:
```bash
sudo iptables -F
sudo iptables -X
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT
```

## Docker Configuration

Configure Docker for proper cgroup v2 compatibility:

```bash
sudo python3 -c "
import json, os
path = '/etc/docker/daemon.json'
d = json.load(open(path)) if os.path.exists(path) else {}
d['default-cgroupns-mode'] = 'host'
d['default-runtime'] = 'nvidia'
d['runtimes'] = {'nvidia': {'path': 'nvidia-container-runtime', 'args': []}}
json.dump(d, open(path, 'w'), indent=2)
"
sudo systemctl restart docker
sudo usermod -aG docker $USER
newgrp docker
```

## Verify Setup

```bash
# Check both nodes are reachable
ping 192.168.86.26

# Check SSH works
ssh moonlit@192.168.86.26

# Check Docker
docker info | grep "Cgroup Version"
```
