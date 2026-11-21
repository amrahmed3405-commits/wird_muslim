import 'dart:convert';
import 'package:adhan/adhan.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:webview_flutter/webview_flutter.dart';

// ================= الإشعارات (أذان / إقامة / تذكير) =================
class Notifier {
  static final FlutterLocalNotificationsPlugin _p = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    try {
      tzdata.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation('Africa/Cairo'));
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _p.initialize(const InitializationSettings(android: android));
      final impl = _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await impl?.requestNotificationsPermission();
      _ready = true;
    } catch (e) {
      _ready = false;
    }
  }

  // kind: a1..a5 (أذان) | iqama | silent | tone
  static NotificationDetails _details(String kind) {
    if (kind.length == 2 && kind.startsWith('a')) {
      final n = kind.substring(1);
      return NotificationDetails(
        android: AndroidNotificationDetails(
          'adhan_${n}_v1',
          'الأذان $n',
          channelDescription: 'أذان الصلوات',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('adhan_$n'),
          audioAttributesUsage: AudioAttributesUsage.alarm,
          category: AndroidNotificationCategory.alarm,
        ),
      );
    }
    switch (kind) {
      case 'iqama':
        return NotificationDetails(
          android: AndroidNotificationDetails(
            'iqama_v1',
            'الإقامة',
            channelDescription: 'تنبيه الإقامة',
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            sound: const RawResourceAndroidNotificationSound('iqama'),
            audioAttributesUsage: AudioAttributesUsage.alarm,
            category: AndroidNotificationCategory.alarm,
          ),
        );
      case 'silent':
        return NotificationDetails(
          android: AndroidNotificationDetails(
            'silent_v1',
            'تنبيه صامت',
            channelDescription: 'تنبيهات بدون صوت',
            importance: Importance.low,
            priority: Priority.low,
            playSound: false,
            enableVibration: false,
          ),
        );
      default:
        return NotificationDetails(
          android: AndroidNotificationDetails(
            'wird_channel',
            'تذكير الأوراد',
            channelDescription: 'تذكيرات الأوراد اليومية',
            importance: Importance.high,
            priority: Priority.high,
          ),
        );
    }
  }

  static Future<void> schedule(int id, String title, String body, DateTime when, {String kind = 'tone'}) async {
    if (!_ready) return;
    final t = tz.TZDateTime.from(when, tz.local);
    if (!t.isAfter(tz.TZDateTime.now(tz.local))) return;
    try {
      await _p.zonedSchedule(
        id,
        title,
        body,
        t,
        _details(kind),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      try {
        await _p.zonedSchedule(
          id,
          title,
          body,
          t,
          _details(kind),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        );
      } catch (e2) {
        // تجاهل
      }
    }
  }

  static Future<void> cancelAll() async {
    if (!_ready) return;
    try {
      await _p.cancelAll();
    } catch (e) {
      // تجاهل
    }
  }
}

// ================= التطبيق: نفس صفحة وردي داخل WebView =================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notifier.init();
  runApp(const WirdApp());
}

class WirdApp extends StatelessWidget {
  const WirdApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'وردي',
      debugShowCheckedModeBanner: false,
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const WebHome(),
    );
  }
}

class WebHome extends StatefulWidget {
  const WebHome({super.key});

  @override
  State<WebHome> createState() => _WebHomeState();
}

