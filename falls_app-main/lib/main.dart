// ============================================================
// 낙상 감지 IoT 앱 — WebSocket 버전 (Flutter Web 호환)
// lib/main.dart
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:webview_flutter/webview_flutter.dart';

// ============================================================
// 설정값
// ============================================================

class AppConfig {
  static const String host = 'localhost';
  static const String wsUrl = 'ws://$host:8765';
  static const String videoServerBase = 'http://$host:8080';
  static const String mjpegStreamUrl  = 'http://$host:81/stream';
  static const double fallThreshold  = 0.6;
  static const double alertThreshold = 0.7;
  static const bool simulatorMode = false;
}

// ============================================================
// 데이터 모델
// ============================================================

class FallData {
  final int timestamp;
  final double fallProb;
  final String status;
  final List<dynamic> poseData;
  final String? videoClipUrl;

  FallData({
    required this.timestamp,
    required this.fallProb,
    required this.status,
    required this.poseData,
    this.videoClipUrl,
  });

  factory FallData.fromJson(Map<String, dynamic> json) {
    final prob = (json['fall_prob'] as num?)?.toDouble() ?? 0.0;
    String st;
    if (prob >= 0.7)      st = 'FALL';
    else if (prob >= 0.4) st = 'WARNING';
    else                   st = 'NORMAL';

    return FallData(
      timestamp:    json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      fallProb:     prob,
      status:       st,
      poseData:     json['pose_data'] as List<dynamic>? ?? [],
      videoClipUrl: json['video_clip_url'] as String?,
    );
  }

  DateTime get dateTime => DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
}

class FallEvent {
  final int timestamp;
  final double fallProb;
  final String status;
  final String? videoClipUrl;

  FallEvent({required this.timestamp, required this.fallProb,
             required this.status, this.videoClipUrl});

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp, 'fall_prob': fallProb,
    'status': status, 'video_clip_url': videoClipUrl,
  };

  factory FallEvent.fromJson(Map<String, dynamic> j) => FallEvent(
    timestamp:    j['timestamp'] as int,
    fallProb:     (j['fall_prob'] as num).toDouble(),
    status:       j['status'] as String,
    videoClipUrl: j['video_clip_url'] as String?,
  );

  DateTime get dateTime => DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
}

class EmergencyContact {
  final String name, phone, relation;
  EmergencyContact({required this.name, required this.phone, required this.relation});

  Map<String, dynamic> toJson() => {'name': name, 'phone': phone, 'relation': relation};
  factory EmergencyContact.fromJson(Map<String, dynamic> j) => EmergencyContact(
    name: j['name'] as String, phone: j['phone'] as String, relation: j['relation'] as String,
  );
}

// ============================================================
// WebSocket 서비스
// ============================================================

enum MqttConnectionState { disconnected, connecting, connected, error }

class MqttService {
  static final MqttService _instance = MqttService._internal();
  factory MqttService() => _instance;
  MqttService._internal();

  final StreamController<FallData> _dataController =
      StreamController<FallData>.broadcast();
  Stream<FallData> get dataStream => _dataController.stream;

  MqttConnectionState _connectionState = MqttConnectionState.disconnected;
  MqttConnectionState get connectionState => _connectionState;

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  Timer? _simulatorTimer;

  void _connectWs() {
    _connectionState = MqttConnectionState.connecting;
    print('[WS] 연결 시도: ${AppConfig.wsUrl}');

    try {
      _channel = WebSocketChannel.connect(Uri.parse(AppConfig.wsUrl));
      _connectionState = MqttConnectionState.connected;
      print('[WS] 연결 성공');

      _channel!.stream.listen(
        (message) {
          try {
            final jsonMap = jsonDecode(message as String) as Map<String, dynamic>;
            _dataController.add(FallData.fromJson(jsonMap));
          } catch (e) {
            print('[WS] 파싱 오류: $e');
          }
        },
        onError: (e) {
          print('[WS] 오류: $e');
          _connectionState = MqttConnectionState.error;
          _scheduleReconnect();
        },
        onDone: () {
          print('[WS] 연결 끊김 — 3초 후 재연결');
          _connectionState = MqttConnectionState.disconnected;
          _scheduleReconnect();
        },
      );
    } catch (e) {
      print('[WS] 연결 실패: $e');
      _connectionState = MqttConnectionState.error;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _connectWs);
  }

  final Random _random = Random();
  double _currentProb = 0.1;
  bool _simulatingFall = false;
  int _fallCountdown = 0;

  void _startSimulator() {
    _connectionState = MqttConnectionState.connected;
    _simulatorTimer?.cancel();
    _simulatorTimer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    print('[시뮬레이터] 테스트 모드 시작');
  }

  void _tick() {
    if (!_simulatingFall && _random.nextDouble() < 0.04) {
      _simulatingFall = true;
      _fallCountdown = 5;
    }
    if (_simulatingFall) {
      _currentProb = 0.65 + _random.nextDouble() * 0.3;
      if (--_fallCountdown <= 0) _simulatingFall = false;
    } else {
      _currentProb = (_currentProb * 0.7 + _random.nextDouble() * 0.35 * 0.3).clamp(0.0, 1.0);
    }

    String st;
    if (_currentProb >= 0.7)      st = 'FALL';
    else if (_currentProb >= 0.4) st = 'WARNING';
    else                           st = 'NORMAL';

    _dataController.add(FallData(
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      fallProb:  _currentProb,
      status:    st,
      poseData:  List.generate(33, (_) => {
        'x': _random.nextDouble(),
        'y': _random.nextDouble(),
        'z': _random.nextDouble() * 0.1,
        'visibility': 0.8 + _random.nextDouble() * 0.2,
      }),
      videoClipUrl: st == 'FALL'
          ? 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4'
          : null,
    ));
  }

