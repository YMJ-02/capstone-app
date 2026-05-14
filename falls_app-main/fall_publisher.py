#!/usr/bin/env python3
# ============================================================
# 낙상 감지 시스템 - WebSocket 버전 (Flutter Web 호환)
# fall_publisher.py
#
# 설치:
#   pip install mediapipe==0.10.14
#   pip install opencv-python numpy
#   pip install websockets flask
#
# 실행:
#   python fall_publisher.py
#
# Flutter Web: ws://localhost:8765 로 자동 연결됩니다
# ============================================================

import cv2
import mediapipe as mp
import asyncio
import json
import time
import threading
import os
import websockets
from flask import Flask, jsonify

# ============================================================
# 설정값 (필요시 수정)
# ============================================================

CAMERA_INDEX  = 0        # 카메라 번호 (보통 0)
WS_PORT       = 8765     # WebSocket 포트
FLASK_PORT    = 8080     # Flask health check 포트
VIDEO_SAVE_DIR= "fall_recordings"

FALL_THRESHOLD    = 0.7
WARNING_THRESHOLD = 0.4

# ============================================================
# MediaPipe 초기화
# ============================================================

mp_pose    = mp.solutions.pose
mp_drawing = mp.solutions.drawing_utils

pose_detector = mp_pose.Pose(
    min_detection_confidence=0.5,
    min_tracking_confidence=0.5,
    model_complexity=1,
)
print("[시스템] MediaPipe 로드 성공")

# ============================================================
# WebSocket 클라이언트 관리
# ============================================================

connected_clients: set = set()

async def ws_handler(websocket):
    connected_clients.add(websocket)
    print(f"[WS] 클라이언트 연결 ({len(connected_clients)}개 접속 중)")
    try:
        await websocket.wait_closed()
    finally:
        connected_clients.discard(websocket)
        print(f"[WS] 클라이언트 종료 ({len(connected_clients)}개 접속 중)")

async def broadcast(payload: dict):
    if not connected_clients:
        return
    message = json.dumps(payload)
    dead = set()
    for ws in connected_clients:
        try:
            await ws.send(message)
        except websockets.exceptions.ConnectionClosed:
            dead.add(ws)
    connected_clients.difference_update(dead)

# ============================================================
# 낙상 감지 알고리즘
# ============================================================

class FallDetector:
    def __init__(self):
        self.prev_landmarks   = None
        self.velocity_history = []
        self.history_size     = 10

    def calculate(self, landmarks) -> float:
        if landmarks is None:
            return 0.0

        lm = landmarks.landmark
        nose           = lm[mp_pose.PoseLandmark.NOSE]
        left_shoulder  = lm[mp_pose.PoseLandmark.LEFT_SHOULDER]
        right_shoulder = lm[mp_pose.PoseLandmark.RIGHT_SHOULDER]
        left_hip       = lm[mp_pose.PoseLandmark.LEFT_HIP]
        right_hip      = lm[mp_pose.PoseLandmark.RIGHT_HIP]
        left_ankle     = lm[mp_pose.PoseLandmark.LEFT_ANKLE]
        right_ankle    = lm[mp_pose.PoseLandmark.RIGHT_ANKLE]

        # 가시성 낮으면 무시
        if min(nose.visibility, left_shoulder.visibility,
               right_shoulder.visibility, left_hip.visibility,
               right_hip.visibility) < 0.3:
            return 0.1

        avg_shoulder_y    = (left_shoulder.y  + right_shoulder.y) / 2
        avg_hip_y         = (left_hip.y       + right_hip.y)      / 2
        avg_ankle_y       = (left_ankle.y     + right_ankle.y)    / 2
        body_height_ratio = abs(avg_shoulder_y - avg_ankle_y)
        shoulder_tilt     = abs(left_shoulder.y - right_shoulder.y)
        head_below_hip    = max(0.0, nose.y - avg_hip_y)
        shoulder_below_hip= max(0.0, avg_shoulder_y - avg_hip_y)

        prob  = 0.0
        prob += min(0.5, head_below_hip     * 3.0)
        prob += min(0.4, shoulder_below_hip * 4.0)
        prob += min(0.2, shoulder_tilt      * 2.0)
        if body_height_ratio < 0.3:
            prob += 0.1

        if self.prev_landmarks:
            velocity = abs(nose.y - self.prev_landmarks.landmark[mp_pose.PoseLandmark.NOSE].y)
            self.velocity_history.append(velocity)
            if len(self.velocity_history) > self.history_size:
                self.velocity_history.pop(0)
            prob += min(0.2, (sum(self.velocity_history) / len(self.velocity_history)) * 10.0)

        self.prev_landmarks = landmarks
        return min(1.0, max(0.0, prob))

