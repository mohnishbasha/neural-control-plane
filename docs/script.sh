#!/usr/bin/env bash
# =============================================================================
# setup-cluster.sh — DGX Spark 2-node AI cluster automated setup
#
# Covers (in order):
#   Step 1 — dgx-spark-setup.md  : static IPs, iptables, Docker
#   Step 2 — cuda-updates.md     : OS + CUDA updates
#   Step 3 — k3s-setup.md        : k3s, GPU Operator, Helm, namespaces
#   Step 4 — kuberay-setup.md    : KubeRay operator + cross-node networking
#   Step 5 — vllm-setup.md       : HF token secret + RayCluster with vLLM
#   Step 6 — aibrix-setup.md     : AIBrix routing layer
#   Step 7 — cluster-setup.md    : Prometheus + Grafana monitoring
#
# BEFORE RUNNING — fill in all values marked PLACEHOLDER.
# Then run on Spark 1 (the master node):
#
#   bash setup-cluster.sh [flags]
#
# Or pass values as flags instead of editing this file:
#
#   bash setup-cluster.sh \
#     --spark1-ip <IP> \
#     --spark2-ip <IP> \
#     --spark2-user <USER> \
#     --spark1-hostname <K8S_NODE_NAME> \
#     --spark2-hostname <K8S_NODE_NAME> \
#     --hf-token <TOKEN>
#
# Optional flags:
#   --skip-step N   Skip a specific step (repeatable, e.g. --skip-step 1 --skip-step 2)
#   --dry-run       Print every command without executing
#   --model <ID>    HuggingFace model ID to serve (default: see PLACEHOLDER below)
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION — edit these or pass as flags
# =============================================================================

# IP address of Spark 1 (master / control plane)
SPARK1_IP="PLACEHOLDER_SPARK1_IP"                  # e.g. 192.168.1.10

# IP address of Spark 2 (worker)
SPARK2_IP="PLACEHOLDER_SPARK2_IP"                  # e.g. 192.168.1.11

# SSH username on Spark 2 (used for cross-node setup instructions)
SPARK2_USER="PLACEHOLDER_SPARK2_SSH_USER"          # e.g. ubuntu

# Local subnet in CIDR notation (used for iptables LAN rules)
LAN_CIDR="PLACEHOLDER_LAN_CIDR"                    # e.g. 192.168.1.0/24

# Default gateway IP
GATEWAY_IP="PLACEHOLDER_GATEWAY_IP"                # e.g. 192.168.1.1

# Kubernetes node name for Spark 1 (from: kubectl get nodes)
SPARK1_HOSTNAME="PLACEHOLDER_SPARK1_K8S_HOSTNAME"  # e.g. spark-node1

# Kubernetes node name for Spark 2 (from: kubectl get nodes)
SPARK2_HOSTNAME="PLACEHOLDER_SPARK2_K8S_HOSTNAME"  # e.g. spark-node2

# HuggingFace API token (required for model download in Step 5)
HF_TOKEN="PLACEHOLDER_HUGGINGFACE_TOKEN"

# HuggingFace model ID to serve via vLLM
VLLM_MODEL="PLACEHOLDER_VLLM_MODEL_ID"             # e.g. Qwen/Qwen2.5-7B-Instruct

# GPU memory fraction for vLLM KV cache (0.0–1.0)
GPU_MEMORY_UTIL="0.85"

# Max concurrent sequences vLLM will serve
MAX_NUM_SEQS="4"

# =============================================================================
# DO NOT EDIT BELOW THIS LINE (unless you know what you're doing)
# =============================================================================

DRY_RUN=false
SKIP_STEPS=()

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[$(date +%T)]${RESET} $*"; }
ok()   { echo -e "${GREEN}✓${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET}  $*"; }
die()  { echo -e "${RED}✗${RESET} $*" >&2; exit 1; }
run()  {
  if $DRY_RUN; then echo -e "${YELLOW}[dry-run]${RESET} $*"
  else eval "$*"; fi
}
skip_step() {
  local n=$1
  for s in "${SKIP_STEPS[@]:-}"; do [[ "$s" == "$n" ]] && return 0; done
  return 1
}

