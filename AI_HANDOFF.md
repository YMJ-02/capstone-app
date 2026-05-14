# AI 파트 핸드오프 문서

> 본 문서는 캡스톤 **낙상 감지 IoT 시스템**의 AI 파트(Python)를 담당하는 Claude Code 세션에 전달하기 위한 정리본입니다.
> **앱(Flutter) ↔ AI(Python) 연결 계약**을 정확히 맞추는 데 초점을 둡니다.

---

## 1. 프로젝트 한눈에 보기

- **목적**: 카메라 영상에서 사람의 자세(pose)를 추적해 **낙상**을 실시간 감지하고, 보호자용 모바일 앱에 즉시 알림 + 위치/연락 기능 제공
- **시나리오**: 독거 노인 또는 환자의 거주공간에 카메라를 설치 → 낙상 발생 시 보호자 스마트폰으로 알림 + 영상 클립 확인 + 119/112/보호자 전화 연결
- **레포 구조**
  - 루트: `requirements.txt`(파이썬 의존성), `.gitignore`
  - `falls_app-main/`: Flutter 앱(Android/iOS/Web 멀티플랫폼) + AI 퍼블리셔 + 샘플 녹화본
    - `lib/main.dart` — 단일 파일 Flutter 앱 (1,742 lines, 모든 페이지/위젯/Provider 포함)
    - `fall_publisher.py` — AI 파트 (MediaPipe + WebSocket 브로드캐스터)
    - `fall_recordings/` — 과거 낙상 영상 클립 샘플 (`fall_<unix_ts>.mp4`)
    - `pubspec.yaml` — Flutter 의존성

---

## 2. 시스템 아키텍처

```
 ┌────────────────────────┐         ┌──────────────────────────┐
 │   Python AI 퍼블리셔     │         │   Flutter 앱 (Web/Mobile) │
 │   fall_publisher.py    │         │       lib/main.dart      │
 │                        │         │                          │
 │  ① OpenCV 카메라 캡처    │         │  ⑤ WebSocket 구독         │
 │  ② MediaPipe Pose      │         │  ⑥ FallData 파싱          │
 │  ③ FallDetector 확률   │ ──ws──▶ │  ⑦ 대시보드/그래프/포즈     │
 │  ④ WebSocket 브로드캐스트│  :8765  │  ⑧ 낙상 시 알림 다이얼로그   │
 │                        │         │     + Hive 로컬 저장      │
 │  + Flask /health       │ ──http─▶│     + 119/112/보호자 호출 │
 │    (:8080)             │  헬스    │                          │
 └────────────────────────┘         └──────────────────────────┘
            │                                    │
            └──── (계획) MJPEG :81/stream ───────▶│  ⑨ LiveStreamPage (WebView)
            └──── (계획) Video clip 서빙 ─────────▶│  ⑩ Hist./Emergency 영상 재생
```

- **현재 구현된 데이터 흐름**: `WebSocket :8765` 단일 채널만 동작
- **미구현이지만 앱이 기대하는 엔드포인트**: ⑨ MJPEG 스트림(`:81/stream`), ⑩ 영상 클립 URL(`video_clip_url`) — 자세한 내용은 §5 참조

---

## 3. ⭐ 앱 ↔ AI 통신 계약 (가장 중요)

### 3.1 엔드포인트

| 항목                | URL                                  | 정의 위치                          | 상태       |
| ------------------- | ------------------------------------ | ---------------------------------- | ---------- |
| WebSocket (낙상 데이터) | `ws://localhost:8765`                | `AppConfig.wsUrl` (main.dart:27) / `WS_PORT` (fall_publisher.py:32) | ✅ 구현 완료 |
| HTTP 헬스/영상 서버   | `http://localhost:8080`              | `AppConfig.videoServerBase` (main.dart:28) / `FLASK_PORT` (fall_publisher.py:33) | ⚠️ 헬스 only |
| MJPEG 라이브 스트림  | `http://localhost:81/stream`         | `AppConfig.mjpegStreamUrl` (main.dart:29) | ❌ 미구현    |

- **호스트 주의**: 현재 `localhost` 고정. 실제 라즈베리파이/PC 분리 환경에서는 앱 빌드 시 `AppConfig.host` 를 IP로 변경하거나 빌드 인자로 주입할 필요가 있음.
- **시뮬레이터 모드**: `AppConfig.simulatorMode = false` (main.dart:32). `true`로 두면 AI 서버 없이 앱이 더미 데이터 자체 생성 (개발 편의용).

