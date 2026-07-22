# Bundle B: 2-Node RKE2 Cluster with GPUDirect RDMA (spark-b1, spark-b2)

**Hardware:** 2x DGX Spark (GB10 Grace Blackwell, ARM64, 128 GB unified memory each) connected via ConnectX-7 200 GbE.
**Role in the fleet:** The full-fat path. Cilium native routing for the pod network, Multus + NVIDIA network operator providing a dedicated RDMA secondary interface, NCCL over GPUDirect RDMA (RoCE v2). Multi-node tensor parallel at 2-5 us per all-reduce instead of Bundle A's 50-100 us.

## 1. Host Preparation (both nodes, Ansible)

Same baseline as Bundle A: nvidia-smi verified, nvidia-container-toolkit, Tailscale with SSH, no Docker daemon.

RoCE fabric config on the ConnectX-7 interfaces (both nodes):

```bash
# static IPs: 10.20.0.1/30 (b1), 10.20.0.2/30 (b2), MTU 9000
sudo ip link set <cx7-iface> mtu 9000

# RoCE v2 lossless-ish config: PFC on priority 3, ECN enabled
sudo mlnx_qos -i <cx7-iface> --pfc 0,0,0,1,0,0,0,0
sudo cma_roce_tos -d <rdma-dev> -t 106
echo 1 | sudo tee /sys/class/net/<cx7-iface>/ecn/roce_np/enable/3 2>/dev/null || true

# verify RDMA devices exist
ibv_devinfo
rdma link show
```

Baseline RDMA validation BEFORE Kubernetes touches anything:

```bash
# b1: ib_write_bw -d <rdma-dev> --report_gbits
# b2: ib_write_bw -d <rdma-dev> --report_gbits 10.20.0.1
```

Expect close to 200 Gb/s. If this fails, nothing downstream will work; fix the fabric first.

## 2. Install RKE2 with Cilium

**spark-b1 (server).** Config before install:

```bash
sudo mkdir -p /etc/rancher/rke2
cat <<'EOF' | sudo tee /etc/rancher/rke2/config.yaml
node-name: spark-b1
cni: multus,cilium
write-kubeconfig-mode: "0644"
node-ip: <LAN-IP-b1>
EOF
```

Note `cni: multus,cilium`: RKE2 deploys Multus as a meta-CNI in front of Cilium natively; no hand-rolled Multus install needed.

Cilium HelmChartConfig (native routing, before first start):

```bash
sudo mkdir -p /var/lib/rancher/rke2/server/manifests
cat <<'EOF' | sudo tee /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    kubeProxyReplacement: true
    routingMode: native
    ipv4NativeRoutingCIDR: 10.42.0.0/16
    autoDirectNodeRoutes: true
    devices: ["<LAN-interface>"]
    hubble:
      enabled: true
      relay: {enabled: true}
      ui: {enabled: true}
EOF
curl -sfL https://get.rke2.io | sudo sh -
sudo systemctl enable --now rke2-server
sudo cat /var/lib/rancher/rke2/server/node-token
```

`devices` pins Cilium to the LAN interface so it never claims the ConnectX-7 link; that link belongs to the RDMA data plane.

**spark-b2 (agent):**

```bash
sudo mkdir -p /etc/rancher/rke2
cat <<'EOF' | sudo tee /etc/rancher/rke2/config.yaml
server: https://<LAN-IP-b1>:9345
token: <node-token>
node-name: spark-b2
node-ip: <LAN-IP-b2>
EOF
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=agent sudo sh -
sudo systemctl enable --now rke2-agent
```

Verify: both nodes Ready, `cilium-dbg status` shows `Routing: Network: Native`.

## 3. GPU Runtime

RKE2 auto-detects the NVIDIA toolkit into its containerd config. Apply RuntimeClass `nvidia` + device plugin as in Bundle A. GPU smoke test on both nodes.

## 4. RDMA Data Plane: NVIDIA Network Operator

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm install network-operator nvidia/network-operator \
  -n nvidia-network-operator --create-namespace \
  --set nfd.enabled=true
```

NicClusterPolicy exposing the ConnectX-7 as an RDMA shared device:

```yaml
apiVersion: mellanox.com/v1alpha1
kind: NicClusterPolicy
metadata:
  name: nic-cluster-policy
spec:
  rdmaSharedDevicePlugin:
    image: k8s-rdma-shared-dev-plugin
    repository: ghcr.io/mellanox
    version: latest
    config: |
      {
        "configList": [{
          "resourceName": "rdma_shared_device_a",
          "rdmaHcaMax": 63,
          "selectors": {"ifNames": ["<cx7-iface>"]}
        }]
      }
```

NetworkAttachmentDefinition for the secondary interface (host-device keeps it simple for a 2-node point-to-point link):

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-net
  namespace: inference
spec:
  config: |
    {
      "cniVersion": "0.4.0",
      "type": "macvlan",
      "master": "<cx7-iface>",
      "mode": "bridge",
      "ipam": {
        "type": "whereabouts",
        "range": "10.20.1.0/24"
      }
    }
```