  void start() {
    if (AppConfig.simulatorMode) {
      _startSimulator();
    } else {
      _connectWs();
    }
  }

  void dispose() {
    _simulatorTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _dataController.close();
  }
}

// ============================================================
// 로컬 저장소 (Hive)
// ============================================================

class StorageService {
  static const String _eventsBox   = 'fall_events_v2';
  static const String _contactsBox = 'emergency_contacts_v2';

  static Future<void> init() async {
    await Hive.initFlutter();
    await Hive.openBox<String>(_eventsBox);
    await Hive.openBox<String>(_contactsBox);
    await _initDefaultContacts();
  }

  static Future<void> _initDefaultContacts() async {
    final box = Hive.box<String>(_contactsBox);
    if (box.isEmpty) {
      await box.add(jsonEncode(
        EmergencyContact(name: '보호자 (아들/딸)', phone: '010-0000-0000', relation: '가족').toJson(),
      ));
    }
  }

  static Future<void> saveFallEvent(FallData d) async {
    if (d.fallProb < AppConfig.fallThreshold) return;
    await Hive.box<String>(_eventsBox).add(jsonEncode(
      FallEvent(timestamp: d.timestamp, fallProb: d.fallProb,
                status: d.status, videoClipUrl: d.videoClipUrl).toJson(),
    ));
  }

  static List<FallEvent> getFallEvents() {
    return Hive.box<String>(_eventsBox).values
        .map((s) => FallEvent.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList()..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  static List<EmergencyContact> getContacts() {
    return Hive.box<String>(_contactsBox).values
        .map((s) => EmergencyContact.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  static Future<void> addContact(EmergencyContact c) async {
    await Hive.box<String>(_contactsBox).add(jsonEncode(c.toJson()));
  }

  static Future<void> deleteContact(int index) async {
    final box  = Hive.box<String>(_contactsBox);
    final keys = box.keys.toList();
    if (index < keys.length) await box.delete(keys[index]);
  }

  static Future<void> clearHistory() async {
    await Hive.box<String>(_eventsBox).clear();
  }
}

// ============================================================
// Riverpod Providers
// ============================================================

final mqttServiceProvider = Provider<MqttService>((ref) {
  final s = MqttService()..start();
  ref.onDispose(s.dispose);
  return s;
});

final currentFallDataProvider = StreamProvider<FallData>((ref) {
  return ref.watch(mqttServiceProvider).dataStream;
});

final graphDataProvider = StateNotifierProvider<GraphDataNotifier, List<FallData>>(
  (_) => GraphDataNotifier(),
);

class GraphDataNotifier extends StateNotifier<List<FallData>> {
  GraphDataNotifier() : super([]);
  void addData(FallData d) {
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    state = [...state, d].where((x) => x.dateTime.isAfter(cutoff)).toList();
  }
}

final currentTabProvider      = StateProvider<int>((ref) => 0);
final emergencyBadgeProvider  = StateProvider<bool>((ref) => false);
final fallHistoryProvider     = StateProvider<List<FallEvent>>((ref) => StorageService.getFallEvents());
final contactsProvider        = StateProvider<List<EmergencyContact>>((ref) => StorageService.getContacts());
final latestEmergencyProvider = StateProvider<FallData?>((ref) => null);

// ============================================================
// 색상 & 테마
// ============================================================

class AppColors {
  static const Color safe          = Color(0xFF2ECC71);
  static const Color warning       = Color(0xFFF39C12);
  static const Color danger        = Color(0xFFE74C3C);
  static const Color background    = Color(0xFF1A1A2E);
  static const Color surface       = Color(0xFF16213E);
  static const Color cardBg        = Color(0xFF0F3460);
  static const Color textPrimary   = Color(0xFFECF0F1);
  static const Color textSecondary = Color(0xFFBDC3C7);

  static Color statusColor(String s) =>
      s == 'FALL' ? danger : s == 'WARNING' ? warning : safe;

  static Color probColor(double p) =>
      p >= 0.7 ? danger : p >= 0.4 ? warning : safe;
}

// ============================================================
// 앱 진입점
// ============================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await StorageService.init();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const ProviderScope(child: FallDetectionApp()));
}

class FallDetectionApp extends StatelessWidget {
  const FallDetectionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '낙상 감지 시스템',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
            primary: AppColors.safe, surface: AppColors.surface),
        scaffoldBackgroundColor: AppColors.background,
        textTheme: const TextTheme(
          bodyLarge:  TextStyle(color: AppColors.textPrimary),
          bodyMedium: TextStyle(color: AppColors.textPrimary),
        ),
      ),
      home: const MainShell(),
    );
  }
}