### 3.2 WebSocket 메시지 페이로드 스펙

**Python → Flutter (서버 → 클라이언트, 단방향 브로드캐스트)**

```jsonc
{
  "timestamp": 1735000000,      // int, Unix epoch(seconds)
  "fall_prob": 0.7234,          // float, 0.0 ~ 1.0 (소수점 4자리 권장)
  "status":    "FALL",          // "NORMAL" | "WARNING" | "FALL"
  "pose_data": [                // length=33 (MediaPipe Pose landmark)
    { "x": 0.5123, "y": 0.4456, "z": 0.0021, "visibility": 0.95 },
    ...
  ],
  "video_clip_url": null        // (선택) string, FALL 시 클립 URL. ❌ 현재 AI에서 안 보냄
}
```

**Flutter 측 파싱 로직** (`main.dart:54-68`, `FallData.fromJson`)
- `fall_prob` 누락 → 0.0
- `timestamp` 누락 → 현재 시각
- `status` 필드를 받긴 하지만, **Flutter가 prob 값으로 재계산**해서 덮어씀 (Python과 임계값 일치하면 동일 결과)
- `pose_data` 누락 → 빈 배열
- `video_clip_url` 누락 → null (현재는 항상 null)

> ⚠️ **변경 시 주의**: 필드명을 바꿀 거면 양쪽 다 동시에 수정해야 합니다. snake_case 유지 권장.

### 3.3 임계값(Threshold) 정리

| 의미              | Python (fall_publisher.py) | Flutter (main.dart) | 일치 여부 |
| ----------------- | -------------------------- | ------------------- | --------- |
| FALL 진입 임계값  | `FALL_THRESHOLD = 0.7` (L36)    | `FallData.fromJson` 내부 `>= 0.7` (L57) | ✅ 일치 |
| WARNING 진입 임계값 | `WARNING_THRESHOLD = 0.4` (L37) | `FallData.fromJson` 내부 `>= 0.4` (L58) | ✅ 일치 |
| 히스토리 저장 임계값 | (Python엔 없음, 항상 송신)    | `AppConfig.fallThreshold = 0.6` (L30, Hive 저장 컷오프)| 앱 전용 |
| 알림 다이얼로그 트리거 | —                          | `AppConfig.alertThreshold = 0.7` (L31) | 앱 전용 |

→ **AI 측에서 임계값을 변경**할 거면 `FallData.fromJson`의 하드코딩 `>= 0.7` / `>= 0.4` 도 같이 수정하거나, 차라리 **Python이 보낸 `status` 문자열을 그대로 신뢰**하도록 Dart를 고치는 게 깔끔합니다 (권장).

### 3.4 MediaPipe Pose 33-landmark 인덱스

Python에서 사용하는 주요 랜드마크(`fall_publisher.py:95-101`):

| index | 부위           | index | 부위              |
| ----- | -------------- | ----- | ----------------- |
| 0     | NOSE           | 23    | LEFT_HIP          |
| 11    | LEFT_SHOULDER  | 24    | RIGHT_HIP         |
| 12    | RIGHT_SHOULDER | 27    | LEFT_ANKLE        |
|       |                | 28    | RIGHT_ANKLE       |

Flutter 측에서 그리는 골격 연결선(`main.dart:965-969`, `_PoseOverlayWidget.connections`):
```
[0,1][1,2][2,3][3,7][0,4][4,5][5,6][6,8][9,10]      // 얼굴
[11,12][11,13][13,15][12,14][14,16]                  // 상체/팔
[11,23][12,24][23,24][23,25][25,27][24,26][26,28]    // 몸통/다리
```
→ MediaPipe 표준 인덱스 그대로 사용. 인덱스 매핑 변경하지 마세요.

### 3.5 현재 낙상 확률 계산 알고리즘 (참고용)

`FallDetector.calculate()` (fall_publisher.py:84-132) — 휴리스틱 기반:

