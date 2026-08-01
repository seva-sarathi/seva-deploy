#!/bin/bash
set -e

echo "=========================================="
echo "   Seva Sarathi MEC Server Setup Script   "
echo "=========================================="

# 1. Configure firewall rules for LAN connectivity
echo "[1/3] Configuring firewall ports for LAN..."
if command -v ufw > /dev/null; then
    sudo ufw allow 8080/tcp comment 'WebRTC Gateway (CCTV)' || true
    sudo ufw allow 1883/tcp comment 'MQTT Broker (AGV)' || true
    sudo ufw allow 7400:7500/udp comment 'ROS2 DDS Multicast' || true
fi

# 2. Pull latest images from Docker Hub
echo "[2/3] Pulling latest containers from sevasarathi organization..."
docker compose pull

# 3. Spin up all services
echo "[3/3] Starting Seva Sarathi MEC services..."
docker compose up -d

echo ""
echo "=========================================="
echo "   MEC Server Services Ready & Running!   "
echo "=========================================="
echo "  - WebRTC (CCTV Ingest): http://$(hostname -I | awk '{print $1}'):8080"
echo "  - MQTT Broker (AGV):     $(hostname -I | awk '{print $1}'):1883"
echo "  - ROS 2 DDS Domain ID:   0"
echo "=========================================="