// ============================================================
// 메인 셸
// ============================================================

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});
  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  final List<Widget> _pages = const [
    DashboardPage(),
    EmergencyPage(),
    LiveStreamPage(),
    HistoryPage(),
    ContactsPage(),
  ];
  bool _lastWasFall = false;

  @override
  Widget build(BuildContext context) {
    final tabIndex = ref.watch(currentTabProvider);
    final hasBadge = ref.watch(emergencyBadgeProvider);

    ref.listen(currentFallDataProvider, (_, next) {
      next.whenData((data) {
        ref.read(graphDataProvider.notifier).addData(data);
        if (data.fallProb >= AppConfig.fallThreshold) {
          StorageService.saveFallEvent(data).then((_) {
            ref.read(fallHistoryProvider.notifier).state = StorageService.getFallEvents();
          });
        }
        final isFall = data.status == 'FALL';
        if (isFall && !_lastWasFall) {
          ref.read(emergencyBadgeProvider.notifier).state = true;
          ref.read(latestEmergencyProvider.notifier).state = data;
          _showFallAlert(context, data);
        }
        _lastWasFall = isFall;
      });
    });

    return Scaffold(
      body: IndexedStack(index: tabIndex, children: _pages),
      bottomNavigationBar: _buildBottomNav(tabIndex, hasBadge),
    );
  }

  void _showFallAlert(BuildContext ctx, FallData data) {
    if (!ctx.mounted) return;
    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => _FallAlertDialog(data: data, ref: ref),
    );
  }

  Widget _buildBottomNav(int tabIndex, bool hasBadge) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10)],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(icon: Icons.monitor_heart,    label: '대시보드', index: 0, current: tabIndex),
              _NavItemWithBadge(
                icon: Icons.warning_rounded, label: '긴급상황',
                index: 1, current: tabIndex, hasBadge: hasBadge,
                onTap: () {
                  ref.read(currentTabProvider.notifier).state = 1;
                  ref.read(emergencyBadgeProvider.notifier).state = false;
                },
              ),
              _NavItem(icon: Icons.videocam_rounded, label: '실시간',   index: 2, current: tabIndex),
              _NavItem(icon: Icons.history,           label: '히스토리', index: 3, current: tabIndex),
              _NavItem(icon: Icons.contacts,          label: '연락처',   index: 4, current: tabIndex),
            ],
          ),
        ),
      ),
    );
  }
}

class _FallAlertDialog extends ConsumerWidget {
  final FallData data;
  final WidgetRef ref;
  const _FallAlertDialog({required this.data, required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef _) {
    return AlertDialog(
      backgroundColor: AppColors.danger,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(children: [
        Icon(Icons.warning_rounded, color: Colors.white, size: 36),
        SizedBox(width: 8),
        Text('낙상 감지!',
            style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('낙상 확률: ${(data.fallProb * 100).toStringAsFixed(0)}%',
            style: const TextStyle(color: Colors.white, fontSize: 22)),
        const SizedBox(height: 8),
        Text(DateFormat('MM월 dd일 HH:mm:ss').format(data.dateTime),
            style: const TextStyle(color: Colors.white70, fontSize: 16)),
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('확인', style: TextStyle(color: Colors.white, fontSize: 20)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
          onPressed: () {
            Navigator.pop(context);
            ref.read(currentTabProvider.notifier).state = 1;
          },
          child: Text('긴급상황 보기', style: TextStyle(color: AppColors.danger, fontSize: 20)),
        ),
      ],
    );
  }
}

class _NavItem extends ConsumerWidget {
  final IconData icon;
  final String label;
  final int index, current;
  const _NavItem({required this.icon, required this.label,
      required this.index, required this.current});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sel = index == current;
    return GestureDetector(
      onTap: () => ref.read(currentTabProvider.notifier).state = index,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? AppColors.safe.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: sel ? AppColors.safe : AppColors.textSecondary, size: 26),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(
            color: sel ? AppColors.safe : AppColors.textSecondary,
            fontSize: 11, fontWeight: sel ? FontWeight.bold : FontWeight.normal,
          )),
        ]),
      ),
    );
  }
}

class _NavItemWithBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final int index, current;
  final bool hasBadge;
  final VoidCallback onTap;
  const _NavItemWithBadge({required this.icon, required this.label,
      required this.index, required this.current,
      required this.hasBadge, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sel = index == current;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? AppColors.danger.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Stack(clipBehavior: Clip.none, children: [
            Icon(icon, color: sel ? AppColors.danger : AppColors.textSecondary, size: 26),
            if (hasBadge)
              Positioned(top: -4, right: -4,
                child: Container(width: 12, height: 12,
                  decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle))),
          ]),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(
            color: sel ? AppColors.danger : AppColors.textSecondary,
            fontSize: 11, fontWeight: sel ? FontWeight.bold : FontWeight.normal,
          )),
        ]),
      ),
    );
  }
}

// ============================================================
// 실시간 스트리밍 페이지
// ============================================================

class LiveStreamPage extends ConsumerStatefulWidget {
  const LiveStreamPage({super.key});
  @override
  ConsumerState<LiveStreamPage> createState() => _LiveStreamPageState();
}