# ── Flag parsing ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --spark1-ip)       SPARK1_IP="$2";       shift 2 ;;
    --spark2-ip)       SPARK2_IP="$2";       shift 2 ;;
    --spark2-user)     SPARK2_USER="$2";     shift 2 ;;
    --spark1-hostname) SPARK1_HOSTNAME="$2"; shift 2 ;;
    --spark2-hostname) SPARK2_HOSTNAME="$2"; shift 2 ;;
    --lan-cidr)        LAN_CIDR="$2";        shift 2 ;;
    --gateway)         GATEWAY_IP="$2";      shift 2 ;;
    --hf-token)        HF_TOKEN="$2";        shift 2 ;;
    --model)           VLLM_MODEL="$2";      shift 2 ;;
    --skip-step)       SKIP_STEPS+=("$2");   shift 2 ;;
    --dry-run)         DRY_RUN=true;         shift ;;
    *) die "Unknown argument: $1. Run with --help for usage." ;;
  esac
done

# ── Validate required placeholders are filled ────────────────────────────────
MISSING=()
for VAR in SPARK1_IP SPARK2_IP SPARK2_USER LAN_CIDR GATEWAY_IP \
           SPARK1_HOSTNAME SPARK2_HOSTNAME HF_TOKEN VLLM_MODEL; do
  VAL="${!VAR}"
  if [[ "$VAL" == PLACEHOLDER* ]]; then
    MISSING+=("$VAR")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo -e "${RED}${BOLD}ERROR — the following required values are still placeholders:${RESET}"
  for VAR in "${MISSING[@]}"; do
    echo -e "  ${RED}✗${RESET} $VAR = ${!VAR}"
  done
  echo ""
  echo "Fill them in at the top of this script or pass them as flags."
  echo "Run with --dry-run to preview what will happen before committing."
  exit 1
fi

