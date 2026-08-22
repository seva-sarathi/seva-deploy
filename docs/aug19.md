# Seva Sarathi: WebRTC Gateway & ROS 2 Telemetry Integration
This document covers the end-to-end architecture, source code, container configurations, and execution workflow for integrating real-time WebRTC video stream processing with ROS 2 obstacle telemetry publishing.
## 1. System Architecture Overview
```
[ Web Client / Camera ] 
          │ (WebRTC Offer/Answer & Video Stream)
          ▼
┌─────────────────────────────────────────────────────────────┐
│ mec_webrtc Container (aiohttp + aiortc)                    │
│                                                             │
│  1. WebRTC Signaling Endpoint (/offer)                      │
│  2. MediaRelay Subscriber                                   │
│  3. Async Vision Worker (YOLOv8 Inference every 10s)        │
│  4. ROS 2 Publisher Node (`webrtc_vision_publisher`)       │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           │ DDS Protocol over Host Network
                           │ Topic: `/seva/corridor_status`
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ ros2_core Container / External Listener                      │
│                                                             │
│  ROS 2 Subscriber Node (`corridor_listener`)                │
└─────────────────────────────────────────────────────────────┘
```
## 2. WebRTC Gateway & Vision Engine
webrtc-gateway/signaling/server.py 
This server serves as the WebRTC signaling gateway and stream relay. It handles incoming camera tracks, executes non-blocking YOLO object detection at 10-second intervals in a thread executor, and publishes corridor status payloads directly to the ROS 2 DDS network.
```python
"""
MEC WebRTC signaling + relay server for Seva Sarathi.

Roles:
  - publisher: the laptop/robot browser that opens "/" and shares its webcam.
  - viewer(s): any web client that opens "/view" or integrates the stream.
"""

import asyncio
import json
import logging
import os
import ssl
import time
import uuid

import cv2
from aiohttp import web
from aiortc import RTCPeerConnection, RTCSessionDescription
from aiortc.contrib.media import MediaRelay
from ultralytics import YOLO

# ROS 2 Integration
import rclpy
from rclpy.node import Node
from std_msgs.msg import String

try:
    from receiver import StreamRecorder
except ImportError:
    StreamRecorder = None

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("sevasarathi.webrtc")

WEB_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # .../web
STATIC_DIR = os.path.join(WEB_ROOT, "static")

RECORD_STREAM = os.environ.get("RECORD_STREAM", "false").lower() == "true"
RECORDINGS_DIR = os.environ.get("RECORDINGS_DIR", "/data/recordings")

pcs = set()
relay = MediaRelay()
recorder = (
    StreamRecorder(RECORDINGS_DIR)
    if (RECORD_STREAM and StreamRecorder)
    else None
)

# Single-publisher state tracking
publisher_state = {"track": None, "pc": None, "pc_id": None, "yolo_task": None}

# Initialize YOLO model & ROS 2 Globals
yolo_model = YOLO("yolov8n.pt")
OBSTACLE_CLASSES = {0, 24, 26, 28, 56, 57, 59}  # person, chair, backpack, suitcase, couch, bed
ros_node = None
status_pub = None


def init_ros():
    """Initializes rclpy and sets up the vision publisher node."""
    global ros_node, status_pub
    if not rclpy.ok():
        rclpy.init(args=None)
    ros_node = Node("webrtc_vision_publisher")
    status_pub = ros_node.create_publisher(String, "/seva/corridor_status", 10)
    logger.info("ROS 2 Node 'webrtc_vision_publisher' initialized on topic /seva/corridor_status")


def run_yolo_inference(frame_bgr, corridor_id="Corridor_A"):
    """Runs YOLO obstacle detection on an OpenCV image matrix."""
    results = yolo_model(frame_bgr, verbose=False)[0]
    
    obstacle_count = sum(
        1 for box in results.boxes
        if int(box.cls[0]) in OBSTACLE_CLASSES and float(box.conf[0]) >= 0.40
    )
    
    status = "BLOCKED" if obstacle_count >= 3 else ("CLEAR" if obstacle_count == 0 else "PARTIALLY_OBSTRUCTED")
    
    return {
        "corridor_id": corridor_id,
        "obstacle_count": obstacle_count,
        "status": status,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S")
    }


async def yolo_processing_loop(relayed_track, corridor_id="Corridor_A"):
    """Async task sampling frames every 10s and publishing telemetry to ROS 2."""
    logger.info("Started 10-second YOLO vision loop for %s", corridor_id)
    loop = asyncio.get_running_loop()

    while True:
        try:
            frame = await relayed_track.recv()
            img = frame.to_ndarray(format="bgr24")
            
            # Execute inference in executor to avoid blocking asyncio event loop
            telemetry = await loop.run_in_executor(None, run_yolo_inference, img, corridor_id)
            
            if status_pub:
                msg = String()
                msg.data = json.dumps(telemetry)
                status_pub.publish(msg)
                logger.info("[ROS 2 OUT -> /seva/corridor_status]: %s", msg.data)

            await asyncio.sleep(10)

        except asyncio.CancelledError:
            logger.info("YOLO processing loop cancelled for %s", corridor_id)
            break
        except Exception as e:
            logger.error("Error in YOLO processing loop: %s", e)
            await asyncio.sleep(1)


async def cancel_publisher_yolo_task():
    """Cancels background vision task on stream drop."""
    if publisher_state["yolo_task"]:
        publisher_state["yolo_task"].cancel()
        publisher_state["yolo_task"] = None


async def index(request):
    return web.FileResponse(os.path.join(STATIC_DIR, "index.html"))


async def viewer_page(request):
    return web.FileResponse(os.path.join(STATIC_DIR, "viewer.html"))


async def status(request):
    return web.json_response(
        {
            "publisher_connected": publisher_state["track"] is not None,
            "recording": RECORD_STREAM,
            "active_peer_connections": len(pcs),
        }
    )


async def offer(request):
    """Publisher endpoint: camera client posts offer SDP here."""
    params = await request.json()
    offer_desc = RTCSessionDescription(sdp=params["sdp"], type=params["type"])

    pc = RTCPeerConnection()
    pc_id = f"publisher-{uuid.uuid4().hex[:8]}"
    pcs.add(pc)

    @pc.on("connectionstatechange")
    async def on_connectionstatechange():
        if pc.connectionState in ("failed", "closed", "disconnected"):
            await pc.close()
            pcs.discard(pc)
            if publisher_state["pc_id"] == pc_id:
                publisher_state["track"] = None
                publisher_state["pc_id"] = None
                await cancel_publisher_yolo_task()
                if recorder:
                    await recorder.stop()

    @pc.on("track")
    def on_track(track):
        if track.kind == "video":
            publisher_state["track"] = track
            publisher_state["pc_id"] = pc_id
            
            if recorder:
                asyncio.ensure_future(
                    recorder.start(relay.subscribe(track), pc_id)
                )

            relayed_track = relay.subscribe(track)
            publisher_state["yolo_task"] = asyncio.create_task(
                yolo_processing_loop(relayed_track, corridor_id="Corridor_A")
            )

        @track.on("ended")
        async def on_ended():
            if publisher_state["pc_id"] == pc_id:
                publisher_state["track"] = None
                publisher_state["pc_id"] = None
                await cancel_publisher_yolo_task()
                if recorder:
                    await recorder.stop()

    await pc.setRemoteDescription(offer_desc)
    answer = await pc.createAnswer()
    await pc.setLocalDescription(answer)

    return web.json_response(
        {
            "sdp": pc.localDescription.sdp,
            "type": pc.localDescription.type,
        }
    )


async def viewer_offer(request):
    """Viewer endpoint: browser clients subscribe to active relay."""
    if publisher_state["track"] is None:
        return web.json_response(
            {"error": "no active publisher stream"}, status=503
        )

    params = await request.json()
    offer_desc = RTCSessionDescription(sdp=params["sdp"], type=params["type"])

    pc = RTCPeerConnection()
    pcs.add(pc)

    @pc.on("connectionstatechange")
    async def on_connectionstatechange():
        if pc.connectionState in ("failed", "closed", "disconnected"):
            await pc.close()
            pcs.discard(pc)

    pc.addTrack(relay.subscribe(publisher_state["track"]))

    await pc.setRemoteDescription(offer_desc)
    answer = await pc.createAnswer()
    await pc.setLocalDescription(answer)

    return web.json_response(
        {
            "sdp": pc.localDescription.sdp,
            "type": pc.localDescription.type,
        }
    )


async def on_shutdown(app):
    await cancel_publisher_yolo_task()
    if recorder:
        await recorder.stop()
    await asyncio.gather(*(pc.close() for pc in pcs))
    pcs.clear()
    if rclpy.ok():
        ros_node.destroy_node()
        rclpy.shutdown()


@web.middleware
async def cors_middleware(request, handler):
    if request.method == "OPTIONS":
        response = web.Response()
    else:
        response = await handler(request)

    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS, PUT, DELETE"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    return response


def create_app():
    app = web.Application(middlewares=[cors_middleware])
    app.on_shutdown.append(on_shutdown)

    app.router.add_get("/", index)
    app.router.add_get("/view", viewer_page)
    app.router.add_get("/status", status)
    app.router.add_post("/offer", offer)
    app.router.add_post("/viewer/offer", viewer_offer)
    app.router.add_static("/static/", STATIC_DIR)

    return app


if __name__ == "__main__":
    init_ros()
    app = create_app()

    ssl_context = None
    cert_file = os.environ.get("SSL_CERT_FILE")
    key_file = os.environ.get("SSL_KEY_FILE")

    if cert_file and key_file and os.path.exists(cert_file) and os.path.exists(key_file):
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_context.load_cert_chain(cert_file, key_file)

    port = int(os.environ.get("PORT", 8081))
    web.run_app(app, host="0.0.0.0", port=port, ssl_context=ssl_context)
```