class _WebHomeState extends State<WebHome> {
  WebViewController? _c;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    var html = await rootBundle.loadString('assets/app.html');
    final saved = _prefs!.getString('wird_state');
    if (saved != null && saved.isNotEmpty) {
      final lit = jsonEncode(saved).replaceAll('</', '<\\/');
      html = html.replaceFirst('/*__NS__*/', 'window.__NS=$lit;');
    }
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFEEF3F0))
      ..addJavaScriptChannel('Native', onMessageReceived: _onMsg)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest r) {
            final u = r.url;
            if (u.startsWith('https://wird.app') || u.startsWith('about:') || u.startsWith('data:')) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadHtmlString(html, baseUrl: 'https://wird.app/');
    if (!mounted) return;
    setState(() {
      _c = c;
    });
  }

  Future<void> _onMsg(JavaScriptMessage m) async {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(m.message) as Map<String, dynamic>;
    } catch (e) {
      return;
    }
    final id = msg['id'] is int ? msg['id'] as int : 0;
    final cmd = (msg['cmd'] ?? '') as String;
    final args = msg['args'] is Map ? Map<String, dynamic>.from(msg['args'] as Map) : <String, dynamic>{};
    dynamic result = <String, dynamic>{'ok': true};
    bool ok = true;
    try {
      if (cmd == 'save') {
        await _prefs?.setString('wird_state', args['data'] as String);
      } else if (cmd == 'times') {
        result = _times(args);
      } else if (cmd == 'schedule') {
        await _schedule(args);
      } else if (cmd == 'gps') {
        result = await _gps();
      } else if (cmd == 'test') {
        await _test(args);
      } else if (cmd == 'settings') {
        await Geolocator.openAppSettings();
      } else {
        ok = false;
        result = 'unknown';
      }
    } catch (e) {
      ok = false;
      result = e.toString();
    }
    if (id != 0) {
      _c?.runJavaScript('window.__nres($id, $ok, ${jsonEncode(jsonEncode(result))})');
    }
  }

  // مواقيت الصلاة بطريقة الهيئة المصرية (بدون إنترنت)
  List<Map<String, dynamic>> _times(Map<String, dynamic> a) {
    final c = Coordinates((a['lat'] as num).toDouble(), (a['lng'] as num).toDouble());
    final p = CalculationMethod.egyptian.getParameters();
    p.madhab = a['hanafi'] == true ? Madhab.hanafi : Madhab.shafi;
    final days = (a['days'] as num).toInt();
    final now = DateTime.now();
    final out = <Map<String, dynamic>>[];
    for (int i = 0; i < days; i++) {
      final d = DateTime(now.year, now.month, now.day + i);
      final pt = PrayerTimes(c, DateComponents.from(d), p);
      out.add(<String, dynamic>{
        'fajr': pt.fajr.millisecondsSinceEpoch,
        'sunrise': pt.sunrise.millisecondsSinceEpoch,
        'dhuhr': pt.dhuhr.millisecondsSinceEpoch,
        'asr': pt.asr.millisecondsSinceEpoch,
        'maghrib': pt.maghrib.millisecondsSinceEpoch,
        'isha': pt.isha.millisecondsSinceEpoch,
      });
    }
    return out;
  }

  Future<void> _schedule(Map<String, dynamic> a) async {
    await Notifier.cancelAll();
    final items = a['items'] as List<dynamic>;
    for (final raw in items) {
      final it = raw as Map<String, dynamic>;
      await Notifier.schedule(
        (it['id'] as num).toInt(),
        it['title'] as String,
        it['body'] as String,
        DateTime.fromMillisecondsSinceEpoch((it['when'] as num).toInt()),
        kind: it['kind'] as String,
      );
    }
  }

  Future<Map<String, dynamic>> _gps() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      throw 'شغّل خدمة الموقع (GPS) في الموبايل ثم جرّب تاني';
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      throw 'محتاج صلاحية الموقع. فعّلها من إعدادات التطبيق أو اختار مدينتك';
    }
    Position? pos;
    try {
      pos = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 25));
    } catch (e) {
      pos = await Geolocator.getLastKnownPosition();
    }
    if (pos == null) {
      throw 'ما قدرتش أحدد موقعك. اختار مدينتك يدويًا';
    }
    return <String, dynamic>{'lat': pos.latitude, 'lng': pos.longitude};
  }

  Future<void> _test(Map<String, dynamic> a) async {
    final secs = (a['seconds'] as num).toInt();
    await Notifier.schedule(
      (a['id'] as num).toInt(),
      a['title'] as String,
      a['body'] as String,
      DateTime.now().add(Duration(seconds: secs)),
      kind: a['kind'] as String,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return PopScope(
      canPop: false,
      onPopInvoked: (bool didPop) async {
        if (didPop) return;
        if (c != null && await c.canGoBack()) {
          await c.goBack();
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0C4234),
        body: SafeArea(
          child: c == null ? const Center(child: CircularProgressIndicator()) : WebViewWidget(controller: c),
        ),
      ),
    );
  }
}
