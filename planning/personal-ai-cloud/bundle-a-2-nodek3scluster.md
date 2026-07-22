# Bundle A: 2-Node k3s Cluster (spark-a1, spark-a2)

**Hardware:** 2x DGX Spark (GB10 Grace Blackwell, ARM64, 128 GB unified memory each) connected via ConnectX-7 200 GbE.
**Role in the fleet:** Baseline bundle. Flannel VXLAN networking, NCCL over TCP sockets. Multi-node tensor parallel works but pays the kernel-stack tax on every all-reduce. This is the control group against Bundle B's RDMA path.

## 1. Host Preparation (both nodes, Ansible)

Per node:

```bash
nvidia-smi                                  # verify driver baseline
sudo apt update && sudo apt install -y nfs-common nfs-kernel-server open-iscsi jq
# nvidia-container-toolkit (repo + apt install, same on both)
curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up --ssh
```

No Docker daemon. Set static IPs or DHCP reservations on the ConnectX-7 interfaces, e.g. `10.10.0.1/30` (a1) and `10.10.0.2/30` (a2), MTU 9000. Verify:

```bash
ping -M do -s 8972 10.10.0.2   # jumbo frames pass
iperf3 -c 10.10.0.2            # sanity: should approach line rate
```

## 2. Install k3s

**spark-a1 (server):**

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable=servicelb \
  --write-kubeconfig-mode=644 \
  --node-name=spark-a1 \
  --node-ip=<LAN-IP-a1> \
  --flannel-iface=<LAN-interface>" sh -
sudo cat /var/lib/rancher/k3s/server/node-token   # save for the agent
```

**spark-a2 (agent):**

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://<LAN-IP-a1>:6443 \
  K3S_TOKEN=<node-token> \
  INSTALL_K3S_EXEC="agent --node-name=spark-a2 \
  --node-ip=<LAN-IP-a2> \
  --flannel-iface=<LAN-interface>" sh -
```

Deliberate choice: Flannel rides the LAN interface. The ConnectX-7 link is left out of the CNI and used directly by NCCL (host networking) so the fast link still carries tensor-parallel traffic, just over TCP.

## 3. GPU Runtime (both nodes)

RuntimeClass `nvidia` + NVIDIA device plugin daemonset (chart `nvdp/nvidia-device-plugin`, `runtimeClassName=nvidia`). Smoke test a GPU pod on EACH node using nodeSelector to confirm both schedule.

## 4. Namespaces, GitOps

Namespaces: `inference`, `monitoring`, `storage`, `gitops`, ResourceQuotas per namespace.

```bash
flux bootstrap github --owner=<gh-user> --repository=spark-fleet \
  --path=clusters/bundle-a-k3s --personal
```

Fleet repo layout (shared with Bundle B):

```
spark-fleet/
  clusters/
    bundle-a-k3s/       # Traefik ingress, TCP NCCL env overrides
    bundle-b-rke2/      # nginx ingress, RDMA NCCL env overrides
  bases/
    inference/          # shared vLLM, AIBrix, LWS manifests
    monitoring/         # shared LGTM + DCGM
```

SOPS + age per cluster for secrets.

## 5. Storage: Shared Model Cache

NFS export from spark-a1 so both nodes share one HuggingFace cache:

```bash
# spark-a1
sudo mkdir -p /data/hf-cache
echo "/data/hf-cache <LAN-IP-a2>(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
sudo exportfs -ra
# spark-a2
sudo mkdir -p /data/hf-cache
sudo mount -t nfs <LAN-IP-a1>:/data/hf-cache /data/hf-cache   # plus fstab entry
```

Pods on both nodes mount hostPath `/data/hf-cache` as `HF_HOME`.

## 6. Inference

### Single-node models (fit in 128 GB)
Standard vLLM Deployment per model, image `nvcr.io/nvidia/vllm-openai:latest` (only viable ARM64 image), `runtimeClassName: nvidia`, GPU limit 1, AIBrix in front for routing and autoscaling.