class _LiveStreamPageState extends ConsumerState<LiveStreamPage>
    with AutomaticKeepAliveClientMixin {
  late final WebViewController _wvc;
  bool _isLoading = true;
  bool _hasError  = false;
  final String _streamUrl = AppConfig.mjpegStreamUrl;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _wvc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() { _isLoading = true; _hasError = false; }),
        onPageFinished: (_) => setState(() => _isLoading = false),
        onWebResourceError: (_) => setState(() { _isLoading = false; _hasError = true; }),
      ))
      ..loadHtmlString(_buildHtml(_streamUrl));
  }

  String _buildHtml(String url) => '''
<!DOCTYPE html><html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  html,body{width:100%;height:100%;background:#000;display:flex;
    align-items:center;justify-content:center;overflow:hidden}
  #s{width:100%;height:100%;object-fit:contain}
  #e{display:none;color:#e74c3c;font-family:sans-serif;font-size:16px;
    text-align:center;padding:24px}
</style>
</head><body>
<img id="s" src="$url"
  onerror="document.getElementById('s').style.display='none';
           document.getElementById('e').style.display='block'"/>
<div id="e">
  <p>스트림 연결 불가</p>
  <p style="font-size:13px;color:#bdc3c7;margin-top:8px">$url</p>
</div>
</body></html>''';

  void _reload() {
    setState(() { _isLoading = true; _hasError = false; });
    _wvc.loadHtmlString(_buildHtml(_streamUrl));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final data = ref.watch(currentFallDataProvider).valueOrNull;
    final sc = data != null ? AppColors.statusColor(data.status) : AppColors.safe;
    final st = data?.status == 'FALL' ? '🚨 낙상 감지!'
        : data?.status == 'WARNING' ? '⚠️ 주의' : '✅ 안전';

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(child: Column(children: [
        Container(
          color: AppColors.surface,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            const Icon(Icons.videocam_rounded, color: AppColors.safe, size: 24),
            const SizedBox(width: 8),
            const Text('실시간 영상',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(width: 12),
            _LiveBadge(),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: sc.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: sc),
              ),
              child: Text(st, style: TextStyle(color: sc, fontSize: 13, fontWeight: FontWeight.bold)),
            ),
          ]),
        ),
        Expanded(child: Stack(children: [
          WebViewWidget(controller: _wvc),
          if (_isLoading)
            Container(color: Colors.black87,
                child: const Center(child: CircularProgressIndicator(color: AppColors.safe))),
          if (_hasError)
            Container(color: Colors.black, child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.wifi_off_rounded, color: AppColors.danger, size: 72),
              const SizedBox(height: 12),
              const Text('스트림 연결 실패',
                  style: TextStyle(color: AppColors.danger, fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.safe, foregroundColor: Colors.black),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('다시 연결',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                onPressed: _reload,
              ),
            ]))),
          Positioned(right: 12, bottom: 12,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _SCBtn(icon: Icons.fullscreen_rounded, onTap: () {}),
                const SizedBox(height: 8),
                _SCBtn(icon: Icons.refresh_rounded, onTap: _reload),
              ])),
        ])),
        Container(
          color: AppColors.surface,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('낙상 위험도', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                  Text(
                    data != null ? '${(data.fallProb * 100).toStringAsFixed(1)}%' : '--',
                    style: TextStyle(color: sc, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ]),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: data?.fallProb ?? 0.0, minHeight: 8,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation<Color>(sc),
                  ),
                ),
              ],
            )),
          ]),
        ),
      ])),
    );
  }
}

class _SCBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _SCBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 44, height: 44,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6), shape: BoxShape.circle,
        border: Border.all(color: Colors.white24),
      ),
      child: Icon(icon, color: Colors.white, size: 22),
    ),
  );
}

class _LiveBadge extends StatefulWidget {
  @override State<_LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<_LiveBadge> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _a;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _a = CurvedAnimation(parent: _c, curve: Curves.easeInOut);
  }

  @override void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _a,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: AppColors.danger, borderRadius: BorderRadius.circular(6)),
      child: const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, color: Colors.white, size: 8),
        SizedBox(width: 4),
        Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 11,
            fontWeight: FontWeight.bold, letterSpacing: 1)),
      ]),
    ),
  );
}

// ============================================================
// 대시보드 페이지
// ============================================================

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(currentFallDataProvider);

    return SafeArea(child: CustomScrollView(slivers: [
      SliverAppBar(
        backgroundColor: AppColors.background, floating: true,
        title: const Text('부모님 안전 모니터',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.bold)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppConfig.simulatorMode
                    ? AppColors.warning.withOpacity(0.2)
                    : AppColors.safe.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppConfig.simulatorMode ? AppColors.warning : AppColors.safe),
              ),
              child: Text(AppConfig.simulatorMode ? '테스트' : '실제',
                style: TextStyle(
                  color: AppConfig.simulatorMode ? AppColors.warning : AppColors.safe,
                  fontSize: 11, fontWeight: FontWeight.bold,
                )),
            ),
          ),
          async.when(
            data: (_) => const Padding(padding: EdgeInsets.only(right: 16),
              child: Row(children: [
                Icon(Icons.circle, color: AppColors.safe, size: 10), SizedBox(width: 4),
                Text('연결됨', style: TextStyle(color: AppColors.safe, fontSize: 14)),
              ])),
            loading: () => const Padding(padding: EdgeInsets.only(right: 16),
              child: Row(children: [
                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 4),
                Text('연결 중...', style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
              ])),
            error: (_, __) => const Padding(padding: EdgeInsets.only(right: 16),
              child: Row(children: [
                Icon(Icons.circle, color: AppColors.danger, size: 10), SizedBox(width: 4),
                Text('연결 오류', style: TextStyle(color: AppColors.danger, fontSize: 14)),
              ])),
          ),
        ],
      ),
      SliverToBoxAdapter(child: async.when(
        loading: () => const SizedBox(height: 300,
            child: Center(child: CircularProgressIndicator(color: AppColors.safe))),
        error: (e, _) => Padding(padding: const EdgeInsets.all(32), child: Column(children: [
          const Icon(Icons.wifi_off, color: AppColors.danger, size: 64),
          const SizedBox(height: 16),
          const Text('Python 서버 연결 실패',
              style: TextStyle(color: AppColors.danger, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('ws://localhost:8765',
              style: TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          const Text('fall_publisher.py 가 실행 중인지 확인하세요',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
              textAlign: TextAlign.center),
        ])),
        data: (data) => Column(children: [
          const SizedBox(height: 16),
          _StatusCard(data: data),
          const SizedBox(height: 16),
          _ProbabilityGauge(prob: data.fallProb),
          const SizedBox(height: 16),
          if (data.poseData.isNotEmpty) ...[
            _PoseOverlayWidget(poseData: data.poseData),
            const SizedBox(height: 16),
          ],
          const _RealTimeGraph(),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('마지막 업데이트: ${DateFormat('HH:mm:ss').format(data.dateTime)}',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
          ),
          const SizedBox(height: 24),
        ]),
      )),
    ]));
  }
}

