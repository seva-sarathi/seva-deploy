#!/bin/bash
set -e

echo "=========================================="
echo "  Seva Sarathi MicroK8s Deployment Script "
echo "=========================================="

# 1. Check if MicroK8s is installed
if ! command -v microk8s > /dev/null; then
    echo "[!] MicroK8s is not installed. Installing via snap..."
    sudo snap install microk8s --classic
    sudo usermod -a -G microk8s $USER
    sudo microk8s status --wait-ready
fi

# 2. Enable MicroK8s Addons
echo "[1/3] Enabling required MicroK8s addons..."
microk8s enable dns storage ingress

# 3. Configure Firewall
echo "[2/3] Open firewall ports..."
if command -v ufw > /dev/null; then
    sudo ufw allow 8080/tcp comment 'WebRTC Gateway' || true
    sudo ufw allow 1883/tcp comment 'MQTT Broker' || true
    sudo ufw allow 7400:7500/udp comment 'ROS2 DDS Multicast' || true
fi

# 4. Apply Kubernetes Manifests
echo "[3/3] Deploying seva-deploy stack to MicroK8s..."
microk8s kubectl apply -f k8s/

echo ""
echo "=========================================="
echo "   MicroK8s Deployment Successful!        "
echo "=========================================="
echo "Check running pods with:"
echo "  microk8s kubectl get pods -n seva-sarathi"