Verify nodes advertise the resource:

```bash
kubectl get nodes -o json | jq '.items[].status.allocatable' | grep rdma
```

## 5. Namespaces, GitOps, Storage

Identical to Bundle A: same namespaces and quotas, Flux bootstrap at `--path=clusters/bundle-b-rke2` in the shared spark-fleet repo, SOPS + age. NFS shared HF cache exported from spark-b1, mounted on spark-b2, hostPath `/data/hf-cache` in pods.

Shared workloads come from `bases/`; this cluster's kustomization swaps ingress to nginx and adds the RDMA annotations below.

## 6. Inference: Multi-Node vLLM over RDMA

Same LWS shape as Bundle A with three differences: the RDMA network annotation, the RDMA resource request, and NCCL env pointed at IB instead of sockets.

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
      metadata:
        annotations:
          k8s.v1.cni.cncf.io/networks: rdma-net
      spec:
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
          - {name: NCCL_IB_HCA, value: <rdma-dev>}
          - {name: NCCL_IB_GID_INDEX, value: "3"}
          - {name: NCCL_DEBUG, value: INFO}
          securityContext:
            capabilities: {add: ["IPC_LOCK"]}
          resources:
            limits:
              nvidia.com/gpu: 1
              rdma/rdma_shared_device_a: 1
          volumeMounts: [{name: models, mountPath: /models}]
        volumes: [{name: models, hostPath: {path: /data/hf-cache}}]
    workerTemplate:
      metadata:
        annotations:
          k8s.v1.cni.cncf.io/networks: rdma-net
      spec:
        runtimeClassName: nvidia
        containers:
        - name: vllm-worker
          image: nvcr.io/nvidia/vllm-openai:latest
          command: ["sh","-c"]
          args: [">-", "ray start --address=$(LWS_LEADER_ADDRESS):6379 --block"]
          env:
          - {name: HF_HOME, value: /models}
          - {name: NCCL_IB_HCA, value: <rdma-dev>}
          - {name: NCCL_IB_GID_INDEX, value: "3"}
          - {name: NCCL_DEBUG, value: INFO}
          securityContext:
            capabilities: {add: ["IPC_LOCK"]}
          resources:
            limits:
              nvidia.com/gpu: 1
              rdma/rdma_shared_device_a: 1
          volumeMounts: [{name: models, mountPath: /models}]
        volumes: [{name: models, hostPath: {path: /data/hf-cache}}]
```

The acceptance test: NCCL logs must show `NET/IB` as the selected transport, not `NET/Socket`. If you see Socket, RDMA is not being used; check GID index (RoCE v2 usually index 3), IPC_LOCK capability, and the rdma resource allocation.

Cross-node collective benchmark before serving traffic:

```bash
# nccl-tests all_reduce_perf across both nodes (build from source on ARM64
# inside the NGC image, standard images unavailable)
./all_reduce_perf -b 8 -e 256M -f 2 -g 1
```

AIBrix in front routes small models to single-node deployments and large models to the LWS group, same as Bundle A.

## 7. Monitoring

Shared LGTM + DCGM from bases, plus Bundle-B extras:
- RoCE counters (pause frames, ECN marks, retransmits) via mlnx exporters into Prometheus
- Hubble for pod-network flow visibility
- NCCL debug logs to Loki during bring-up, dialed down after

## 8. Verification Checklist

- [ ] ib_write_bw near 200 Gb/s host-to-host before k8s
- [ ] Both nodes Ready; cilium native routing confirmed
- [ ] rdma_shared_device_a allocatable on both nodes
- [ ] LWS pods get the rdma-net secondary interface (check ip addr in pod)
- [ ] NCCL log shows NET/IB transport
- [ ] all_reduce_perf bus bandwidth sane (record for the comparison table)
- [ ] Multi-node model serves end to end through nginx ingress with TLS
- [ ] Same benchmark suite as Bundle A recorded

## 9. The Comparison That Matters

Run the identical large model with identical prompts on both bundles and record:

| Metric | Bundle A (TCP) | Bundle B (RDMA) |
|---|---|---|
| all_reduce_perf bus BW | | |
| Time to first token | | |
| Decode tokens/sec | | |
| GPU SM util during decode | | |
| CPU util during inference | | |

Expected: Bundle B wins decode throughput and shows flatter GPU utilization (less stall during syncs) and much lower CPU burn. The size of the gap tells you exactly what the RDMA stack complexity is worth, and whether converging the whole fleet on RKE2 (4-node, or 2x2) is justified.

## 10. Convergence Options After the Bake-Off

- **RKE2 wins (likely):** Reinstall Bundle A as RKE2 via Ansible. Then either run two independent 2-node RKE2 clusters (blast-radius isolation, prod/dev split), or note that a single 4-node cluster only helps if a model needs more than 256 GB, which requires inter-bundle networking the bundles do not have (ConnectX links are intra-bundle point-to-point). Two 2-node clusters is the natural end state.
- **k3s wins on ops simplicity and RDMA gap is small:** Keep k3s fleet-wide for single-node serving; accept the multi-node ceiling.