class _StatusCard extends StatelessWidget {
  final FallData data;
  const _StatusCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final c  = AppColors.statusColor(data.status);
    final tx = data.status == 'FALL' ? '낙상 감지!'
        : data.status == 'WARNING' ? '주의' : '안전';
    final em = data.status == 'FALL' ? '🚨'
        : data.status == 'WARNING' ? '⚠️' : '✅';
    final ds = data.status == 'FALL' ? '즉시 확인이 필요합니다'
        : data.status == 'WARNING' ? '상태를 확인해 주세요' : '정상적으로 활동 중입니다';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        width: double.infinity, padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: c.withOpacity(0.15), borderRadius: BorderRadius.circular(24),
          border: Border.all(color: c, width: 3),
          boxShadow: [BoxShadow(color: c.withOpacity(0.3), blurRadius: 20, spreadRadius: 2)],
        ),
        child: Column(children: [
          Text(em, style: const TextStyle(fontSize: 64)),
          const SizedBox(height: 12),
          Text(tx, style: TextStyle(color: c, fontSize: 40, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(ds, style: const TextStyle(color: AppColors.textSecondary, fontSize: 18)),
        ]),
      ),
    );
  }
}

class _ProbabilityGauge extends StatelessWidget {
  final double prob;
  const _ProbabilityGauge({required this.prob});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.probColor(prob);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: AppColors.cardBg, borderRadius: BorderRadius.circular(20)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('낙상 위험도', style: TextStyle(color: AppColors.textSecondary, fontSize: 16)),
            Text('${(prob * 100).toStringAsFixed(1)}%',
                style: TextStyle(color: c, fontSize: 28, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: prob, minHeight: 20,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(c),
            ),
          ),
          const SizedBox(height: 8),
          const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('0%', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            Text('주의 40%', style: TextStyle(color: AppColors.warning, fontSize: 12, fontWeight: FontWeight.bold)),
            Text('위험 70%', style: TextStyle(color: AppColors.danger,  fontSize: 12, fontWeight: FontWeight.bold)),
            Text('100%', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          ]),
        ]),
      ),
    );
  }
}

class _PoseOverlayWidget extends StatelessWidget {
  final List<dynamic> poseData;
  const _PoseOverlayWidget({required this.poseData});

  static const List<List<int>> connections = [
    [0,1],[1,2],[2,3],[3,7],[0,4],[4,5],[5,6],[6,8],[9,10],
    [11,12],[11,13],[13,15],[12,14],[14,16],
    [11,23],[12,24],[23,24],[23,25],[25,27],[24,26],[26,28],
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: 220,
        decoration: BoxDecoration(color: AppColors.cardBg, borderRadius: BorderRadius.circular(20)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text('실시간 관절 추적',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
          ),
          Expanded(child: CustomPaint(
            painter: _PosePainter(poseData: poseData, connections: connections),
            size: Size.infinite,
          )),
        ]),
      ),
    );
  }
}

class _PosePainter extends CustomPainter {
  final List<dynamic> poseData;
  final List<List<int>> connections;
  _PosePainter({required this.poseData, required this.connections});

  @override
  void paint(Canvas canvas, Size size) {
    if (poseData.isEmpty) return;
    const pad = 20.0;
    final w = size.width - pad * 2;
    final h = size.height - pad * 2;

    Offset toOff(Map<String, dynamic> lm) =>
        Offset(pad + (lm['x'] as double) * w, pad + (lm['y'] as double) * h);

    final bone = Paint()
      ..color = Colors.white.withOpacity(0.4)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final joint = Paint()..color = AppColors.safe..style = PaintingStyle.fill;

    for (final c in connections) {
      if (c[0] >= poseData.length || c[1] >= poseData.length) continue;
      final a = poseData[c[0]] as Map<String, dynamic>;
      final b = poseData[c[1]] as Map<String, dynamic>;
      if ((a['visibility'] as double) > 0.4 && (b['visibility'] as double) > 0.4) {
        canvas.drawLine(toOff(a), toOff(b), bone);
      }
    }

    for (int i = 0; i < poseData.length; i++) {
      final lm = poseData[i] as Map<String, dynamic>;
      if ((lm['visibility'] as double) > 0.4) {
        final isKey = [0, 11, 12, 23, 24].contains(i);
        joint.color = isKey ? AppColors.warning : AppColors.safe;
        canvas.drawCircle(toOff(lm), isKey ? 5.0 : 3.0, joint);
      }
    }
  }

  @override
  bool shouldRepaint(_PosePainter old) => old.poseData != poseData;
}

