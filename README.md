
# Seva Sarathi — Server Orchestration & Deployment (`seva-deploy`)

Central deployment repository for the **Seva Sarathi** MEC (Multi-access Edge Computing) infrastructure. This repository provides unified setup scripts, `docker-compose` stack configurations, and Kubernetes manifests to launch the entire MEC edge stack on a server with a single command.

---

## 🏗️ Architecture Overview

The MEC server coordinates multiple streaming and telemetry pipelines across the physical deployment:

* **CCTV Cameras $\rightarrow$ Server:** WebRTC video ingestion (`webrtc-gateway`) for real-time computer vision, path planning, and heatmap generation.
* **AGV Fleet $\rightarrow$ Server:** ROS 2 DDS & MQTT telemetry (`ros2-core` & `mqtt-broker`) for navigation, status monitoring, and motor control.
* **Direct User Interface:** Web Application (`web-app`) dashboard connecting directly to the server to display real-time analytics and controls.
* **Server Controller Engine:** Coordinates CCTV vision feeds and AGV telemetry for mission dispatching.

---

## 📁 Repository Structure

```text
seva-deploy/
├── docker-compose.yml       # Production stack orchestration
├── setup.sh                 # One-click server initialization script
├── k8s/                     # MicroK8s manifests for Kubernetes production
│   ├── namespace.yml
│   ├── webrtc-gateway.yml
│   ├── mqtt-broker.yml
│   └── ros2-core.yml
└── README.md

```
## ⚡ Quickstart: One-Command Deployment
On a fresh MEC server connected to your Wi-Fi/LAN:
### Option A: Direct Script Pull
```bash
curl -sSL [https://raw.githubusercontent.com/seva-sarathi/seva-deploy/main/setup.sh](https://raw.githubusercontent.com/seva-sarathi/seva-deploy/main/setup.sh) | bash

```
### Option B: Clone & Run
```bash
git clone [https://github.com/seva-sarathi/seva-deploy.git](https://github.com/seva-sarathi/seva-deploy.git)
cd seva-deploy
chmod +x setup.sh
./setup.sh

```
## ⚙️ How setup.sh Works
 1. **Firewall Setup:** Opens ports 8080/tcp (WebRTC), 1883/tcp (MQTT), and 7400:7500/udp (ROS 2 DDS).
 2. **Container Fetch:** Pulls pre-built production images from the sevasarathi Docker Hub organization:
   * sevasarathi/webrtc-gateway:latest
   * sevasarathi/mqtt-broker:latest
   * sevasarathi/ros2-core:latest
 3. **Stack Launch:** Spins up all services in detached mode with host networking enabled for low-latency DDS discovery.
## 🌐 Active Service Endpoints
Once running, services are exposed directly on your server's LAN IP:
| Component | Protocol / Interface | Access Endpoint |
|---|---|---|
| **WebRTC CCTV Ingest** | HTTP / WebRTC | http://<SERVER_IP>:8080/ |
| **MQTT Broker** | TCP / MQTT | <SERVER_IP>:1883 |
| **ROS 2 DDS Network** | UDP Multicast | ROS_DOMAIN_ID=0 |
## 🧪 Testing with a Laptop Stand-In
To test the deployment before connecting physical CCTV cameras or AGVs:
 1. **Test CCTV Stream:**
   Open http://<SERVER_IP>:8080/ on your laptop browser and click **Publish** to send your laptop webcam feed to the server.
 2. **Test AGV Telemetry (MQTT):**
   Run the publisher script from your laptop pointing to the server's LAN IP:
   ```bash
   MQTT_BROKER=<SERVER_IP> python scripts/publisher.py
   
   ```
 3. **Test AGV Telemetry (ROS 2):**
   Publish directly to the /chatter topic on the same Wi-Fi network:
   ```bash
   export ROS_DOMAIN_ID=0
   ros2 topic pub /chatter std_msgs/msg/String "data: 'Hello World from Laptop'"
   
   ```
## 🛠️ Management Commands
```bash
# View real-time logs across all services
docker compose logs -f

# Check status of running containers
docker compose ps

# Restart the entire MEC stack
docker compose restart

# Stop all services
docker compose down

```

---
If you're transitioning from Docker Compose to Kubernetes, check out [How to deploy Docker compose to Kubernetes](https://www.youtube.com/watch?v=mbWdlay4evQ), which walks through converting Compose setups into Kubernetes manifests using `kompose`.

```