## 3. ROS 2 Telemetry Listener Node
ros2-core/corridor_listener.py
A standalone ROS 2 node that consumes JSON payloads published on /seva/corridor_status.

```python
import json
import rclpy
from rclpy.node import Node
from std_msgs.msg import String


class CorridorTelemetrySubscriber(Node):
    def __init__(self):
        super().__init__("corridor_telemetry_subscriber")
        self.subscription = self.create_subscription(
            String,
            "/seva/corridor_status",
            self.listener_callback,
            10
        )
        self.get_logger().info("Listening on topic: /seva/corridor_status")

    def listener_callback(self, msg):
        try:
            data = json.loads(msg.data)
            self.get_logger().info(
                f"[{data['corridor_id']}] Status: {data['status']} | Obstacles: {data['obstacle_count']} | Time: {data['timestamp']}"
            )
        except json.JSONDecodeError:
            self.get_logger().error(f"Malformed JSON: {msg.data}")


def main(args=None):
    rclpy.init(args=args)
    subscriber = CorridorTelemetrySubscriber()
    try:
        rclpy.spin(subscriber)
    except KeyboardInterrupt:
        pass
    finally:
        subscriber.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
```

## 4. Infrastructure & Docker Configuration
docker-compose.yml
Both containers share the host network mode (network_mode: host) to allow zero-configuration ROS 2 DDS discovery across container boundaries.
```bash
version: '3.8'

services:
  mec_webrtc:
    build:
      context: ./webrtc-gateway
      dockerfile: Dockerfile
    container_name: mec_webrtc
    network_mode: host
    environment:
      - PORT=8081
      - ROS_DOMAIN_ID=42
      - RECORD_STREAM=false
    volumes:
      - ./data/recordings:/data/recordings
    restart: unless-stopped

  ros2_core:
    build:
      context: ./ros2-core
      dockerfile: Dockerfile
    container_name: ros2_core
    network_mode: host
    environment:
      - ROS_DOMAIN_ID=42
    command: python3 /app/corridor_listener.py
    restart: unless-stopped
```

## 5. Deployment & Telemetry Verification
1. Start Containers
``docker compose up --build -d``

2. Stream Video Stream
Open http://localhost:8081 in a browser and start video publishing.
3. Monitor WebRTC Gateway Logs
``docker logs -f mec_webrtc``

Expected Log:
__[ROS 2 OUT -> /seva/corridor_status]: {"corridor_id": "Corridor_A", "obstacle_count": 0, "status": "CLEAR", "timestamp": "2026-08-19 23:10:00"}__
4. Inspect ROS 2 Topic Output
``docker exec -it ros2_core bash -c "source /opt/ros/humble/setup.bash && ros2 topic echo /seva/corridor_status"``

To learn more about containerizing robotics applications, you can watch this Docker for ROS 2 Tutorial, which explains how to structure Docker containers for ROS 2 setups.

YouTube video views will be stored in your YouTube History, and your data will be stored and used by YouTube according to its Terms of Service