class _RealTimeGraph extends ConsumerWidget {
  const _RealTimeGraph();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final graphData = ref.watch(graphDataProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: AppColors.cardBg, borderRadius: BorderRadius.circular(20)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('낙상 확률 추이 (최근 1시간)',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 16)),
          const SizedBox(height: 20),
          SizedBox(
            height: 200,
            child: graphData.isEmpty
                ? const Center(child: Text('데이터 수집 중...',
                    style: TextStyle(color: AppColors.textSecondary)))
                : _buildChart(graphData),
          ),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _Legend(color: AppColors.safe,    label: '안전 (<40%)'),
            const SizedBox(width: 16),
            _Legend(color: AppColors.warning, label: '주의 (40-70%)'),
            const SizedBox(width: 16),
            _Legend(color: AppColors.danger,  label: '위험 (>70%)'),
          ]),
        ]),
      ),
    );
  }

  Widget _buildChart(List<FallData> data) {
    final d = data.length > 60 ? data.sublist(data.length - 60) : data;
    final spots = d.asMap().entries
        .map((e) => FlSpot(e.key.toDouble(), e.value.fallProb))
        .toList();

    return LineChart(
      LineChartData(
        minY: 0, maxY: 1,
        gridData: FlGridData(
          show: true, drawVerticalLine: false, horizontalInterval: 0.1,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: Colors.white.withOpacity(0.05), strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          rightTitles:  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(sideTitles: SideTitles(
            showTitles: true, interval: 0.2, reservedSize: 36,
            getTitlesWidget: (v, _) => Text('${(v * 100).toInt()}%',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 10)),
          )),
        ),
        extraLinesData: ExtraLinesData(horizontalLines: [
          HorizontalLine(y: 0.4,
              color: AppColors.warning.withOpacity(0.5), strokeWidth: 1, dashArray: [6, 3]),
          HorizontalLine(y: 0.7,
              color: AppColors.danger.withOpacity(0.5), strokeWidth: 1, dashArray: [6, 3]),
        ]),
        lineBarsData: [
          LineChartBarData(
            spots: spots, isCurved: true, curveSmoothness: 0.3,
            color: AppColors.safe, barWidth: 3, isStrokeCapRound: true,
            dotData: FlDotData(
              show: true,
              getDotPainter: (s, _, __, ___) => FlDotCirclePainter(
                radius: s.y >= 0.6 ? 6 : 3,
                color: AppColors.probColor(s.y),
                strokeWidth: 2, strokeColor: Colors.white,
              ),
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [AppColors.safe.withOpacity(0.3), AppColors.safe.withOpacity(0.0)],
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
              ),
            ),
          ),
        ],
        // ★ fl_chart 0.68: tooltipBgColor 제거, getTooltipColor 사용
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppColors.surface,
            getTooltipItems: (spots) => spots.map((s) => LineTooltipItem(
              '${(s.y * 100).toStringAsFixed(1)}%',
              TextStyle(color: AppColors.probColor(s.y), fontWeight: FontWeight.bold),
            )).toList(),
          ),
        ),
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend({required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 12, height: 12,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
    const SizedBox(width: 4),
    Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 10)),
  ]);
}

// ============================================================
// 긴급상황 페이지
// ============================================================

class EmergencyPage extends ConsumerWidget {
  const EmergencyPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latest   = ref.watch(latestEmergencyProvider);
    final current  = ref.watch(currentFallDataProvider).valueOrNull;
    final contacts = ref.watch(contactsProvider);
    final isFall   = current?.status == 'FALL';

    return Scaffold(
      backgroundColor:
          isFall ? AppColors.danger.withOpacity(0.15) : AppColors.background,
      body: SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          const SizedBox(height: 16),
          Row(children: [
            Icon(Icons.warning_rounded,
                color: isFall ? AppColors.danger : AppColors.textSecondary, size: 32),
            const SizedBox(width: 8),
            const Text('긴급상황',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 28, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 24),

          latest != null
              ? _EmergencyStatusCard(data: latest)
              : Container(
                  width: double.infinity, padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: AppColors.safe.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.safe),
                  ),
                  child: const Column(children: [
                    Icon(Icons.check_circle_rounded, color: AppColors.safe, size: 64),
                    SizedBox(height: 12),
                    Text('낙상 이벤트 없음',
                        style: TextStyle(color: AppColors.safe, fontSize: 24, fontWeight: FontWeight.bold)),
                    SizedBox(height: 8),
                    Text('현재 안전한 상태입니다',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 16)),
                  ]),
                ),

          const SizedBox(height: 32),
          const Align(alignment: Alignment.centerLeft,
              child: Text('긴급 신고',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 18, fontWeight: FontWeight.bold))),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _EmergencyCallButton(
                icon: Icons.local_hospital_rounded, label: '119',
                sublabel: '구급대', color: AppColors.danger, phone: '119')),
            const SizedBox(width: 12),
            Expanded(child: _EmergencyCallButton(
                icon: Icons.local_police_rounded, label: '112',
                sublabel: '경찰', color: const Color(0xFF2980B9), phone: '112')),
          ]),
          const SizedBox(height: 24),

          const Align(alignment: Alignment.centerLeft,
              child: Text('보호자 연락',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 18, fontWeight: FontWeight.bold))),
          const SizedBox(height: 12),
          ...contacts.map((c) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _ContactCallButton(contact: c))),
          if (contacts.isEmpty)
            const Text('연락처 탭에서 보호자를 추가하세요',
                style: TextStyle(color: AppColors.textSecondary)),

          if (latest?.videoClipUrl != null) ...[
            const SizedBox(height: 24),
            const Align(alignment: Alignment.centerLeft,
                child: Text('사고 당시 영상',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 18, fontWeight: FontWeight.bold))),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => VideoPlayerPage(
                      videoUrl: latest!.videoClipUrl!, title: '낙상 감지 영상'))),
              child: Container(
                width: double.infinity, padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.danger.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.danger),
                ),
                child: const Row(children: [
                  Icon(Icons.play_circle_rounded, color: AppColors.danger, size: 48),
                  SizedBox(width: 16),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('영상 보기',
                        style: TextStyle(color: AppColors.danger, fontSize: 20, fontWeight: FontWeight.bold)),
                    Text('낙상 감지 ±20초 클립',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
                  ]),
                ]),
              ),
            ),
          ],
          const SizedBox(height: 24),
        ]),
      )),
    );
  }
}