| 신호                          | 가중치 / 산식                                       |
| ----------------------------- | --------------------------------------------------- |
| 머리가 엉덩이 아래            | `min(0.5, head_below_hip * 3.0)`                   |
| 어깨가 엉덩이 아래            | `min(0.4, shoulder_below_hip * 4.0)`               |
| 어깨 좌우 기울기              | `min(0.2, shoulder_tilt * 2.0)`                    |
| 체고 비율(어깨-발목) < 0.3    | +0.1                                                |
| 머리 y좌표 평균 속도(10프레임) | `min(0.2, avg_velocity * 10.0)`                    |
| 가시성 < 0.3                  | 강제 0.1 (저신뢰 프레임 무시)                       |

→ ML 모델로 교체할 경우, **출력 인터페이스(`fall_prob: float [0,1]`)만 유지**하면 앱은 그대로 동작합니다.

---

## 4. AI 파트 코드 빠른 투어

### `fall_publisher.py` 구성

| 섹션           | 라인     | 책임                                       |
| -------------- | -------- | ------------------------------------------ |
| 설정값         | 28-37    | 카메라 인덱스, 포트, 임계값                |
| MediaPipe 초기화 | 41-51    | `pose_detector` 글로벌 인스턴스           |
| WS 클라이언트 관리 | 57-78    | `connected_clients` set, `broadcast()`    |
| FallDetector   | 84-132   | 휴리스틱 확률 계산 클래스                  |
| `camera_loop()` | 140-211  | OpenCV 캡처 → MediaPipe → 페이로드 → WS 송신 |
| Flask `/health` | 217-224  | `{"status":"ok","ws_clients":N}`           |
| `main()`       | 230-247  | 이벤트 루프 + 카메라 스레드 + WS 서버 기동 |

### 의존성

- 핵심: `mediapipe==0.10.14`, `opencv-python`, `websockets`, `flask`, `numpy`
- 루트 `requirements.txt`는 venv 통째 freeze된 거대 목록이라 **그대로 설치하지 말 것**. AI 파트 전용 최소 셋만 따로 설치 권장:
  ```bash
  pip install mediapipe==0.10.14 opencv-python numpy websockets flask
  ```

---

## 5. 미구현 / TODO — AI 파트가 채워야 할 연결점

### 5.1 ❌ 영상 클립(`video_clip_url`) 자동 저장 + 서빙

- **앱이 기대하는 동작**
  - 낙상 감지(`FALL`) 발생 시 ±20초 클립이 `fall_recordings/fall_<timestamp>.mp4`에 저장
  - WebSocket 페이로드에 `video_clip_url: "http://<host>:8080/recordings/fall_<ts>.mp4"` 필드 포함
  - 앱은 이 URL을 `VideoPlayerPage`(main.dart:1530) 에서 `video_player` + `chewie` 로 재생
- **현재 상태**: `fall_recordings/` 디렉토리에 샘플 영상은 있지만, **`fall_publisher.py`는 영상 저장 로직이 없음**. Flask는 `/health`만 노출.
- **해야 할 작업**
  1. `camera_loop` 안에 롤링 버퍼(deque로 최근 20초 프레임 보관) 추가
  2. `status` 가 `NORMAL → FALL` 천이될 때 버퍼 flush + 이후 20초 캡처 → mp4 저장
  3. Flask에 `/recordings/<filename>` 정적 라우트 추가 (`send_from_directory`)
  4. WS 페이로드에 `video_clip_url` 채워 송신

### 5.2 ❌ MJPEG 라이브 스트리밍 (`:81/stream`)

- **앱이 기대하는 동작**: `LiveStreamPage`(main.dart:585) 의 WebView가 `<img src="http://<host>:81/stream">`을 로드 → 브라우저가 multipart/x-mixed-replace MJPEG로 디코딩
- **현재 상태**: 포트 81에 서버 자체가 없음
- **해야 할 작업** (둘 중 선택)
  - (간단) `fall_publisher.py` Flask 앱에 `/stream` 라우트를 추가하고 포트 8080으로 통일 → 앱 `AppConfig.mjpegStreamUrl` 도 같이 변경
  - (분리) ESP32-CAM 등 외부 카메라 모듈을 :81에 두는 IoT 시나리오 — 이 경우 fall_publisher는 별도 카메라 스트림을 구독하도록 변경
- 참고: MJPEG 응답 골격
  ```python
  @app.route("/stream")
  def stream():
      return Response(gen_frames(), mimetype="multipart/x-mixed-replace; boundary=frame")
  ```

### 5.3 ⚠️ 호스트 주소 하드코딩