### Multi-node models (need both nodes, TCP NCCL)
Install the LeaderWorkerSet controller, then:

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: vllm-large
  namespace: inference
spec:
  replicas: 1
  leaderWorkerTemplate:
    size: 2
    restartPolicy: RecreateGroupOnPodRestart
    leaderTemplate:
      metadata: {labels: {role: leader}}
      spec:
        hostNetwork: true
        dnsPolicy: ClusterFirstWithHostNet
        runtimeClassName: nvidia
        containers:
        - name: vllm-leader
          image: nvcr.io/nvidia/vllm-openai:latest
          command: ["sh","-c"]
          args:
          - >
            ray start --head --port=6379 &&
            vllm serve <large-model>
            --tensor-parallel-size 2
            --distributed-executor-backend ray
            --gpu-memory-utilization 0.90
          env:
          - {name: HF_HOME, value: /models}
          - {name: NCCL_SOCKET_IFNAME, value: <connectx-iface>}
          - {name: GLOO_SOCKET_IFNAME, value: <connectx-iface>}
          - {name: NCCL_DEBUG, value: INFO}
          resources: {limits: {nvidia.com/gpu: 1}}
          volumeMounts: [{name: models, mountPath: /models}]
        volumes: [{name: models, hostPath: {path: /data/hf-cache}}]
    workerTemplate:
      spec:
        hostNetwork: true
        dnsPolicy: ClusterFirstWithHostNet
        runtimeClassName: nvidia
        containers:
        - name: vllm-worker
          image: nvcr.io/nvidia/vllm-openai:latest
          command: ["sh","-c"]
          args: [">-", "ray start --address=$(LWS_LEADER_ADDRESS):6379 --block"]
          env:
          - {name: HF_HOME, value: /models}
          - {name: NCCL_SOCKET_IFNAME, value: <connectx-iface>}
          - {name: NCCL_DEBUG, value: INFO}
          resources: {limits: {nvidia.com/gpu: 1}}
          volumeMounts: [{name: models, mountPath: /models}]
        volumes: [{name: models, hostPath: {path: /data/hf-cache}}]
```

Key points:
- `hostNetwork: true` + `NCCL_SOCKET_IFNAME=<connectx-iface>` pins NCCL to the 200 GbE link instead of the LAN. Without this, all-reduces ride Flannel VXLAN and get dramatically worse.
- NCCL logs must show the socket transport pinned to the ConnectX interface. Expect `NET/Socket`; that is correct for this bundle. `NET/IB` belongs to Bundle B.
- ARM64: standard Ray images are unusable; Ray ships inside the NGC vLLM image, which is why the pattern above starts Ray from that image.

## 7. Monitoring

kube-prometheus-stack, dcgm-exporter (both nodes), Loki (SingleBinary), Tempo, OTel Collector funnel. Watch during multi-node runs: GPU SM utilization dips during all-reduce phases are the visible signature of the TCP sync tax. Record tokens/sec for the benchmark table.

## 8. Verification Checklist

- [ ] Both nodes Ready, arm64
- [ ] GPU pod schedules and runs nvidia-smi on each node
- [ ] Jumbo frames pass on ConnectX link, iperf3 near line rate
- [ ] Single-node vLLM serves on /v1/models
- [ ] LWS group forms; NCCL log shows socket transport on the ConnectX interface
- [ ] Multi-node model generates tokens end to end
- [ ] Benchmark recorded: tokens/sec, time-to-first-token, GPU util during decode
- [ ] Flux reconciles bases identically to Bundle B

## Notes

An RDMA path on this bundle is technically possible (Multus and the NVIDIA network operator are CNI-agnostic and can sit alongside Flannel), but leaving Bundle A on TCP is the point: it is the baseline that quantifies what RDMA buys on Bundle B. If Bundle B wins decisively, the convergence move is to reinstall Bundle A as RKE2 and join the fleet pattern, not to retrofit Flannel.