class _EmergencyStatusCard extends StatelessWidget {
  final FallData data;
  const _EmergencyStatusCard({required this.data});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity, padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: AppColors.danger.withOpacity(0.2),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: AppColors.danger, width: 2),
    ),
    child: Column(children: [
      const Icon(Icons.person_off_rounded, color: AppColors.danger, size: 56),
      const SizedBox(height: 12),
      const Text('낙상 감지됨!',
          style: TextStyle(color: AppColors.danger, fontSize: 28, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text('낙상 확률: ${(data.fallProb * 100).toStringAsFixed(0)}%',
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 20)),
      const SizedBox(height: 4),
      Text('감지 시각: ${DateFormat('MM월 dd일 HH시 mm분 ss초').format(data.dateTime)}',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 15)),
    ]),
  );
}

class _EmergencyCallButton extends StatelessWidget {
  final IconData icon;
  final String label, sublabel, phone;
  final Color color;
  const _EmergencyCallButton({required this.icon, required this.label,
      required this.sublabel, required this.color, required this.phone});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => _call(context),
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color, width: 2),
      ),
      child: Column(children: [
        Icon(icon, color: color, size: 44),
        const SizedBox(height: 8),
        Text(label, style: TextStyle(color: color, fontSize: 32, fontWeight: FontWeight.bold)),
        Text(sublabel, style: TextStyle(color: color.withOpacity(0.7), fontSize: 14)),
      ]),
    ),
  );

  void _call(BuildContext context) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('$label에 전화하시겠습니까?',
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 20)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true), child: const Text('전화하기')),
      ],
    ));
    if (ok == true) {
      final u = Uri(scheme: 'tel', path: phone);
      if (await canLaunchUrl(u)) await launchUrl(u);
    }
  }
}

class _ContactCallButton extends StatelessWidget {
  final EmergencyContact contact;
  const _ContactCallButton({required this.contact});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => _call(context),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF8E44AD).withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF8E44AD), width: 2),
      ),
      child: Row(children: [
        const Icon(Icons.person_rounded, color: Color(0xFF8E44AD), size: 36),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(contact.name,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.bold)),
          Text(contact.phone,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 16)),
          Text(contact.relation,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
        ])),
        const Icon(Icons.call_rounded, color: Color(0xFF8E44AD), size: 36),
      ]),
    ),
  );

  void _call(BuildContext context) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('${contact.name}에게 전화하시겠습니까?',
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 18)),
      content: Text(contact.phone,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 22)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
        ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8E44AD)),
            onPressed: () => Navigator.pop(ctx, true), child: const Text('전화하기')),
      ],
    ));
    if (ok == true) {
      final u = Uri(scheme: 'tel', path: contact.phone);
      if (await canLaunchUrl(u)) await launchUrl(u);
    }
  }
}

// ============================================================
// 히스토리 페이지
// ============================================================

class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(fallHistoryProvider);
    return SafeArea(child: Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('낙상 기록',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 28, fontWeight: FontWeight.bold)),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.danger.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.danger),
              ),
              child: Text('총 ${events.length}건',
                  style: const TextStyle(color: AppColors.danger, fontSize: 16)),
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded, color: AppColors.textSecondary),
              onPressed: events.isEmpty ? null : () => _confirmClear(context, ref),
            ),
          ]),
        ]),
      ),
      Expanded(child: events.isEmpty
          ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.check_circle_rounded, color: AppColors.safe, size: 72),
              SizedBox(height: 16),
              Text('낙상 기록 없음', style: TextStyle(color: AppColors.textPrimary, fontSize: 24)),
              SizedBox(height: 8),
              Text('안전한 상태가 유지되고 있습니다',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 16)),
            ]))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: events.length,
              itemBuilder: (_, i) => _HistoryItem(event: events[i]))),
    ]));
  }

  void _confirmClear(BuildContext context, WidgetRef ref) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('기록 전체 삭제', style: TextStyle(color: AppColors.textPrimary)),
      content: const Text('모든 낙상 기록을 삭제하시겠습니까?',
          style: TextStyle(color: AppColors.textSecondary)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: () async {
            await StorageService.clearHistory();
            ref.read(fallHistoryProvider.notifier).state = [];
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text('삭제'),
        ),
      ],
    ));
  }
}

class _HistoryItem extends StatelessWidget {
  final FallEvent event;
  const _HistoryItem({required this.event});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.probColor(event.fallProb);
    return Card(
      color: AppColors.cardBg, margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: event.videoClipUrl != null
            ? () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => VideoPlayerPage(
                    videoUrl: event.videoClipUrl!, title: '낙상 감지 영상')))
            : null,
        child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
          Container(width: 64, height: 64,
            decoration: BoxDecoration(
              color: c.withOpacity(0.15), shape: BoxShape.circle,
              border: Border.all(color: c, width: 2),
            ),
            child: Center(child: Text('${(event.fallProb * 100).toStringAsFixed(0)}%',
                style: TextStyle(color: c, fontSize: 15, fontWeight: FontWeight.bold)))),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(DateFormat('yyyy년 MM월 dd일').format(event.dateTime),
                style: const TextStyle(color: AppColors.textPrimary,
                    fontSize: 16, fontWeight: FontWeight.bold)),
            Text(DateFormat('HH시 mm분 ss초').format(event.dateTime),
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                  color: c.withOpacity(0.15), borderRadius: BorderRadius.circular(6)),
              child: Text(event.status == 'FALL' ? '낙상 감지' : '위험 수준',
                  style: TextStyle(color: c, fontSize: 12)),
            ),
          ])),
          if (event.videoClipUrl != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.danger.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.play_circle_rounded, color: AppColors.danger, size: 32),
                SizedBox(height: 2),
                Text('영상\n보기', textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.danger, fontSize: 11)),
              ]),
            ),
        ])),
      ),
    );
  }
}