# ── Print config summary ─────────────────────────────────────────────────────
echo -e "${BOLD}=====================================================${RESET}"
echo -e "${BOLD} DGX Spark Cluster Setup${RESET}"
echo -e "${BOLD}=====================================================${RESET}"
echo "  Spark 1 IP / hostname : ${SPARK1_IP} / ${SPARK1_HOSTNAME}"
echo "  Spark 2 IP / hostname : ${SPARK2_IP} / ${SPARK2_HOSTNAME}"
echo "  Spark 2 SSH user      : ${SPARK2_USER}"
echo "  LAN CIDR              : ${LAN_CIDR}"
echo "  Gateway               : ${GATEWAY_IP}"
echo "  vLLM model            : ${VLLM_MODEL}"
echo "  HF token              : ${HF_TOKEN:0:8}... (truncated)"
echo "  Dry run               : ${DRY_RUN}"
[[ ${#SKIP_STEPS[@]} -gt 0 ]] && echo "  Skipping steps        : ${SKIP_STEPS[*]}"
echo ""

# =============================================================================
# STEP 1 — dgx-spark-setup.md: Static IPs, iptables, Docker
# =============================================================================
if ! skip_step 1; then
  log "${BOLD}Step 1/7 — Static IP, iptables, Docker (run on Spark 1)${RESET}"

  # Detect active network connection name
  CONN=$(nmcli -g NAME con show --active | head -1)
  log "Active connection: ${CONN}"

  run sudo nmcli con mod "\"${CONN}\"" \
    ipv4.addresses "${SPARK1_IP}/24" \
    ipv4.gateway "${GATEWAY_IP}" \
    ipv4.dns 8.8.8.8 \
    ipv4.method manual
  run sudo nmcli con up "\"${CONN}\""

  # iptables: allow all LAN traffic (idempotent)
  run "sudo iptables -C INPUT   -s ${LAN_CIDR} -j ACCEPT 2>/dev/null || sudo iptables -I INPUT   -s ${LAN_CIDR} -j ACCEPT"
  run "sudo iptables -C FORWARD -s ${LAN_CIDR} -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -s ${LAN_CIDR} -j ACCEPT"
  run sudo apt install -y iptables-persistent
  run sudo netfilter-persistent save

  # Docker: cgroup v2 + NVIDIA runtime
  run sudo python3 -c "
import json, os
path = '/etc/docker/daemon.json'
d = json.load(open(path)) if os.path.exists(path) else {}
d['default-cgroupns-mode'] = 'host'
d['default-runtime'] = 'nvidia'
d['runtimes'] = {'nvidia': {'path': 'nvidia-container-runtime', 'args': []}}
json.dump(d, open(path, 'w'), indent=2)
print('Docker daemon.json updated')
"
  run sudo systemctl restart docker
  run "sudo usermod -aG docker \$USER"

  warn "--------------------------------------------------------------"
  warn "Spark 2 network config must be done manually via SSH:"
  warn "  ssh ${SPARK2_USER}@${SPARK2_IP}"
  warn "  Then run the same nmcli + iptables + Docker commands,"
  warn "  substituting SPARK2_IP (${SPARK2_IP}) as the static address."
  warn "--------------------------------------------------------------"

  ok "Step 1 complete (Spark 1)"
fi

# =============================================================================
# STEP 2 — cuda-updates.md: OS + CUDA updates
# =============================================================================
if ! skip_step 2; then
  log "${BOLD}Step 2/7 — OS + CUDA updates (Spark 1)${RESET}"

  run sudo apt update
  run sudo apt dist-upgrade -y

  DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "unknown")
  log "NVIDIA driver version detected: ${DRIVER}"

  warn "--------------------------------------------------------------"
  warn "Spark 2 must be updated separately:"
  warn "  ssh ${SPARK2_USER}@${SPARK2_IP} \\"
  warn "    'sudo apt update && sudo apt dist-upgrade -y'"
  warn "Or use the DGX Dashboard on Spark 2 directly."
  warn "--------------------------------------------------------------"

  ok "Step 2 complete (Spark 1)"
fi

# =============================================================================
# STEP 3 — k3s-setup.md: k3s, GPU Operator, Helm, namespaces
# =============================================================================
if ! skip_step 3; then
  log "${BOLD}Step 3/7 — k3s cluster${RESET}"

  # Install k3s on Spark 1 (master)
  if ! command -v k3s &>/dev/null; then
    log "Installing k3s..."
    run "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--write-kubeconfig-mode 644 --disable=traefik' sh -"
    run sleep 10
  else
    ok "k3s already installed"
  fi

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  grep -q "KUBECONFIG=/etc/rancher/k3s/k3s.yaml" ~/.bashrc || \
    echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> ~/.bashrc

  warn "--------------------------------------------------------------"
  warn "JOIN SPARK 2 TO THE CLUSTER — do this manually:"
  warn ""
  warn "  1. On Spark 1, get the join token:"
  warn "       sudo cat /var/lib/rancher/k3s/server/node-token"
  warn ""
  warn "  2. On Spark 2, run:"
  warn "       curl -sfL https://get.k3s.io | \\"
  warn "         K3S_URL=https://${SPARK1_IP}:6443 \\"
  warn "         K3S_TOKEN=<TOKEN_FROM_STEP_1> \\"
  warn "         sh -"
  warn ""
  warn "  3. Back on Spark 1, label the worker node:"
  warn "       kubectl label node ${SPARK2_HOSTNAME} \\"
  warn "         node-role.kubernetes.io/worker=worker"
  warn "--------------------------------------------------------------"
  warn "Press ENTER once Spark 2 is joined and shows Ready, or Ctrl-C to exit."
  $DRY_RUN || read -r

  # Verify both nodes ready
  run kubectl get nodes

  # Install Helm
  if ! command -v helm &>/dev/null; then
    log "Installing Helm..."
    run "curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  else
    ok "Helm already installed"
  fi

  # NVIDIA GPU Operator
  if ! helm status gpu-operator -n gpu-operator &>/dev/null; then
    log "Installing NVIDIA GPU Operator..."
    run helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
    run helm repo update
    run helm install gpu-operator nvidia/gpu-operator \
      --namespace gpu-operator \
      --create-namespace \
      --wait --timeout 10m
  else
    ok "GPU Operator already installed"
  fi

  # Create application namespaces
  for ns in core-services qqq-data snackonai monitoring; do
    run "kubectl create namespace ${ns} --dry-run=client -o yaml | kubectl apply -f -"
  done

  ok "Step 3 complete"
fi

# =============================================================================
# STEP 4 — kuberay-setup.md: KubeRay operator + cross-node networking check
# =============================================================================
if ! skip_step 4; then
  log "${BOLD}Step 4/7 — KubeRay operator${RESET}"

  if ! helm status kuberay-operator -n kuberay-system &>/dev/null; then
    log "Installing KubeRay operator (pinned to Spark 1)..."
    run helm repo add kuberay https://ray-project.github.io/kuberay-helm/
    run helm repo update
    run helm install kuberay-operator kuberay/kuberay-operator \
      --namespace kuberay-system \
      --create-namespace \
      --set "nodeSelector.kubernetes\\.io/hostname=${SPARK1_HOSTNAME}" \
      --wait --timeout 5m
  else
    ok "KubeRay already installed"
  fi

  # Cross-node networking validation
  log "Validating cross-node pod networking..."
  run "kubectl run net-test-node1 \
    --image=busybox \
    --overrides='{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${SPARK1_HOSTNAME}\"}}}' \
    --command -- sleep 60 2>/dev/null || true"
  run "kubectl run net-test-node2 \
    --image=busybox \
    --overrides='{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${SPARK2_HOSTNAME}\"}}}' \
    --command -- sleep 60 2>/dev/null || true"
  run sleep 15

  NODE2_POD_IP=$(kubectl get pod net-test-node2 -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
  if [[ -n "$NODE2_POD_IP" ]]; then
    run "kubectl exec net-test-node1 -- ping -c 4 ${NODE2_POD_IP}" && \
      ok "Cross-node networking OK" || \
      warn "Ping failed — check Flannel CNI is running on both nodes"
  else
    warn "Could not get pod IP for net-test-node2 — check pod status manually"
  fi
  run kubectl delete pod net-test-node1 net-test-node2 --ignore-not-found

  ok "Step 4 complete"
fi

# =============================================================================
# STEP 5 — vllm-setup.md: HF token secret + RayCluster + vLLM
# =============================================================================
if ! skip_step 5; then
  log "${BOLD}Step 5/7 — vLLM deployment${RESET}"

  warn "--------------------------------------------------------------"
  warn "NGC REGISTRY LOGIN required to pull the vLLM image."
  warn "  docker login nvcr.io"
  warn "  Username: \$oauthtoken"
  warn "  Password: <your NGC API key from ngc.nvidia.com>"
  warn ""
  warn "Then create the NGC pull secret in Kubernetes:"
  warn "  kubectl create secret docker-registry ngc-secret \\"
  warn "    --docker-server=nvcr.io \\"
  warn "    --docker-username='\$oauthtoken' \\"
  warn "    --docker-password=<NGC_API_KEY> \\"
  warn "    -n core-services"
  warn "--------------------------------------------------------------"
  warn "Press ENTER once NGC login is done, or Ctrl-C to skip vLLM."
  $DRY_RUN || read -r

  # HuggingFace token secret
  run "kubectl create secret generic hf-token \
    --from-literal=token='${HF_TOKEN}' \
    -n core-services \
    --dry-run=client -o yaml | kubectl apply -f -"

  # Deploy RayCluster with vLLM
  log "Deploying RayCluster + vLLM (first startup may take ~25 min for model download)..."
  run kubectl apply -f - <<EOF
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: vllm-cluster
  namespace: core-services
spec:
  rayVersion: '2.49.2'
  headGroupSpec:
    rayStartParams:
      dashboard-host: '0.0.0.0'
      num-gpus: '1'
    template:
      spec:
        nodeSelector:
          kubernetes.io/hostname: ${SPARK1_HOSTNAME}
        containers:
        - name: ray-head
          image: nvcr.io/nvidia/vllm:25.09-py3
          imagePullSecrets:
          - name: ngc-secret
          command: ["/bin/bash", "-c"]
          args:
          - |
            ray start --head \
              --dashboard-host=0.0.0.0 \
              --num-gpus=1 \
              --block &
            sleep 30
            python3 -m vllm.entrypoints.openai.api_server \
              --model ${VLLM_MODEL} \
              --tensor-parallel-size 2 \
              --distributed-executor-backend ray \
              --host 0.0.0.0 \
              --port 8000 \
              --gpu-memory-utilization ${GPU_MEMORY_UTIL} \
              --max-num-seqs ${MAX_NUM_SEQS}
          env:
          - name: HF_TOKEN
            valueFrom:
              secretKeyRef:
                name: hf-token
                key: token
          resources:
            limits:
              nvidia.com/gpu: "1"
              memory: "100Gi"
            requests:
              nvidia.com/gpu: "1"
              memory: "100Gi"
          ports:
          - containerPort: 8000
          - containerPort: 8265
  workerGroupSpecs:
  - replicas: 1
    minReplicas: 1
    maxReplicas: 1
    groupName: worker-group
    rayStartParams:
      num-gpus: '1'
    template:
      spec:
        nodeSelector:
          kubernetes.io/hostname: ${SPARK2_HOSTNAME}
        containers:
        - name: ray-worker
          image: nvcr.io/nvidia/vllm:25.09-py3
          imagePullSecrets:
          - name: ngc-secret
          command: ["/bin/bash", "-c"]
          args:
          - |
            ray start \
              --address=vllm-cluster-head-svc.core-services.svc.cluster.local:6379 \
              --num-gpus=1 \
              --block
          env:
          - name: HF_TOKEN
            valueFrom:
              secretKeyRef:
                name: hf-token
                key: token
          resources:
            limits:
              nvidia.com/gpu: "1"
              memory: "100Gi"
            requests:
              nvidia.com/gpu: "1"
              memory: "100Gi"
EOF

  # Poll for startup
  log "Polling for vLLM startup (timeout: 30 min)..."
  HEAD_POD=""
  for i in $(seq 1 60); do
    HEAD_POD=$(kubectl get pods -n core-services -l ray.io/node-type=head \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -n "$HEAD_POD" ]] && break
    sleep 10
  done

  if [[ -n "$HEAD_POD" ]]; then
    for i in $(seq 1 90); do
      READY=$(kubectl logs -n core-services "$HEAD_POD" --tail=10 2>/dev/null \
        | grep -c "Application startup complete" || true)
      [[ "$READY" -gt 0 ]] && ok "vLLM ready: ${HEAD_POD}" && break
      [[ $((i % 6)) -eq 0 ]] && log "Still waiting... ($((i * 10))s elapsed)"
      sleep 10
    done
  else
    warn "Head pod did not appear — check: kubectl get pods -n core-services"
  fi

  ok "Step 5 complete"
fi

# =============================================================================
# STEP 6 — aibrix-setup.md: AIBrix routing layer
# =============================================================================
if ! skip_step 6; then
  log "${BOLD}Step 6/7 — AIBrix v0.6.0${RESET}"

  if ! kubectl get namespace aibrix-system &>/dev/null; then
    log "Installing AIBrix dependencies..."
    run kubectl apply \
      -f https://github.com/vllm-project/aibrix/releases/download/v0.6.0/aibrix-dependency-v0.6.0.yaml \
      --server-side --force-conflicts
    run sleep 15

    log "Installing AIBrix core..."
    run kubectl apply \
      -f https://github.com/vllm-project/aibrix/releases/download/v0.6.0/aibrix-core-v0.6.0.yaml

    log "Waiting for AIBrix controller to be ready..."
    run kubectl wait \
      --for=condition=ready pod \
      -l app=aibrix-controller-manager \
      -n aibrix-system \
      --timeout=300s
  else
    ok "AIBrix already installed"
  fi

  ok "Step 6 complete"
fi

# =============================================================================
# STEP 7 — cluster-setup.md: Prometheus + Grafana monitoring
# =============================================================================
if ! skip_step 7; then
  log "${BOLD}Step 7/7 — Monitoring stack (Prometheus + Grafana)${RESET}"

  if ! helm status monitoring -n monitoring &>/dev/null; then
    log "Installing kube-prometheus-stack..."
    run helm repo add prometheus-community \
      https://prometheus-community.github.io/helm-charts
    run helm repo update
    run helm install monitoring prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      --create-namespace \
      --wait --timeout 10m
  else
    ok "Monitoring already installed"
  fi

  ok "Step 7 complete"
fi

# =============================================================================
# Final summary
# =============================================================================
echo ""
echo -e "${BOLD}=====================================================${RESET}"
echo -e "${BOLD} Setup complete — final verification${RESET}"
echo -e "${BOLD}=====================================================${RESET}"

log "Node status:"
kubectl get nodes -o wide

echo ""
log "Unhealthy pods (if any):"
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded \
  2>/dev/null | grep -v "^NAMESPACE" | head -20 || echo "  All pods running."

echo ""
log "Grafana admin password:"
kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d && echo \
  || warn "Monitoring not ready — check: kubectl get pods -n monitoring"

echo ""
echo -e "${GREEN}${BOLD}Access Grafana:${RESET}"
echo "  kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80"
echo "  Open: http://localhost:3000"
echo ""
echo -e "${GREEN}${BOLD}Test vLLM:${RESET}"
echo "  HEAD=\$(kubectl get pods -n core-services -l ray.io/node-type=head -o name | head -1)"
echo "  kubectl exec -n core-services \$HEAD -- curl -s http://localhost:8000/v1/models"