- `AppConfig.host = 'localhost'` (main.dart:26) — 모바일 디바이스에서 실행하면 PC에 못 붙음
- 권장: `.env` 또는 빌드 시점 `--dart-define=API_HOST=192.168.x.x` 로 주입하도록 추후 리팩토링

### 5.4 ⚠️ `status` 이중 계산

- Python이 보낸 `status` 가 Flutter에서 무시됨(§3.2). 양쪽 임계값 동기화 또는 Flutter 신뢰 방식으로 통일 필요.

---

## 6. 책임 영역 분리 (제안)

| 영역              | 담당          | 비고                                             |
| ----------------- | ------------- | ------------------------------------------------ |
| 카메라 캡처/포즈 추출 | **AI (Python)** | MediaPipe → 추후 ML 모델 교체 가능               |
| 낙상 확률 계산    | **AI (Python)** | 휴리스틱 → LSTM/Transformer 업그레이드 여지       |
| 영상 클립 저장/서빙 | **AI (Python)** | §5.1, Flask 정적 서빙으로 충분                   |
| MJPEG 스트리밍   | **AI (Python)** | §5.2                                             |
| WebSocket 송신    | **AI (Python)** | 페이로드 스키마는 §3.2 고정 계약                  |
| 알림 UI / 다이얼로그 | **App (Flutter)** | 현재 완성                                        |
| 히스토리 저장(Hive) | **App (Flutter)** | 현재 완성                                        |
| 보호자 전화/119/112 | **App (Flutter)** | `url_launcher tel:` 스킴, 현재 완성              |

---

## 7. 로컬 개발 환경 / 실행 순서

```bash
# 1) AI 파트 (Python)
cd falls_app-main
python -m venv .venv && source .venv/bin/activate
pip install mediapipe==0.10.14 opencv-python numpy websockets flask
python fall_publisher.py
# → [WS] WebSocket 서버 시작: ws://localhost:8765
# → [Flask] http://localhost:8080/health

# 2) Flutter 앱 (별도 터미널)
cd falls_app-main
flutter pub get
flutter run -d chrome   # Web 권장 (현재 코드가 web_socket_channel 기반)
# 또는 모바일: flutter run (이 경우 AppConfig.host 를 PC IP로 변경 필요)
```

### 헬스 체크

```bash
curl http://localhost:8080/health
# {"status":"ok","ws_clients":1}
```

### WS 수동 테스트

```bash
# wscat 또는 websocat
websocat ws://localhost:8765
# → 매 프레임 JSON 페이로드가 흘러나와야 함
```

---

## 8. 트러블슈팅 체크리스트

| 증상                                       | 원인 후보                                                |
| ------------------------------------------ | -------------------------------------------------------- |
| 앱 대시보드에 "Python 서버 연결 실패"      | (1) `fall_publisher.py` 미실행, (2) 포트 8765 차단, (3) 모바일에서 localhost 사용 |
| 앱 상태가 항상 NORMAL                      | 카메라 가시성 < 0.3 — 조명/거리 확인, Python 콘솔의 `[전송]` 로그에 prob 값 확인 |
| 앱이 연결은 되는데 포즈 안 그려짐          | `pose_data` 가 비어 있음 — MediaPipe 가 사람 인식 못함   |
| FALL 떴는데 영상 재생 버튼이 없음          | §5.1 미구현 — `video_clip_url` 이 null 인 상태           |
| LiveStream 페이지가 "스트림 연결 불가"     | §5.2 미구현 — `:81/stream` 서버 없음                     |

---

## 9. 참고 파일 라인 인덱스 (Quick Jump)

- `falls_app-main/fall_publisher.py:46` — MediaPipe Pose 모델 설정
- `falls_app-main/fall_publisher.py:90` — `FallDetector.calculate` (확률 산식)
- `falls_app-main/fall_publisher.py:184` — WebSocket 페이로드 생성
- `falls_app-main/fall_publisher.py:240` — 메인 진입점 (스레드 구조)
- `falls_app-main/lib/main.dart:25` — `AppConfig` (호스트/포트/임계값)
- `falls_app-main/lib/main.dart:39` — `FallData` 모델 + JSON 파싱
- `falls_app-main/lib/main.dart:113` — `MqttService` (실제로는 WebSocket)
- `falls_app-main/lib/main.dart:585` — `LiveStreamPage` (MJPEG WebView)
- `falls_app-main/lib/main.dart:1530` — `VideoPlayerPage` (clip 재생)