# ============================================================
# 카메라 루프 (별도 스레드에서 실행)
# ============================================================

_loop: asyncio.AbstractEventLoop | None = None

def camera_loop():
    os.makedirs(VIDEO_SAVE_DIR, exist_ok=True)

    cap = cv2.VideoCapture(CAMERA_INDEX)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH,  640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)

    if not cap.isOpened():
        print(f"[카메라 오류] index={CAMERA_INDEX} 열기 실패")
        return
    print(f"[카메라] 연결 성공 (index={CAMERA_INDEX})")

    detector = FallDetector()

    while True:
        ret, frame = cap.read()
        if not ret:
            continue

        # MediaPipe 처리
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        rgb.flags.writeable = False
        result = pose_detector.process(rgb)
        rgb.flags.writeable = True

        # 낙상 확률 계산
        fall_prob = detector.calculate(result.pose_landmarks)

        # 포즈 직렬화
        pose_data = []
        if result.pose_landmarks:
            for lm in result.pose_landmarks.landmark:
                pose_data.append({
                    "x":          round(lm.x,          4),
                    "y":          round(lm.y,          4),
                    "z":          round(lm.z,          4),
                    "visibility": round(lm.visibility, 4),
                })

        # 상태 판정
        if   fall_prob >= FALL_THRESHOLD:    status = "FALL"
        elif fall_prob >= WARNING_THRESHOLD: status = "WARNING"
        else:                                status = "NORMAL"

        payload = {
            "timestamp": int(time.time()),
            "fall_prob": round(fall_prob, 4),
            "status":    status,
            "pose_data": pose_data,
        }

        print(f"[전송] {status} | {fall_prob:.1%} | 접속 클라이언트 {len(connected_clients)}개")

        # WebSocket 브로드캐스트
        if _loop is not None and connected_clients:
            asyncio.run_coroutine_threadsafe(broadcast(payload), _loop)

        # 화면 표시
        if result.pose_landmarks:
            mp_drawing.draw_landmarks(frame, result.pose_landmarks, mp_pose.POSE_CONNECTIONS)

        color = (0, 255, 0) if status == "NORMAL" else \
                (0, 165, 255) if status == "WARNING" else (0, 0, 255)
        cv2.putText(frame, f"Fall Prob: {fall_prob:.1%} [{status}]",
                    (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 1, color, 2)
        cv2.imshow("Fall Detection", frame)

        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

    cap.release()
    cv2.destroyAllWindows()

# ============================================================
# Flask (health check)
# ============================================================

flask_app = Flask(__name__)

@flask_app.route("/health")
def health():
    return jsonify({"status": "ok", "ws_clients": len(connected_clients)})

def run_flask():
    flask_app.run(host="0.0.0.0", port=FLASK_PORT, debug=False, use_reloader=False)

# ============================================================
# 메인
# ============================================================

async def main():
    global _loop
    _loop = asyncio.get_running_loop()

    # Flask
    threading.Thread(target=run_flask, daemon=True).start()
    print(f"[Flask] http://localhost:{FLASK_PORT}/health")

    # 카메라 스레드
    threading.Thread(target=camera_loop, daemon=True).start()

    # WebSocket 서버
    print(f"[WS] WebSocket 서버 시작: ws://localhost:{WS_PORT}")
    print("[안내] Flutter 앱 실행 후 자동 연결됩니다")
    print("[안내] 카메라 창에서 q 키 또는 Ctrl+C 로 종료")

    async with websockets.serve(ws_handler, "0.0.0.0", WS_PORT):
        await asyncio.Future()  # 영구 실행

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[종료 완료]")