// ============================================================
// 영상 재생 페이지
// ============================================================

class VideoPlayerPage extends StatefulWidget {
  final String videoUrl, title;
  const VideoPlayerPage({super.key, required this.videoUrl, required this.title});
  @override State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _vc;
  ChewieController?      _cc;
  bool    _loading = true;
  String? _error;

  @override void initState() { super.initState(); _init(); }

  Future<void> _init() async {
    try {
      _vc = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
      await _vc!.initialize();
      _cc = ChewieController(
        videoPlayerController: _vc!, autoPlay: true, looping: false, aspectRatio: 16 / 9,
        materialProgressColors: ChewieProgressColors(
            playedColor: AppColors.danger, handleColor: AppColors.danger),
      );
      setState(() => _loading = false);
    } catch (_) {
      setState(() { _loading = false; _error = '영상을 불러올 수 없습니다'; });
    }
  }

  @override void dispose() { _vc?.dispose(); _cc?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context)),
      title: Text(widget.title, style: const TextStyle(color: Colors.white)),
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator(color: AppColors.danger))
        : _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white)))
            : Chewie(controller: _cc!),
  );
}

// ============================================================
// 연락처 페이지
// ============================================================

class ContactsPage extends ConsumerWidget {
  const ContactsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contacts = ref.watch(contactsProvider);
    return SafeArea(child: Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('긴급 연락처',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 28, fontWeight: FontWeight.bold)),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.safe, foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.add, size: 22),
            label: const Text('추가', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            onPressed: () => _showAdd(context, ref),
          ),
        ]),
      ),
      const SizedBox(height: 8),
      Expanded(child: contacts.isEmpty
          ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.person_add_alt_1_rounded, color: AppColors.textSecondary, size: 72),
              SizedBox(height: 16),
              Text('연락처가 없습니다',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 22)),
            ]))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: contacts.length,
              itemBuilder: (_, i) => _ContactCard(
                contact: contacts[i],
                onDelete: () async {
                  await StorageService.deleteContact(i);
                  ref.read(contactsProvider.notifier).state = StorageService.getContacts();
                },
              ))),
    ]));
  }

  void _showAdd(BuildContext context, WidgetRef ref) {
    final nc = TextEditingController();
    final pc = TextEditingController();
    final rc = TextEditingController();
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('연락처 추가',
          style: TextStyle(color: AppColors.textPrimary, fontSize: 22)),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        _Field(ctrl: nc, label: '이름',    hint: '예: 홍길동'),
        const SizedBox(height: 12),
        _Field(ctrl: pc, label: '전화번호', hint: '예: 010-1234-5678',
            type: TextInputType.phone),
        const SizedBox(height: 12),
        _Field(ctrl: rc, label: '관계',    hint: '예: 아들, 딸'),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.safe),
          onPressed: () async {
            if (nc.text.isEmpty || pc.text.isEmpty) return;
            await StorageService.addContact(EmergencyContact(
              name: nc.text, phone: pc.text,
              relation: rc.text.isEmpty ? '가족' : rc.text,
            ));
            ref.read(contactsProvider.notifier).state = StorageService.getContacts();
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text('저장', style: TextStyle(color: Colors.black)),
        ),
      ],
    ));
  }
}

class _Field extends StatelessWidget {
  final TextEditingController ctrl;
  final String label, hint;
  final TextInputType? type;
  const _Field({required this.ctrl, required this.label,
      required this.hint, this.type});

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 15)),
        const SizedBox(height: 6),
        TextField(
          controller: ctrl, keyboardType: type,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 18),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: AppColors.textSecondary),
            filled: true, fillColor: AppColors.cardBg,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      ]);
}

class _ContactCard extends StatelessWidget {
  final EmergencyContact contact;
  final VoidCallback onDelete;
  const _ContactCard({required this.contact, required this.onDelete});

  @override
  Widget build(BuildContext context) => Card(
    color: AppColors.cardBg, margin: const EdgeInsets.only(bottom: 12),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
      Container(width: 56, height: 56,
        decoration: const BoxDecoration(color: Color(0xFF8E44AD), shape: BoxShape.circle),
        child: const Icon(Icons.person_rounded, color: Colors.white, size: 32)),
      const SizedBox(width: 16),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(contact.name,
            style: const TextStyle(color: AppColors.textPrimary,
                fontSize: 20, fontWeight: FontWeight.bold)),
        Text(contact.phone,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 17)),
        Text(contact.relation,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
      ])),
      Column(children: [
        IconButton(
          icon: const Icon(Icons.call_rounded, color: AppColors.safe, size: 30),
          onPressed: () async {
            final u = Uri(scheme: 'tel', path: contact.phone);
            if (await canLaunchUrl(u)) await launchUrl(u);
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete_rounded, color: AppColors.danger, size: 26),
          onPressed: () => showDialog(context: context, builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text('${contact.name} 삭제',
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 20)),
            content: const Text('이 연락처를 삭제하시겠습니까?',
                style: TextStyle(color: AppColors.textSecondary)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
                onPressed: () { onDelete(); Navigator.pop(ctx); },
                child: const Text('삭제'),
              ),
            ],
          )),
        ),
      ]),
    ])),
  );
}