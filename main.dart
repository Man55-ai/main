// lib/main.dart (HereMe — Supabase Auth + DB integrated, pixel-perfect UI, threaded chat, animations)
// -----------------------------------------------------------------------------
// BEFORE RUN:
// 1) pubspec.yaml: add dependency -> supabase_flutter: ^2.10.0
// 2) Set constants below (kSupabaseUrl, kSupabaseAnonKey) to YOUR project values
//    - URL must be like: https://xxxxx.supabase.co  (NOT a dashboard URL)
//    - You can also pass via --dart-define SUPABASE_URL / SUPABASE_ANON_KEY
// 3) Mobile OAuth requires deep links in AndroidManifest.xml / Info.plist.
// 4) OpenAI key optional; leave empty to use local simulated replies.
//
// This single file includes:
// - Supabase initialize
// - AuthService (email/password + OAuth + phone OTP)
// - DBService (profiles, threads, messages, mood_history)
// - AppState wiring & first-login migration from SharedPreferences -> Supabase
// - Full UI updated to read/write with Supabase
// -----------------------------------------------------------------------------

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:uuid/uuid.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

// ===== Supabase Config (REQUIRED) =====
const String kSupabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://psqitupmfwkpbqrfqqut.supabase.co',
);
const String kSupabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue:
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBzcWl0dXBtZndrcGJxcmZxcXV0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTgyODc2NTcsImV4cCI6MjA3Mzg2MzY1N30.ltAUjMN9V_gEi6j5x4DJ0A8OMdwYUUusulEpM1MgvTk',
);

// ใช้ dart-define แทน (ค่า default เว้นว่าง)
const String kOpenAIKey =
    String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');
const String kOpenAIModel = String.fromEnvironment(
  'OPENAI_MODEL',
  defaultValue: 'gpt-4o-mini',
);

// Easy alias
sb.SupabaseClient get supabase => sb.Supabase.instance.client;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final uuid = const Uuid();
  print('UUID v4: ${uuid.v4()}');
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details, forceReport: true);
  };

  // Initialize local storage (for pre-login cache & migration)
  await AppStorage.init();

  // Initialize Supabase (if keys are provided)
  if (kSupabaseUrl.isNotEmpty && kSupabaseAnonKey.isNotEmpty) {
    await sb.Supabase.initialize(
      url: kSupabaseUrl,
      anonKey: kSupabaseAnonKey,
      authOptions: sb.FlutterAuthClientOptions(
        authFlowType: sb.AuthFlowType.pkce, // สำคัญสำหรับ OAuth + deep link
      ),
    );
  }

  runApp(const HereMeApp());
}

// -----------------------------------------------------------------------------
// Models (in-app)
// -----------------------------------------------------------------------------
class ChatMessage {
  final String role; // 'user' | 'ai'
  String text;
  final DateTime time;
  ChatMessage({required this.role, required this.text, DateTime? time})
      : time = time ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        'time': time.toIso8601String(),
      };
  static ChatMessage fromJson(Map<String, dynamic> j) => ChatMessage(
        role: j['role'] ?? 'user',
        text: j['text'] ?? '',
        time: DateTime.tryParse(j['time'] ?? '') ?? DateTime.now(),
      );
}

class MoodEntry {
  final DateTime date;
  final int mood; // 1..6
  MoodEntry({required this.date, required this.mood});

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'mood': mood,
      };
  static MoodEntry fromJson(Map<String, dynamic> j) => MoodEntry(
        date: DateTime.tryParse(j['date'] ?? '') ?? DateTime.now(),
        mood: (j['mood'] as num?)?.toInt() ?? 3,
      );
}

class ChatThread {
  final String id; // uuid (from DB)
  String persona; // ผู้เชี่ยวชาญ/เพื่อน/...
  String topic; // การเรียน/ความรัก/...
  DateTime createdAt;
  DateTime updatedAt;
  final List<ChatMessage> messages;

  ChatThread({
    required this.id,
    required this.persona,
    required this.topic,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        messages = messages ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'persona': persona,
        'topic': topic,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'messages': messages.map((e) => e.toJson()).toList(),
      };

  static ChatThread fromJson(Map<String, dynamic> j) => ChatThread(
        id: j['id'],
        persona: j['persona'] ?? 'เพื่อน',
        topic: j['topic'] ?? 'การเรียน',
        createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse(j['updatedAt'] ?? '') ?? DateTime.now(),
        messages: (j['messages'] as List? ?? [])
            .map((e) => ChatMessage.fromJson(e))
            .toList(),
      );
}

// -----------------------------------------------------------------------------
// Local Storage (SharedPreferences JSON) — used BEFORE login & for migration
// -----------------------------------------------------------------------------
class AppStorage {
  static SharedPreferences? _prefs;

  // ==== Keys ====
  static const _kThreadsKey = 'here_me_threads_v2';
  static const _kProfileKey = 'here_me_profile_v1';
  static const _kMoodKey = 'here_me_mood_v1';
  static const _kMoodHistoryKey = 'here_me_mood_history_v1';

  // ==== Init ====
  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static Future<void> _ensure() async {
    if (_prefs == null) await init();
  }

  // ==== Threads ====
  static Future<List<ChatThread>> loadThreads() async {
    await _ensure();
    final raw = _prefs!.getString(_kThreadsKey);
    if (raw == null) return [];
    try {
      final list = (jsonDecode(raw) as List);
      return list
          .map((e) => ChatThread.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveThreads(List<ChatThread> threads) async {
    await _ensure();
    final raw = jsonEncode(threads.map((t) => t.toJson()).toList());
    await _prefs!.setString(_kThreadsKey, raw);
  }

  // ==== Profile ====
  static Future<void> saveProfile(Map<String, String?> profile) async {
    await _ensure();
    await _prefs!.setString(_kProfileKey, jsonEncode(profile));
  }

  static Future<Map<String, String?>> loadProfile() async {
    await _ensure();
    final raw = _prefs!.getString(_kProfileKey);
    if (raw == null) return {};
    try {
      final j = Map<String, dynamic>.from(jsonDecode(raw));
      return j.map((k, v) => MapEntry(k, v?.toString()));
    } catch (_) {
      return {};
    }
  }

  // ==== Mood (latest-of-day, compatibility) ====
  static Future<void> saveMood(int mood, List<String> symptoms) async {
    await _ensure();
    final obj = {'mood': mood, 'symptoms': symptoms};
    await _prefs!.setString(_kMoodKey, jsonEncode(obj));
  }

  static Future<Map<String, dynamic>> loadMood() async {
    await _ensure();
    final raw = _prefs!.getString(_kMoodKey);
    if (raw == null) return {'mood': 3, 'symptoms': <String>[]};
    try {
      final j = Map<String, dynamic>.from(jsonDecode(raw));
      final mood = (j['mood'] as num?)?.toInt() ?? 3;
      final symptoms =
          (j['symptoms'] as List?)?.map((e) => e.toString()).toList() ??
              <String>[];
      return {'mood': mood, 'symptoms': symptoms};
    } catch (_) {
      return {'mood': 3, 'symptoms': <String>[]};
    }
  }

  // ==== Mood History (multi-day) ====
  static Future<List<MoodEntry>> loadMoodHistory() async {
    await _ensure();
    final raw = _prefs!.getString(_kMoodHistoryKey);
    if (raw == null) return [];
    try {
      final list = (jsonDecode(raw) as List);
      return list
          .map((e) => MoodEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveMoodHistory(List<MoodEntry> list) async {
    await _ensure();
    final raw = jsonEncode(list.map((e) => e.toJson()).toList());
    await _prefs!.setString(_kMoodHistoryKey, raw);
  }

  // ==== Utilities ====
  static Future<void> clearAll() async {
    await _ensure();
    await _prefs!.remove(_kThreadsKey);
    await _prefs!.remove(_kProfileKey);
    await _prefs!.remove(_kMoodKey);
    await _prefs!.remove(_kMoodHistoryKey);
  }
}

// -----------------------------------------------------------------------------
// Supabase Services
// -----------------------------------------------------------------------------

// แปลงเบอร์เป็น E.164 (+66) อัตโนมัติ
String normalizePhoneE164(String raw, {String defaultCountry = 'TH'}) {
  var s = raw.trim().replaceAll(RegExp(r'[\s\-()]'), '');
  if (s.startsWith('+')) return s;
  if (defaultCountry == 'TH') {
    if (s.startsWith('0')) return '+66${s.substring(1)}';
    if (RegExp(r'^\d{8,10}$').hasMatch(s)) return '+66$s';
  }
  if (RegExp(r'^\d+$').hasMatch(s)) return '+66$s';
  return s;
}

class AuthService {
  static Stream<sb.AuthState> authStateChanges() =>
      supabase.auth.onAuthStateChange;
  static String? get uid => supabase.auth.currentUser?.id;

  // ===== Email =====
  static Future<sb.AuthResponse> signUpEmail(
      String email, String password) async {
    return supabase.auth.signUp(
      email: email,
      password: password,
      emailRedirectTo: 'hereme://login-callback',
    );
  }

  static Future<sb.AuthResponse> signInEmail(
      String email, String password) async {
    return supabase.auth.signInWithPassword(email: email, password: password);
  }

  // ===== Phone + Password (สมัครครั้งแรกต้องยืนยัน OTP) =====
  // สมัครด้วย "เบอร์+รหัส" → ถ้ามี user เดิมอยู่แล้ว จะไม่พัง แต่จะส่ง OTP ให้ยืนยันแทน
  static Future<void> startPhonePassSignup({
    required String phoneRaw,
    required String password,
  }) async {
    final phone = normalizePhoneE164(phoneRaw);

    try {
      // พยายามสร้าง user ใหม่พร้อม password
      await supabase.auth.signUp(phone: phone, password: password);
    } on sb.AuthException catch (e) {
      // ถ้าเป็นเคสผู้ใช้มีอยู่แล้ว ให้ผ่านไปขั้นตอนส่ง OTP ได้เลย
      final msg = e.message.toLowerCase();
      final already = msg.contains('already') ||
          msg.contains('registered') ||
          msg.contains('exists');
      if (!already) rethrow;
    }

    // ส่ง OTP เพื่อยืนยันเบอร์ (ไม่สร้าง user ซ้ำ)
    await supabase.auth.signInWithOtp(
      phone: phone,
      channel: sb.OtpChannel.sms,
      shouldCreateUser: false,
    );
  }

  /// ยืนยัน OTP แล้ว "ตั้งรหัสผ่าน" ให้บัญชี (ทั้งเคสสมัครใหม่และเคสที่มีอยู่แล้ว)
  static Future<void> verifyPhonePassSignup({
    required String phoneRaw,
    required String code6,
    required String password, // รหัสที่ต้องการตั้งให้บัญชี
  }) async {
    final phone = normalizePhoneE164(phoneRaw);

    // 1) ยืนยัน OTP → ได้ session เข้ามา
    await supabase.auth.verifyOTP(
      phone: phone,
      token: code6,
      type: sb.OtpType.sms,
    );

    // 2) ตั้งรหัสผ่านให้บัญชีที่เพิ่งยืนยัน (ต้องมี session แล้ว)
    await supabase.auth.updateUser(sb.UserAttributes(password: password));

    // 3) (ออปชัน) เก็บสำรองลงตาราง phone_users เพื่อ debug/ตรวจสอบภายหลัง
    //    ถ้าไม่ต้องการเก็บซ้ำ ลบบล็อกนี้ออกได้เลย
    await supabase.from('phone_users').upsert(
      {
        'phone': phone,
        'password_hash': password,
        'created_at': DateTime.now().toIso8601String(),
      },
      onConflict: 'phone', // ถ้ามีเบอร์นี้อยู่แล้ว → อัปเดตแทน
    );
  }

  // ✅ alias ให้ตรงกับโค้ด UI เดิม (รับพารามิเตอร์แบบตำแหน่ง)
  static Future<void> signUpPhoneWithPassword(
    String phoneRaw,
    String password,
  ) {
    return startPhonePassSignup(phoneRaw: phoneRaw, password: password);
  }

  static Future<sb.AuthResponse> signInPhoneWithPassword(
    String phoneRaw,
    String password,
  ) async {
    final phone = normalizePhoneE164(phoneRaw);
    return supabase.auth.signInWithPassword(phone: phone, password: password);
  }

  // ===== Phone OTP (ล้วน) =====
  static Future<void> sendOtpToPhone(String phoneRaw) async {
    final phone = normalizePhoneE164(phoneRaw);
    await supabase.auth.signInWithOtp(
      phone: phone,
      channel: sb.OtpChannel.sms,
      shouldCreateUser: true,
    );
  }

  static Future<void> verifyPhoneOtp({
    required String phoneRaw,
    required String code6,
  }) async {
    final phone = normalizePhoneE164(phoneRaw);
    await supabase.auth.verifyOTP(
      phone: phone,
      token: code6,
      type: sb.OtpType.sms,
    );
  }

  static Future<void> signOut() => supabase.auth.signOut();

  // ===== OAuth =====
  static Future<void> signInOAuth(sb.OAuthProvider provider) async {
    await supabase.auth.signInWithOAuth(
      provider,
      redirectTo: 'hereme://login-callback',
    );
  }
}

class DBService {
  // ====== PROFILES ======
  static Future<Map<String, dynamic>?> fetchProfile() async {
    final uid = AuthService.uid;
    if (uid == null) return null;
    final res =
        await supabase.from('profiles').select().eq('id', uid).maybeSingle();
    return res;
  }

  static Future<void> upsertProfile({
    String? age,
    String? gender,
    String? occupation,
    String? status,
    String? displayName,
    String? avatarUrl,
  }) async {
    final uid = AuthService.uid;
    if (uid == null) return;

    final user = supabase.auth.currentUser;
    final safeName = displayName ??
        (user?.userMetadata?['full_name'] as String?) ??
        (user?.email?.split('@').first) ??
        (user?.phone) ??
        'HereMe User';

    await supabase.from('profiles').upsert({
      'id': uid,
      'display_name': safeName,
      if (avatarUrl != null) 'avatar_url': avatarUrl, // ✅ ได้ถ้า Dart >= 2.3
      'age': age,
      'gender': gender,
      'occupation': occupation, // ❗ ลบ backslash ทิ้ง
      'status': status,
      'updated_at': DateTime.now().toIso8601String(),
    }, onConflict: 'id');
  }

  // ====== THREADS ======
  static Future<List<ChatThread>> fetchThreads() async {
    final uid = AuthService.uid;
    if (uid == null) return [];
    final rows = await supabase
        .from('threads')
        .select()
        .eq('user_id', uid)
        .order('updated_at', ascending: false);
    return (rows as List)
        .map(
          (r) => ChatThread(
            id: r['id'].toString(),
            persona: r['persona'] ?? 'เพื่อน',
            topic: r['topic'] ?? 'การเรียน',
            createdAt:
                DateTime.tryParse(r['created_at'] ?? '') ?? DateTime.now(),
            updatedAt:
                DateTime.tryParse(r['updated_at'] ?? '') ?? DateTime.now(),
            messages: [],
          ),
        )
        .toList();
  }

  static Future<ChatThread?> createThread({
    required String persona,
    required String topic,
  }) async {
    final uid = AuthService.uid;
    if (uid == null) return null;

    // ✅ แก้จุดพัง: gen UUID ฝั่งแอปแล้วส่งไปเอง
    final tid = const Uuid().v4();

    final insert = await supabase
        .from('threads')
        .insert({
          'id': tid, // ส่ง id เอง → ไม่พึ่ง default DB
          'user_id': uid,
          'persona': persona,
          'topic': topic,
        })
        .select()
        .single();

    return ChatThread(
      id: insert['id'].toString(),
      persona: insert['persona'] ?? persona,
      topic: insert['topic'] ?? topic,
      createdAt:
          DateTime.tryParse(insert['created_at'] ?? '') ?? DateTime.now(),
      updatedAt:
          DateTime.tryParse(insert['updated_at'] ?? '') ?? DateTime.now(),
      messages: [],
    );
  }

  static Future<void> touchThread(String threadId) async {
    await supabase.from('threads').update(
        {'updated_at': DateTime.now().toIso8601String()}).eq('id', threadId);
  }

  // ====== MESSAGES ======
  static Future<List<ChatMessage>> fetchMessages(String threadId) async {
    final uid = AuthService.uid;
    if (uid == null) return [];
    final rows = await supabase
        .from('messages')
        .select()
        .eq('user_id', uid)
        .eq('thread_id', threadId)
        .order('created_at', ascending: true);
    return (rows as List)
        .map(
          (r) => ChatMessage(
            role: r['role'] ?? 'ai',
            text: r['text'] ?? '',
            time: DateTime.tryParse(r['created_at'] ?? '') ?? DateTime.now(),
          ),
        )
        .toList();
  }

  static Future<void> addMessage({
    required String threadId,
    required String role, // 'user' | 'ai'
    required String text,
  }) async {
    final uid = AuthService.uid;
    if (uid == null) return;
    await supabase.from('messages').insert({
      'user_id': uid,
      'thread_id': threadId, // ควรเป็น uuid ที่สอดคล้องกับ threads.id
      'role': role,
      'text': text,
    });
    await touchThread(threadId);
  }

  // ====== MOOD HISTORY ======
  static Future<List<MoodEntry>> fetchMoodHistory() async {
    final uid = AuthService.uid;
    if (uid == null) return [];
    final rows = await supabase
        .from('mood_history')
        .select()
        .eq('user_id', uid)
        .order('date', ascending: true);
    return (rows as List)
        .map(
          (r) => MoodEntry(
            date: DateTime.tryParse(r['date'] ?? '') ?? DateTime.now(),
            mood: (r['mood'] as num?)?.toInt() ?? 3,
          ),
        )
        .toList();
  }

  static Future<void> upsertTodayMood(int mood) async {
    final uid = AuthService.uid;
    if (uid == null) return;
    final today = DateTime.now();
    final dateOnly = DateTime(today.year, today.month, today.day);
    final updated = await supabase
        .from('mood_history')
        .update({'mood': mood})
        .eq('user_id', uid)
        .eq('date', dateOnly.toIso8601String().substring(0, 10))
        .select();
    if ((updated as List).isEmpty) {
      await supabase.from('mood_history').insert({
        'user_id': uid,
        'date': dateOnly.toIso8601String().substring(0, 10),
        'mood': mood,
      });
    }
  }

  // ====== Migration (local -> server at first login) ======
  static Future<void> migrateFromLocalIfNeeded() async {
    final uid = AuthService.uid;
    if (uid == null) return;

    final serverThreads = await fetchThreads();
    if (serverThreads.isNotEmpty) return;

    final localThreads = await AppStorage.loadThreads();
    final localMood = await AppStorage.loadMoodHistory();
    final localProfile = await AppStorage.loadProfile();
    final quickMood = await AppStorage.loadMood();

    if (localProfile.isNotEmpty) {
      await upsertProfile(
        age: localProfile['age'],
        gender: localProfile['gender'],
        occupation: localProfile['occupation'],
        status: localProfile['status'],
      );
    }

    if (quickMood['mood'] != null) {
      await upsertTodayMood((quickMood['mood'] as num).toInt());
    }

    for (final m in localMood) {
      await supabase.from('mood_history').upsert({
        'user_id': uid,
        'date': DateTime(
          m.date.year,
          m.date.month,
          m.date.day,
        ).toIso8601String().substring(0, 10),
        'mood': m.mood,
      }, onConflict: 'user_id,date');
    }

    for (final t in localThreads) {
      final created = await createThread(persona: t.persona, topic: t.topic);
      if (created == null) continue;
      for (final msg in t.messages) {
        await addMessage(
          threadId: created.id,
          role: msg.role == 'user' ? 'user' : 'ai',
          text: msg.text,
        );
      }
    }

    await AppStorage.clearAll();
  }
}

// -----------------------------------------------------------------------------
// Global AppState (ChangeNotifier) wired with Supabase DB
// -----------------------------------------------------------------------------
class AppState extends ChangeNotifier {
  static final AppState I = AppState._();
  AppState._();

  // Theme palette
  static const Color kSeedGreen = Color(0xFF2AC08E);
  static const Color kSoftGreen = Color(0xFFE7F6F0);

  // Profile & daily check-in (quick state)
  int todaysMood = 3; // 1–6
  List<String> todaysSymptoms = [];
  String? basicAge;
  String? basicGender;
  String? basicOccupation;
  String? basicStatus;

  // Persona/topic selections
  String selectedPersona = 'เพื่อน';
  String selectedTopic = 'การเรียน';

  // Threads
  final List<ChatThread> threads = [];
  ChatThread? currentThread;

  // Mood history (สำหรับกราฟจริง)
  final List<MoodEntry> moodHistory = [];

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool get isLoggedIn => AuthService.uid != null;

  Future<void> loadAll() async {
    if (!isLoggedIn) {
      final p = await AppStorage.loadProfile();
      basicAge = p['age'];
      basicGender = p['gender'];
      basicOccupation = p['occupation'];
      basicStatus = p['status'];

      final m = await AppStorage.loadMood();
      todaysMood = (m['mood'] as num?)?.toInt() ?? 3;
      todaysSymptoms = (m['symptoms'] as List?)?.cast<String>() ?? [];

      threads
        ..clear()
        ..addAll(await AppStorage.loadThreads());

      moodHistory
        ..clear()
        ..addAll(await AppStorage.loadMoodHistory());
      notifyListeners();
      return;
    }

    await DBService.migrateFromLocalIfNeeded();

    final prof = await DBService.fetchProfile();
    basicAge = prof?['age']?.toString();
    basicGender = prof?['gender']?.toString();
    basicOccupation = prof?['occupation']?.toString();
    basicStatus = prof?['status']?.toString();

    final mh = await DBService.fetchMoodHistory();
    moodHistory
      ..clear()
      ..addAll(mh);

    final now = DateTime.now();
    final todayIdx = moodHistory.indexWhere((e) => _isSameDay(e.date, now));
    if (todayIdx >= 0) {
      todaysMood = moodHistory[todayIdx].mood;
    }

    final ths = await DBService.fetchThreads();
    threads
      ..clear()
      ..addAll(ths);

    notifyListeners();
  }

  Future<void> setProfile({
    String? age,
    String? gender,
    String? occupation,
    String? status,
  }) async {
    basicAge = age ?? basicAge;
    basicGender = gender ?? basicGender;
    basicOccupation = occupation ?? basicOccupation;
    basicStatus = status ?? basicStatus;

    if (isLoggedIn) {
      await DBService.upsertProfile(
        age: basicAge,
        gender: basicGender,
        occupation: basicOccupation,
        status: basicStatus,
      );
    } else {
      await AppStorage.saveProfile({
        'age': basicAge,
        'gender': basicGender,
        'occupation': basicOccupation,
        'status': basicStatus,
      });
    }
    notifyListeners();
  }

  Future<void> upsertTodayMood(int mood) async {
    final now = DateTime.now();
    final idx = moodHistory.indexWhere((e) => _isSameDay(e.date, now));
    if (idx >= 0) {
      moodHistory[idx] = MoodEntry(date: moodHistory[idx].date, mood: mood);
    } else {
      moodHistory.add(MoodEntry(date: now, mood: mood));
    }
    todaysMood = mood;

    if (isLoggedIn) {
      await DBService.upsertTodayMood(mood);
    } else {
      await AppStorage.saveMood(todaysMood, todaysSymptoms);
      await AppStorage.saveMoodHistory(moodHistory);
    }
    notifyListeners();
  }

  void setMood(int v) {
    upsertTodayMood(v);
  }

  void toggleSymptom(String s) {
    todaysSymptoms.contains(s)
        ? todaysSymptoms.remove(s)
        : todaysSymptoms.add(s);
    AppStorage.saveMood(todaysMood, todaysSymptoms);
    notifyListeners();
  }

  void setPersona(String v) {
    selectedPersona = v;
    notifyListeners();
  }

  void setTopic(String v) {
    selectedTopic = v;
    notifyListeners();
  }

  Future<ChatThread?> createThread() async {
    if (isLoggedIn) {
      final created = await DBService.createThread(
        persona: selectedPersona,
        topic: selectedTopic,
      );
      if (created == null) return null;

      final intro = _personaIntro(selectedPersona, selectedTopic);
      await DBService.addMessage(threadId: created.id, role: 'ai', text: intro);

      final msgs = await DBService.fetchMessages(created.id);
      created.messages.addAll(msgs);

      threads.insert(0, created);
      currentThread = created;
      notifyListeners();
      return created;
    } else {
      final t = ChatThread(
        id: '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}',
        persona: selectedPersona,
        topic: selectedTopic,
      );
      final intro = _personaIntro(selectedPersona, selectedTopic);
      t.messages.add(ChatMessage(role: 'ai', text: intro));
      threads.insert(0, t);
      currentThread = t;
      _persistThreadsLocal();
      notifyListeners();
      return t;
    }
  }

  void selectThread(ChatThread t) {
    currentThread = t;
    notifyListeners();
  }

  Future<void> renameThread(
    ChatThread t, {
    String? persona,
    String? topic,
  }) async {
    t.persona = persona ?? t.persona;
    t.topic = topic ?? t.topic;
    t.updatedAt = DateTime.now();

    if (isLoggedIn) {
      await supabase.from('threads').update({
        'persona': t.persona,
        'topic': t.topic,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', t.id);
    } else {
      _persistThreadsLocal();
    }
    notifyListeners();
  }

  Future<void> deleteThread(ChatThread t) async {
    if (currentThread?.id == t.id) currentThread = null;
    threads.removeWhere((x) => x.id == t.id);

    if (isLoggedIn) {
      await supabase.from('threads').delete().eq('id', t.id);
    } else {
      _persistThreadsLocal();
    }
    notifyListeners();
  }

  Future<void> addMessageToCurrent(ChatMessage m) async {
    if (currentThread == null) return;
    currentThread!.messages.add(m);
    currentThread!.updatedAt = DateTime.now();
    if (isLoggedIn) {
      await DBService.addMessage(
        threadId: currentThread!.id,
        role: m.role,
        text: m.text,
      );
    } else {
      _persistThreadsLocal();
    }
    notifyListeners();
  }

  void editLastMessage(String newText) {
    if (currentThread == null) return;
    final msgs = currentThread!.messages;
    if (msgs.isEmpty) return;
    msgs.last.text = newText;
    _persistThreadsLocal();
    notifyListeners();
  }

  Future<void> loadMessagesForCurrent() async {
    if (!isLoggedIn || currentThread == null) return;
    final msgs = await DBService.fetchMessages(currentThread!.id);
    currentThread!.messages
      ..clear()
      ..addAll(msgs);
    notifyListeners();
  }

  void _persistThreadsLocal() => AppStorage.saveThreads(threads);

  String _personaIntro(String persona, String topic) =>
      'สวัสดี เราเป็น$persona ที่พร้อมรับฟังนะ วันนี้อยากคุยเรื่อง“$topic”ใช่ไหม ลองเล่าได้เลย ทุกอย่างเป็นความลับและคุณควบคุมการสนทนาได้เสมอ';
}

// -----------------------------------------------------------------------------
// App + Theme
// -----------------------------------------------------------------------------
class HereMeApp extends StatefulWidget {
  const HereMeApp({super.key});
  @override
  State<HereMeApp> createState() => _HereMeAppState();
}

class _HereMeAppState extends State<HereMeApp> {
  final _navKey = GlobalKey<NavigatorState>();
  StreamSubscription<sb.AuthState>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = AuthService.authStateChanges().listen((state) async {
      debugPrint('Auth event: ${state.event}');
      await AppState.I.loadAll();

      final nav = _navKey.currentState;
      if (nav == null) return;

      switch (state.event) {
        case sb.AuthChangeEvent.signedIn:
        case sb.AuthChangeEvent.userUpdated:
          nav.pushNamedAndRemoveUntil('/home', (r) => false);
          break;
        case sb.AuthChangeEvent.signedOut:
          nav.pushNamedAndRemoveUntil('/login', (r) => false);
          break;
        default:
          break;
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seed = AppState.kSeedGreen;

    return AnimatedBuilder(
      animation: AppState.I,
      builder: (_, __) {
        return MaterialApp(
          navigatorKey: _navKey,
          debugShowCheckedModeBanner: false,
          title: 'HereMe',
          theme: ThemeData(
            useMaterial3: true,
            fontFamily: 'NotoSansThai',
            colorScheme: ColorScheme.fromSeed(
              seedColor: seed,
              brightness: Brightness.light,
            ).copyWith(
              primary: seed,
              secondary: const Color(0xFF4AD6A6),
              surface: Colors.white,
            ),
            scaffoldBackgroundColor: Colors.white,

            // ✅ ต้องเป็น CardThemeData (ไม่ใช่ CardTheme)
            cardTheme: const CardThemeData(
              color: Colors.white,
              elevation: 1,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(20)),
              ),
            ),

            appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: const Color(0xFFF6F9F7),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
            ),
            listTileTheme: ListTileThemeData(iconColor: seed),
          ),
          routes: {
            '/': (_) => const _Boot(),
            '/login': (_) => const LoginPage(),
            '/checkin': (_) => const DailyCheckInPage(),
            '/home': (_) => const HomePage(),
            '/safe': (_) => const SafeEmotionalSharingPage(),
            '/chat': (_) => const ChatPage(),
            '/history': (_) => const ChatHistoryPage(),
            '/guide': (_) => const CareerGuidePage(),
            '/matching': (_) => const MentorMatchingPage(),
            '/profile': (_) => const ProfilePage(),
          },
          initialRoute: '/',
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// _Boot — หน้าโหลดในแอป (แทนที่จะขึ้นโลโก้ Flutter ขณะบูตแอปของเราเอง)
//   หมายเหตุ: อันนี้คือ "in-app splash" หลังจากรันแอปแล้ว
//   ถ้าต้องการ Splash ของ OS ตอนเปิดแอป (ก่อนเฟรมแรก) ต้องตั้งค่า
//   flutter_native_splash เพิ่ม ตามขั้นตอนที่ให้ด้านล่าง
// -----------------------------------------------------------------------------
// Splash (in-app) — โลโก้ย่ออัตโนมัติให้ไม่ใหญ่เกินไป
class _Boot extends StatefulWidget {
  const _Boot();
  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 600))
    ..forward();
  late final Animation<double> _fade =
      CurvedAnimation(parent: _ac, curve: Curves.easeOut);

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      try {
        await AppStorage.init();
        await AppState.I.loadAll();
      } catch (e, st) {
        debugPrint('Boot error: $e\n$st');
      } finally {
        if (!mounted) return;
        await Future.delayed(const Duration(milliseconds: 400));
        Navigator.pushReplacementNamed(
          context,
          AuthService.uid != null ? '/home' : '/login',
        );
      }
    });
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const kLogoFraction =
        0.62; // สัดส่วนกว้างของโลโก้เทียบกับหน้าจอ (ลด/เพิ่มได้)
    const kLogoMaxWidth = 420.0; // ไม่ให้เกิน 420px บนอุปกรณ์ใหญ่

    return Scaffold(
      body: FadeTransition(
        opacity: _fade,
        child: LayoutBuilder(
          builder: (context, cons) {
            final logoWidth =
                (cons.maxWidth * kLogoFraction).clamp(0.0, kLogoMaxWidth);
            return Stack(
              fit: StackFit.expand,
              children: [
                // พื้นหลัง
                const ColoredBox(color: Colors.white),

                // โลโก้ย่ออัตโนมัติ (ไม่เต็มจอ)
                Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: logoWidth,
                    ),
                    child: AspectRatio(
                      // ถ้ารูปเป็นสี่เหลี่ยมจัตุรัส ตั้ง 1/1; ถ้าเป็นสัดส่วนอื่นเอาออกได้
                      aspectRatio: 1,
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: Image.asset(
                          'assets/hereme.png',
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// -----------------------------
// Login Page (วางแทนของเดิมได้เลย)
// -----------------------------
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

enum AuthMethod { email, phonePass, phoneOtp }

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);

  // Email login
  final _loginEmail = TextEditingController();
  final _loginPass = TextEditingController();

  // Email sign up
  final _signupEmail = TextEditingController();
  final _signupPass = TextEditingController();

  // Phone+Password (login)
  final _loginPhonePass = TextEditingController();
  final _loginPhonePassPwd = TextEditingController();

  // Phone+Password (signup)
  final _signupPhonePass = TextEditingController();
  final _signupPhonePassPwd = TextEditingController();
  // ใหม่: OTP สำหรับ “สมัครด้วยเบอร์+รหัส”
  final _otpSignupPass = TextEditingController();

  // Phone OTP (login)
  final _phoneLogin = TextEditingController();
  final _otpLogin = TextEditingController();

  // Phone OTP (signup)
  final _phoneSignup = TextEditingController();
  final _otpSignup = TextEditingController();

  AuthMethod loginMethod = AuthMethod.email;
  AuthMethod signupMethod = AuthMethod.email;

  bool _busy = false;
  bool _awaitingOtpLogin = false;
  bool _awaitingOtpSignup = false;
  // ใหม่: กำลังรอ OTP ของ flow “สมัครด้วยเบอร์+รหัส”
  bool _awaitingPhonePassOtp = false;

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // =========================
  // Email flows
  // =========================
  Future<void> _doEmailLogin() async {
    final email = _loginEmail.text.trim();
    final pwd = _loginPass.text.trim();
    if (email.isEmpty || pwd.isEmpty) {
      _snack('กรอกอีเมลและรหัสผ่านก่อน');
      return;
    }
    setState(() => _busy = true);
    try {
      await AuthService.signInEmail(email, pwd);
    } on sb.AuthException catch (e) {
      _snack('เข้าสู่ระบบไม่สำเร็จ: ${e.message}');
    } catch (e) {
      _snack('ผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doEmailSignup() async {
    final email = _signupEmail.text.trim();
    final pwd = _signupPass.text.trim();
    if (email.isEmpty || pwd.isEmpty) {
      _snack('กรอกอีเมลและรหัสผ่านก่อน');
      return;
    }
    setState(() => _busy = true);
    try {
      await AuthService.signUpEmail(email, pwd);
      _snack('สมัครสำเร็จ! กรุณายืนยันอีเมล (ถ้าตั้งค่าให้ต้องยืนยัน)');
    } on sb.AuthException catch (e) {
      _snack('สมัครสมาชิกไม่สำเร็จ: ${e.message}');
    } catch (e) {
      _snack('ผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // =========================
  // Phone + Password flows
  // =========================
  Future<void> _doPhonePassLogin() async {
    final phone = _loginPhonePass.text.trim();
    final pwd = _loginPhonePassPwd.text.trim();
    if (phone.isEmpty || pwd.isEmpty) {
      _snack('กรอกเบอร์และรหัสผ่านก่อน');
      return;
    }
    setState(() => _busy = true);
    try {
      await AuthService.signInPhoneWithPassword(phone, pwd);
    } on sb.AuthException catch (e) {
      _snack('เข้าสู่ระบบไม่สำเร็จ: ${e.message}');
    } catch (e) {
      _snack('ผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// สมัคร “เบอร์ + รหัส” แล้วให้ระบบส่ง OTP ไปที่เบอร์
  Future<void> _doPhonePassSignup() async {
    final phone = _signupPhonePass.text.trim();
    final pwd = _signupPhonePassPwd.text.trim();
    if (phone.isEmpty || pwd.isEmpty) {
      _snack('กรอกเบอร์และรหัสผ่านก่อน');
      return;
    }

    setState(() => _busy = true);
    try {
      // 1) สร้าง user พร้อม password
      await AuthService.signUpPhoneWithPassword(phone, pwd);
      // 2) ส่ง OTP เพื่อยืนยันเบอร์
      setState(() => _awaitingPhonePassOtp = true);
      _snack(
          'สมัครสำเร็จ! ส่ง OTP ไปทาง SMS แล้ว กรุณากรอกรหัส 6 หลักเพื่อยืนยันเบอร์');
    } on sb.AuthException catch (e) {
      _snack('สมัครสมาชิกไม่สำเร็จ: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// ยืนยัน OTP หลังสมัครด้วยเบอร์+รหัส  ✅ ส่ง password ไปบันทึกใน phone_users
  Future<void> _verifyPhonePassSignupOtp() async {
    final phone = _signupPhonePass.text.trim();
    final code = _otpSignupPass.text.trim();
    final pwd = _signupPhonePassPwd.text.trim();
    if (phone.isEmpty || code.isEmpty) {
      _snack('กรอกเบอร์และรหัส 6 หลักก่อน');
      return;
    }

    setState(() => _busy = true);
    try {
      await AuthService.verifyPhonePassSignup(
        phoneRaw: phone,
        code6: code,
        password: pwd, // <-- สำคัญ
      );
      _snack('ยืนยันเบอร์สำเร็จ! ตอนนี้ล็อกอินด้วย “เบอร์ + รหัส” ได้แล้ว');
      setState(() => _awaitingPhonePassOtp = false);
    } on sb.AuthException catch (e) {
      _snack('รหัสไม่ถูกต้อง: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // =========================
  // Phone OTP (ล้วน)
  // =========================
  Future<void> _sendLoginOtp() async {
    final phone = _phoneLogin.text.trim();
    if (phone.isEmpty) {
      _snack('กรอกเบอร์โทรก่อน');
      return;
    }
    setState(() => _busy = true);
    try {
      await AuthService.sendOtpToPhone(phone);
      setState(() => _awaitingOtpLogin = true);
      _snack('ส่งรหัส 6 หลักทาง SMS แล้ว');
    } on sb.AuthException catch (e) {
      _snack('ส่งรหัสไม่สำเร็จ: ${e.message}');
    } catch (e) {
      _snack('ผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyLoginOtp() async {
    final phone = _phoneLogin.text.trim();
    final code = _otpLogin.text.trim();
    if (phone.isEmpty || code.isEmpty) {
      _snack('กรอกเบอร์และรหัส 6 หลักก่อน');
      return;
    }
    setState(() => _busy = true);
    try {
      await AuthService.verifyPhoneOtp(phoneRaw: phone, code6: code);
    } on sb.AuthException catch (e) {
      _snack('รหัสไม่ถูกต้อง: ${e.message}');
    } catch (e) {
      _snack('ผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendSignupOtp() async {
    final phone = _phoneSignup.text.trim();
    if (phone.isEmpty) {
      _snack('กรอกเบอร์โทรก่อน');
      return;
    }
    setState(() => _busy = true);
    try {
      await AuthService.sendOtpToPhone(phone);
      setState(() => _awaitingOtpSignup = true);
      _snack('ส่งรหัส 6 หลักทาง SMS แล้ว');
    } on sb.AuthException catch (e) {
      _snack('ส่งรหัสไม่สำเร็จ: ${e.message}');
    } catch (e) {
      _snack('ผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifySignupOtp() async {
    final phone = _phoneSignup.text.trim();
    final code = _otpSignup.text.trim();
    if (phone.isEmpty || code.isEmpty) {
      _snack('กรอกเบอร์และรหัส 6 หลักก่อน');
      return;
    }
    setState(() => _busy = true);
    try {
      await AuthService.verifyPhoneOtp(phoneRaw: phone, code6: code);
      _snack('ยืนยันเบอร์สำเร็จ!');
    } on sb.AuthException catch (e) {
      _snack('รหัสไม่ถูกต้อง: ${e.message}');
    } catch (e) {
      _snack('ผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // =========================
  // OAuth
  // =========================
  Future<void> _doOAuth(sb.OAuthProvider p) async {
    setState(() => _busy = true);
    try {
      await AuthService.signInOAuth(p);
    } on sb.AuthException catch (e) {
      _snack('OAuth ล้มเหลว: ${e.message}');
    } catch (e) {
      _snack('ผิดพลาด: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ปุ่ม OAuth ขนาดเท่ากัน
  Widget _oauthButton({
    required IconData icon,
    required String label,
    Color? bg,
    Color? fg,
    VoidCallback? onPressed,
    BorderSide? side,
  }) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _busy ? null : onPressed,
        icon: Icon(icon),
        label: Text(label),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          backgroundColor: bg,
          foregroundColor: fg,
          side: side,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, cons) {
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: cons.maxHeight),
                child: Column(
                  children: [
                    const SizedBox(height: 6),
                    Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        color: cs.primary.withOpacity(.12),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Icon(Icons.favorite, size: 36),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'HereMe',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Tabs
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0F7F3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TabBar(
                        controller: _tab,
                        dividerColor: Colors.transparent,
                        labelColor: Colors.black,
                        unselectedLabelColor: Colors.black54,
                        tabs: const [
                          Tab(text: 'เข้าสู่ระบบ'),
                          Tab(text: 'สมัครสมาชิก'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ใช้ ListView ภายในแต่ละแท็บเพื่อกัน overflow
                    SizedBox(
                      height: 500,
                      child: TabBarView(
                        controller: _tab,
                        children: [
                          // --------------- LOGIN TAB ---------------
                          ListView(
                            padding: EdgeInsets.zero,
                            children: [
                              const Text(
                                'เลือกรูปแบบเข้าสู่ระบบ',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              SegmentedButton<AuthMethod>(
                                segments: const [
                                  ButtonSegment(
                                    value: AuthMethod.email,
                                    label: Text('อีเมล'),
                                  ),
                                  ButtonSegment(
                                    value: AuthMethod.phonePass,
                                    label: Text('เบอร์ + รหัส'),
                                  ),
                                  ButtonSegment(
                                    value: AuthMethod.phoneOtp,
                                    label: Text('เบอร์ (OTP)'),
                                  ),
                                ],
                                selected: {loginMethod},
                                onSelectionChanged: (s) =>
                                    setState(() => loginMethod = s.first),
                              ),
                              const SizedBox(height: 12),
                              if (loginMethod == AuthMethod.email) ...[
                                TextField(
                                  controller: _loginEmail,
                                  keyboardType: TextInputType.emailAddress,
                                  decoration: const InputDecoration(
                                    labelText: 'Email',
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _loginPass,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Password',
                                  ),
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed: _busy ? null : _doEmailLogin,
                                    child: const Text('เข้าสู่ระบบ'),
                                  ),
                                ),
                              ] else if (loginMethod ==
                                  AuthMethod.phonePass) ...[
                                TextField(
                                  controller: _loginPhonePass,
                                  keyboardType: TextInputType.phone,
                                  decoration: const InputDecoration(
                                    labelText: 'เบอร์โทร (0 หรือ +66 ก็ได้)',
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _loginPhonePassPwd,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'รหัสผ่าน',
                                  ),
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed: _busy ? null : _doPhonePassLogin,
                                    child: const Text('เข้าสู่ระบบ'),
                                  ),
                                ),
                              ] else ...[
                                TextField(
                                  controller: _phoneLogin,
                                  keyboardType: TextInputType.phone,
                                  decoration: const InputDecoration(
                                    labelText: 'เบอร์โทร (0 หรือ +66 ก็ได้)',
                                  ),
                                ),
                                const SizedBox(height: 10),
                                if (_awaitingOtpLogin)
                                  TextField(
                                    controller: _otpLogin,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'รหัส 6 หลัก',
                                    ),
                                  ),
                                const SizedBox(height: 14),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton(
                                        onPressed: _busy ? null : _sendLoginOtp,
                                        child: const Text('ส่งรหัส'),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: FilledButton(
                                        onPressed: (_busy || !_awaitingOtpLogin)
                                            ? null
                                            : _verifyLoginOtp,
                                        child: const Text('ยืนยันรหัส'),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 16),
                              _oauthButton(
                                icon: Icons.apple,
                                label: 'Sign in with Apple',
                                bg: Colors.black,
                                fg: Colors.white,
                                onPressed: () =>
                                    _doOAuth(sb.OAuthProvider.apple),
                              ),
                              const SizedBox(height: 8),
                              _oauthButton(
                                icon: Icons.facebook,
                                label: 'Sign in with Facebook',
                                bg: const Color(0xFF1877F2),
                                fg: Colors.white,
                                onPressed: () =>
                                    _doOAuth(sb.OAuthProvider.facebook),
                              ),
                              const SizedBox(height: 8),
                              _oauthButton(
                                icon: Icons.g_mobiledata,
                                label: 'Sign in with Google',
                                bg: Colors.white,
                                fg: Colors.black87,
                                side: const BorderSide(color: Colors.black12),
                                onPressed: () =>
                                    _doOAuth(sb.OAuthProvider.google),
                              ),
                            ],
                          ),

                          // --------------- SIGN UP TAB ---------------
                          ListView(
                            padding: EdgeInsets.zero,
                            children: [
                              const Text(
                                'เลือกรูปแบบสมัครสมาชิก',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              SegmentedButton<AuthMethod>(
                                segments: const [
                                  ButtonSegment(
                                    value: AuthMethod.email,
                                    label: Text('อีเมล'),
                                  ),
                                  ButtonSegment(
                                    value: AuthMethod.phonePass,
                                    label: Text('เบอร์ + รหัส'),
                                  ),
                                  ButtonSegment(
                                    value: AuthMethod.phoneOtp,
                                    label: Text('เบอร์ (OTP)'),
                                  ),
                                ],
                                selected: {signupMethod},
                                onSelectionChanged: (s) =>
                                    setState(() => signupMethod = s.first),
                              ),
                              const SizedBox(height: 12),
                              if (signupMethod == AuthMethod.email) ...[
                                TextField(
                                  controller: _signupEmail,
                                  keyboardType: TextInputType.emailAddress,
                                  decoration: const InputDecoration(
                                    labelText: 'Email',
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _signupPass,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Password (min 6)',
                                  ),
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed: _busy ? null : _doEmailSignup,
                                    child: const Text('สมัครสมาชิก'),
                                  ),
                                ),
                              ] else if (signupMethod ==
                                  AuthMethod.phonePass) ...[
                                TextField(
                                  controller: _signupPhonePass,
                                  keyboardType: TextInputType.phone,
                                  decoration: const InputDecoration(
                                    labelText: 'เบอร์โทร (0 หรือ +66 ก็ได้)',
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _signupPhonePassPwd,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'รหัสผ่าน (อย่างน้อย 6 ตัว)',
                                  ),
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed:
                                        _busy ? null : _doPhonePassSignup,
                                    child: const Text('สมัครสมาชิก'),
                                  ),
                                ),

                                // แสดงช่องกรอก OTP เมื่อระบบส่งรหัสแล้ว
                                if (_awaitingPhonePassOtp) ...[
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _otpSignupPass,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'รหัส 6 หลัก (OTP)',
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton(
                                      onPressed: _busy
                                          ? null
                                          : _verifyPhonePassSignupOtp,
                                      child: const Text('ยืนยัน OTP'),
                                    ),
                                  ),
                                ],
                              ] else ...[
                                TextField(
                                  controller: _phoneSignup,
                                  keyboardType: TextInputType.phone,
                                  decoration: const InputDecoration(
                                    labelText: 'เบอร์โทร (0 หรือ +66 ก็ได้)',
                                  ),
                                ),
                                const SizedBox(height: 10),
                                if (_awaitingOtpSignup)
                                  TextField(
                                    controller: _otpSignup,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'รหัส 6 หลัก',
                                    ),
                                  ),
                                const SizedBox(height: 14),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton(
                                        onPressed:
                                            _busy ? null : _sendSignupOtp,
                                        child: const Text('ส่งรหัส'),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: FilledButton(
                                        onPressed:
                                            (_busy || !_awaitingOtpSignup)
                                                ? null
                                                : _verifySignupOtp,
                                        child: const Text('ยืนยันรหัส'),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              if (_loginEmail.text.trim().isEmpty) {
                                _snack('กรอกอีเมลในฟอร์มเข้าสู่ระบบก่อน');
                                return;
                              }
                              try {
                                await supabase.auth.resetPasswordForEmail(
                                  _loginEmail.text.trim(),
                                  redirectTo: 'hereme://login-callback',
                                );
                                _snack('ส่งลิงก์รีเซ็ตรหัสผ่านแล้ว');
                              } catch (e) {
                                _snack('ส่งลิงก์ไม่สำเร็จ: $e');
                              }
                            },
                      child: const Text('ลืมรหัสผ่าน (Forgot?)'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Daily Check-in
// -----------------------------------------------------------------------------
class DailyCheckInPage extends StatefulWidget {
  const DailyCheckInPage({super.key});
  @override
  State<DailyCheckInPage> createState() => _DailyCheckInPageState();
}

class _DailyCheckInPageState extends State<DailyCheckInPage> {
  final symptoms = const [
    'นอนไม่หลับ',
    'ปวดหัว',
    'วิตกกังวล',
    'เบื่ออาหาร',
    'เหงา',
    'ไม่มีแรงใจ',
  ];
  final ageCtrl = TextEditingController();
  final genders = const ['ชาย', 'หญิง', 'อื่น ๆ'];
  final occupations = const [
    'นักเรียน/นักศึกษา',
    'ทำงานประจำ',
    'อิสระ',
    'อื่น ๆ',
  ];
  final statuses = const ['โสด', 'คบหา', 'แต่งงาน', 'อื่น ๆ'];
  String? gender;
  String? occ;
  String? status;

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        return Scaffold(
          body: SafeArea(
            child: CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(
                  child: _TopHero(
                    title: 'ก่อนเข้าใช้งาน',
                    subtitle: 'ตอบคำถามประจำวันเพื่อประเมินอารมณ์',
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      _SectionCard(
                        children: [
                          const _CardTitle('ข้อมูลพื้นฐาน'),
                          TextField(
                            controller: ageCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'โปรดระบุอายุ',
                            ),
                          ),
                          const SizedBox(height: 10),
                          _DropdownField(
                            label: 'เพศ',
                            items: genders,
                            value: gender,
                            onChanged: (v) => setState(() => gender = v),
                          ),
                          const SizedBox(height: 10),
                          _DropdownField(
                            label: 'อาชีพ',
                            items: occupations,
                            value: occ,
                            onChanged: (v) => setState(() => occ = v),
                          ),
                          const SizedBox(height: 10),
                          _DropdownField(
                            label: 'สถานะ',
                            items: statuses,
                            value: status,
                            onChanged: (v) => setState(() => status = v),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () {},
                              child: const Text('อ่านเพิ่มเติม'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _SectionCard(
                        children: [
                          const _CardTitle('วันนี้สบายดีไหม?'),
                          Wrap(
                            spacing: 8,
                            children: List.generate(6, (i) {
                              final n = i + 1;
                              final sel = app.todaysMood == n;
                              return ChoiceChip(
                                label: Text('$n'),
                                selected: sel,
                                selectedColor: cs.primaryContainer,
                                onSelected: (_) => app.setMood(n),
                              );
                            }),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: const [Text('ไม่ดี'), Text('ดีมาก')],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _SectionCard(
                        children: [
                          const _CardTitle(
                            'มีอาการเหล่านี้บ้างไหม (เลือกได้หลายข้อ)',
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final s in symptoms)
                                FilterChip(
                                  label: Text(s),
                                  selected: app.todaysSymptoms.contains(s),
                                  selectedColor: cs.secondaryContainer,
                                  onSelected: (_) => app.toggleSymptom(s),
                                ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: () async {
                          await AppState.I.setProfile(
                            age: ageCtrl.text.trim().isEmpty
                                ? null
                                : ageCtrl.text.trim(),
                            gender: gender,
                            occupation: occ,
                            status: status,
                          );
                          if (context.mounted) {
                            Navigator.pushReplacementNamed(context, '/home');
                          }
                        },
                        icon: const Icon(Icons.login),
                        label: const Text('เข้าใช้งาน'),
                      ),
                      const SizedBox(height: 80),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TopHero extends StatelessWidget {
  final String title;
  final String subtitle;
  const _TopHero({required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            colors: [AppState.kSeedGreen, Color(0xFF4AD6A6)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            const Text(
              'HereMe',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 6),
            Text(subtitle, style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}

class _CardTitle extends StatelessWidget {
  final String text;
  const _CardTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
      );
}

class _SectionCard extends StatelessWidget {
  final List<Widget> children;
  const _SectionCard({required this.children});
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

class _DropdownField extends StatelessWidget {
  final String label;
  final List<String> items;
  final String? value;
  final ValueChanged<String?> onChanged;
  const _DropdownField({
    required this.label,
    required this.items,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final safeValue = (value != null && items.contains(value)) ? value : null;
    return DropdownButtonFormField<String>(
      value: safeValue,
      items: items
          .map((e) => DropdownMenuItem<String>(value: e, child: Text(e)))
          .toList(),
      onChanged: onChanged,
      decoration: InputDecoration(labelText: label),
    );
  }
}

// -----------------------------------------------------------------------------
// MoodChartPage — เลือก “เดือน” ด้านบน + กราฟรายวันของเดือนนั้น (1–6)
//   • ดึงเดือนทั้งหมดที่มีข้อมูลจาก AppState.I.moodHistory
//   • กราฟเส้นโค้ง + จุด + เส้นกริด 6 ระดับ
//   • ปรับ label วันอัตโนมัติ (間隔 2–5 วันแล้วแต่ความกว้าง)
// -----------------------------------------------------------------------------
class MoodChartPage extends StatefulWidget {
  const MoodChartPage({super.key});
  @override
  State<MoodChartPage> createState() => _MoodChartPageState();
}

class _MoodChartPageState extends State<MoodChartPage> {
  late DateTime _selectedMonth; // เดือนที่เลือก (year, month, day=1)

  @override
  void initState() {
    super.initState();
    final all = AppState.I.moodHistory;
    if (all.isNotEmpty) {
      final last = all.last.date;
      _selectedMonth = DateTime(last.year, last.month, 1);
    } else {
      final now = DateTime.now();
      _selectedMonth = DateTime(now.year, now.month, 1);
    }
  }

  List<DateTime> _availableMonths(List<MoodEntry> all) {
    final set = <String, DateTime>{};
    for (final e in all) {
      final d = DateTime(e.date.year, e.date.month, 1);
      set['${d.year}-${d.month}'] = d;
    }
    final list = set.values.toList()..sort((a, b) => a.compareTo(b));
    return list;
  }

  List<MoodEntry> _dataOfMonth(DateTime month, List<MoodEntry> all) {
    final start = DateTime(month.year, month.month, 1);
    final end = DateTime(month.year, month.month + 1, 1)
        .subtract(const Duration(milliseconds: 1));
    // ถ้าวันเดียวมีหลายค่า ให้เอาค่าสุดท้ายของวันนั้น
    final map = <String, MoodEntry>{};
    for (final e in all) {
      if (e.date.isBefore(start) || e.date.isAfter(end)) continue;
      final key = '${e.date.year}-${e.date.month}-${e.date.day}';
      map[key] = MoodEntry(
        date: DateTime(e.date.year, e.date.month, e.date.day),
        mood: e.mood,
      );
    }
    final arr = map.values.toList()..sort((a, b) => a.date.compareTo(b.date));
    return arr;
  }

  String _ymLabel(DateTime d) {
    const thMonths = [
      '',
      'ม.ค.',
      'ก.พ.',
      'มี.ค.',
      'เม.ย.',
      'พ.ค.',
      'มิ.ย.',
      'ก.ค.',
      'ส.ค.',
      'ก.ย.',
      'ต.ค.',
      'พ.ย.',
      'ธ.ค.'
    ];
    return '${thMonths[d.month]} ${d.year + 543}';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: app,
      builder: (_, __) {
        final months = _availableMonths(app.moodHistory);
        final data = _dataOfMonth(_selectedMonth, app.moodHistory);

        return Scaffold(
          appBar: AppBar(title: const Text('กราฟสถิติย้อนหลัง')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ----- เลือกเดือน -----
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.calendar_month),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<DateTime>(
                          value: months.isEmpty
                              ? _selectedMonth
                              : months.contains(_selectedMonth)
                                  ? _selectedMonth
                                  : months.last,
                          decoration: const InputDecoration(
                            labelText: 'เลือกเดือน',
                          ),
                          items: (months.isEmpty ? [_selectedMonth] : months)
                              .map((m) => DropdownMenuItem(
                                    value: m,
                                    child: Text(_ymLabel(m)),
                                  ))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _selectedMonth = v);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // ----- กราฟรายวันของเดือนที่เลือก -----
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'รายเดือน • ${_ymLabel(_selectedMonth)}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 260,
                        child: _MonthlyMoodChart(
                          entries: data,
                          month: _selectedMonth,
                          lineColor: cs.primary,
                          dotColor: cs.primary,
                          gridColor: Colors.black12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text('สเกลอารมณ์: 1 (แย่)  …  6 (ดีมาก)',
                          style:
                              TextStyle(fontSize: 11, color: Colors.black54)),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),
              const _SafetyFooter(),
            ],
          ),
        );
      },
    );
  }
}

class _MonthlyMoodChart extends StatelessWidget {
  final List<MoodEntry> entries;
  final DateTime month;
  final Color lineColor;
  final Color dotColor;
  final Color gridColor;

  const _MonthlyMoodChart({
    required this.entries,
    required this.month,
    required this.lineColor,
    required this.dotColor,
    required this.gridColor,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _MonthlyMoodPainter(
        entries: entries,
        month: month,
        lineColor: lineColor,
        dotColor: dotColor,
        gridColor: gridColor,
      ),
      size: Size.infinite,
    );
  }
}

class _MonthlyMoodPainter extends CustomPainter {
  final List<MoodEntry> entries;
  final DateTime month;
  final Color lineColor;
  final Color dotColor;
  final Color gridColor;

  _MonthlyMoodPainter({
    required this.entries,
    required this.month,
    required this.lineColor,
    required this.dotColor,
    required this.gridColor,
  });

  int _daysInMonth(DateTime m) =>
      DateTime(m.year, m.month + 1, 0).day; // last day of month

  @override
  void paint(Canvas canvas, Size size) {
    final padding = const EdgeInsets.fromLTRB(36, 14, 14, 36);
    final chart = Rect.fromLTWH(
      padding.left,
      padding.top,
      size.width - padding.horizontal,
      size.height - padding.vertical,
    );

    // ----- กริดแนวนอน 6 ระดับ (mood 1..6)
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (int i = 0; i <= 5; i++) {
      final y = chart.top + (chart.height / 5) * i;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
      final moodValue = (6 - i).toString();
      tp.text = TextSpan(
        text: moodValue,
        style: const TextStyle(fontSize: 10, color: Colors.black54),
      );
      tp.layout();
      tp.paint(canvas, Offset(chart.left - 22, y - tp.height / 2));
    }

    // ----- เตรียมข้อมูลรายวันของเดือน
    final totalDays = _daysInMonth(month);
    // map day -> mood
    final byDay = <int, int>{};
    for (final e in entries) {
      if (e.date.year == month.year && e.date.month == month.month) {
        byDay[e.date.day] = e.mood;
      }
    }

    if (totalDays <= 0) return;

    // ----- scale x/y
    final dx = chart.width / (totalDays - 1).clamp(1, 9999);
    Offset pOf(int day, int mood) {
      final x = chart.left + dx * (day - 1);
      final t = (mood - 1) / 5.0; // 1..6 → 0..1
      final y = chart.bottom - t * chart.height;
      return Offset(x, y);
    }

    // ----- เส้นโค้ง (cubic) + จุด
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke;
    final dotPaint = Paint()
      ..color = dotColor
      ..style = PaintingStyle.fill;

    // สร้างลิสต์จุดตามวันที่มีข้อมูล
    final points = <Offset>[];
    final daysSorted = byDay.keys.toList()..sort();
    for (final d in daysSorted) {
      points.add(pOf(d, byDay[d]!));
    }

    if (points.isNotEmpty) {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (int i = 1; i < points.length; i++) {
        final p0 = points[i - 1];
        final p1 = points[i];
        final cx = (p0.dx + p1.dx) / 2;
        // ใช้ curve ง่าย ๆ (Catmull-like) เพื่อความลื่นตา
        path.cubicTo(cx, p0.dy, cx, p1.dy, p1.dx, p1.dy);
      }
      canvas.drawPath(path, linePaint);

      for (final p in points) {
        canvas.drawCircle(p, 3.6, dotPaint);
      }
    }

    // ----- label แกน X (วัน) — เว้นช่วงอัตโนมัติ
    final every = totalDays <= 10
        ? 1
        : totalDays <= 20
            ? 2
            : 3; // เดือน 30–31 วัน แสดงทุก 3 วัน
    for (int d = 1; d <= totalDays; d += every) {
      final x = chart.left + dx * (d - 1);
      final label = d.toString().padLeft(2, '0');
      tp.text = TextSpan(
        text: label,
        style: const TextStyle(fontSize: 9, color: Colors.black54),
      );
      tp.layout();
      tp.paint(canvas, Offset(x - tp.width / 2, chart.bottom + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _MonthlyMoodPainter old) =>
      old.entries != entries ||
      old.month != month ||
      old.lineColor != lineColor ||
      old.dotColor != dotColor ||
      old.gridColor != gridColor;
}

// -----------------------------------------------------------------------------
// Home
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
// Home
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
// Home (5 แท็บ เหมือนเดิม มีแท็บ mood อยู่ตรงกลาง)
// -----------------------------------------------------------------------------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int current = 0;

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final cs = Theme.of(context).colorScheme;

    final body = [
      _HomeBody(app: app, cs: cs),
      const SafeEmotionalSharingPage(),
      const MoodChartPage(), // <— กราฟ (อัปเกรดเป็นเลือกเดือน)
      const CareerGuidePage(),
      const MentorMatchingPage(),
    ][current];

    return Scaffold(
      appBar: AppBar(title: const Text('HereMe')),
      drawer: const _MainDrawer(),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        transitionBuilder: (child, anim) =>
            FadeTransition(opacity: anim, child: child),
        layoutBuilder: (currentChild, previousChildren) =>
            currentChild ?? const SizedBox.shrink(),
        child: body,
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: Colors.white,
        indicatorColor: cs.primary.withOpacity(.12),
        selectedIndex: current,
        onDestinationSelected: (i) => setState(() => current = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'home'),
          NavigationDestination(
              icon: Icon(Icons.forum_outlined), label: 'chat'),
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'mood'),
          NavigationDestination(
              icon: Icon(Icons.auto_graph_outlined), label: 'guide'),
          NavigationDestination(
              icon: Icon(Icons.medical_services_outlined), label: 'matching'),
        ],
      ),
    );
  }
}

class _HomeBody extends StatelessWidget {
  final AppState app;
  final ColorScheme cs;
  const _HomeBody({required this.app, required this.cs});

  String getAffirmation(int mood) {
    if (mood <= 2)
      return 'ไม่เป็นไรเลย วันนี้พักหายใจลึก ๆ แล้วเริ่มใหม่ได้นะ 💛';
    if (mood <= 4) return 'ก้าวเล็ก ๆ วันนี้ ก็คือความก้าวหน้าแล้ว เก่งมากนะ ✨';
    return 'อารมณ์ดีจัง! ส่งพลังบวกให้ตัวเองและคนรอบข้างต่อไป 💪';
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Affirmation ประจำวัน',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  getAffirmation(app.todaysMood),
                  style: const TextStyle(fontSize: 16),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _HomeTile(
              icon: Icons.forum_outlined,
              title: 'Safe Emotional Sharing',
              onTap: () => Navigator.pushNamed(context, '/safe'),
            ),
            _HomeTile(
              icon: Icons.auto_graph_outlined,
              title: 'Life Planner & Career Guide',
              onTap: () => Navigator.pushNamed(context, '/guide'),
            ),
            _HomeTile(
              icon: Icons.medical_services_outlined,
              title: 'Mentor Matching',
              onTap: () => Navigator.pushNamed(context, '/matching'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _SafetyBanner(color: cs.tertiaryContainer),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => Navigator.pushNamed(context, '/history'),
          icon: const Icon(Icons.history),
          label: const Text('ประวัติแชท/แยกตามหัวข้อ'),
        ),
      ],
    );
  }
}

class _HomeTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  const _HomeTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 38, color: cs.primary),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MainDrawer extends StatelessWidget {
  const _MainDrawer();
  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.white, AppState.kSoftGreen],
              ),
            ),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Text(
                'เมนู',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          _item(
            context,
            Icons.person_outline,
            'โปรไฟล์ของฉัน',
            () => Navigator.pushNamed(context, '/profile'),
          ),
          _item(
            context,
            Icons.history,
            'ประวัติแชท AI',
            () => Navigator.pushNamed(context, '/history'),
          ),
          _item(context, Icons.favorite_border, 'รายการโปรด', () {}),
          const Divider(),
          _item(context, Icons.logout, 'ออกจากระบบ', () async {
            await AuthService.signOut();
            AppState.I.threads.clear();
            await AppStorage.saveThreads([]);
            if (context.mounted) {
              Navigator.pushNamedAndRemoveUntil(
                context,
                '/login',
                (r) => false,
              );
            }
          }),
        ],
      ),
    );
  }

  ListTile _item(BuildContext c, IconData i, String t, VoidCallback onTap) =>
      ListTile(
        leading: Icon(i),
        title: Text(t),
        onTap: () => {Navigator.pop(c), onTap()},
      );
}

class _SafetyBanner extends StatelessWidget {
  final Color color;
  const _SafetyBanner({required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Text(
        'เนื้อหานี้ไม่ใช่คำแนะนำทางการแพทย์ หากมีความเสี่ยงต่อความปลอดภัย โปรดติดต่อผู้เชี่ยวชาญหรือสายด่วนใกล้คุณ',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Safe Emotional Sharing — start chat
// -----------------------------------------------------------------------------
class SafeEmotionalSharingPage extends StatelessWidget {
  const SafeEmotionalSharingPage({super.key});
  static const personas = [
    'ผู้เชี่ยวชาญ',
    'เพื่อนชาย',
    'เพื่อนสาว',
    'ผู้ปกครอง',
    'ครูอาจารย์',
    'แฟนหนุ่ม',
    'แฟนสาว',
    'พ่อ',
    'แม่',
    'ยาย',
    'ตา',
    'เพื่อน',
  ];
  static const topics = [
    'การเรียน',
    'ความรัก',
    'ครอบครัว',
    'เพื่อน',
    'สุขภาพใจ',
    'การเงิน',
  ];

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final cs = Theme.of(context).colorScheme;
    final textCtrl = TextEditingController();
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Safe Emotional Sharing')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _SectionTitle('เลือกผู้ที่อยากปรึกษา'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in personas)
                    ChoiceChip(
                      label: Text(p),
                      selected: app.selectedPersona == p,
                      selectedColor: cs.primaryContainer,
                      onSelected: (_) => app.setPersona(p),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const _SectionTitle('หัวข้อที่อยากคุย'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in topics)
                    ChoiceChip(
                      label: Text(t),
                      selected: app.selectedTopic == t,
                      selectedColor: cs.secondaryContainer,
                      onSelected: (_) => app.setTopic(t),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: textCtrl,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'อยากเริ่มต้นว่าอะไร (ไม่บังคับ)',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('เริ่มคุยกับ AI'),
                onPressed: () async {
                  final thread = await app.createThread();
                  if (thread == null) return;
                  final initial = textCtrl.text.trim();
                  if (initial.isNotEmpty) {
                    await app.addMessageToCurrent(
                      ChatMessage(role: 'user', text: initial),
                    );
                  }
                  if (context.mounted) {
                    Navigator.pushNamed(context, '/chat', arguments: thread.id);
                  }
                },
              ),
              const SizedBox(height: 8),
              const _SafetyFooter(),
            ],
          ),
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
      );
}

class _SafetyFooter extends StatelessWidget {
  const _SafetyFooter();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: const Text(
        'เนื้อหานี้ไม่ใช่คำแนะนำทางการแพทย์ หากมีความเสี่ยงต่อความปลอดภัย โปรดติดต่อผู้เชี่ยวชาญหรือสายด่วนใกล้คุณ',
        style: TextStyle(fontSize: 12),
        textAlign: TextAlign.center,
      ),
    );
  }
}

// ----------------------------
// Chat History
// ----------------------------
class ChatHistoryPage extends StatefulWidget {
  const ChatHistoryPage({super.key});
  @override
  State<ChatHistoryPage> createState() => _ChatHistoryPageState();
}

class _ChatHistoryPageState extends State<ChatHistoryPage> {
  String filterTopic = 'ทั้งหมด';

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;

    final topics =
        <String>{'ทั้งหมด', ...app.threads.map((e) => e.topic)}.toList();
    final currentValue = topics.contains(filterTopic) ? filterTopic : 'ทั้งหมด';

    final visible = app.threads
        .where((t) => currentValue == 'ทั้งหมด' || t.topic == currentValue)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('ประวัติแชท')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: DropdownButtonFormField<String>(
              value: currentValue,
              decoration: const InputDecoration(labelText: 'กรองตามหัวข้อ'),
              items: topics
                  .map(
                    (e) => DropdownMenuItem<String>(value: e, child: Text(e)),
                  )
                  .toList(),
              onChanged: (v) => setState(() => filterTopic = v ?? 'ทั้งหมด'),
            ),
          ),
          if (visible.isEmpty)
            const Expanded(
              child: Center(child: Text('ยังไม่มีประวัติแชทในหัวข้อนี้')),
            )
          else
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: visible.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final t = visible[i];
                  final last =
                      t.messages.isNotEmpty ? t.messages.last.text : '—';
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            Theme.of(context).colorScheme.primaryContainer,
                        child: const Icon(Icons.forum),
                      ),
                      title: Text(
                        '${t.topic} · ${t.persona}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        last,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        AppState.I.selectThread(t);
                        await AppState.I.loadMessagesForCurrent();
                        if (context.mounted) {
                          Navigator.pushNamed(
                            context,
                            '/chat',
                            arguments: t.id,
                          );
                        }
                      },
                    ),
                  );
                },
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pushNamed(context, '/safe'),
        icon: const Icon(Icons.add_comment),
        label: const Text('เริ่มบทสนทนาใหม่'),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Chat Page — resend on edit, stop typing, type-out char by char
// -----------------------------------------------------------------------------
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final ctrl = TextEditingController();
  final scrollCtrl = ScrollController();

  bool _isSending = false; // กำลังส่งข้อความขึ้นเครือข่าย (รอ OpenAI)
  bool _isStreaming = false; // กำลังพิมพ์ทีละตัว
  bool _stopRequested = false; // ถูกกดหยุดระหว่างพิมพ์

  ChatThread? thread;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final id = ModalRoute.of(context)?.settings.arguments as String?;
    if (id != null) {
      final found = AppState.I.threads.where((e) => e.id == id);
      thread = found.isNotEmpty
          ? found.first
          : (AppState.I.currentThread ??
              (AppState.I.threads.isNotEmpty
                  ? AppState.I.threads.first
                  : null));
    } else {
      thread = AppState.I.currentThread ??
          (AppState.I.threads.isNotEmpty ? AppState.I.threads.first : null);
    }
    if (thread != null) AppState.I.selectThread(thread!);
  }

  // ===== Helpers =====
  int _lastUserMsgIndex() {
    final t = AppState.I.currentThread;
    if (t == null || t.messages.isEmpty) return -1;
    for (int i = t.messages.length - 1; i >= 0; i--) {
      if (t.messages[i].role == 'user') return i;
    }
    return -1;
  }

  bool _isLastUserMsg(int index) => index == _lastUserMsgIndex();

  Future<void> _promptEditLast() async {
    final t = AppState.I.currentThread;
    if (t == null) return;
    final idx = _lastUserMsgIndex();
    if (idx < 0) return;

    final current = t.messages[idx].text;
    final text = TextEditingController(text: current);

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('แก้ไขข้อความล่าสุดของฉัน'),
        content: TextField(
          controller: text,
          minLines: 1,
          maxLines: 5,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'พิมพ์ข้อความใหม่…'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ยกเลิก')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('ส่งใหม่')),
        ],
      ),
    );

    if (ok == true) {
      await _resendEdited(text.text.trim());
    }
  }

  /// ลบคู่ข้อความล่าสุด (ai ตามด้วย user ถ้ามี) แล้วส่งข้อความใหม่แทน
  Future<void> _resendEdited(String newText) async {
    final t = AppState.I.currentThread;
    if (t == null || newText.isEmpty) return;

    // หยุดสตรีมถ้ากำลังพิมพ์อยู่
    _stopTyping();

    // ลบข้อความ ai ตัวสุดท้ายถ้ามี
    if (t.messages.isNotEmpty && t.messages.last.role == 'ai') {
      t.messages.removeLast();
    }
    // ลบข้อความ user ตัวสุดท้าย
    final idx = _lastUserMsgIndex();
    if (idx >= 0) {
      t.messages.removeAt(idx);
    }
    AppState.I._persistThreadsLocal();
    setState(() {});

    // เพิ่ม user ใหม่ แล้วส่งหา AI อีกรอบ
    await AppState.I
        .addMessageToCurrent(ChatMessage(role: 'user', text: newText));
    await Future.delayed(const Duration(milliseconds: 50));
    _scrollToBottom();

    await _replyForCurrentThread();
  }

  String _toneFor(String persona) {
    switch (persona) {
      case 'ผู้เชี่ยวชาญ':
        return 'มืออาชีพ สุภาพ มีโครงสร้าง คำอธิบายชัดเจน ตรงประเด็น';
      case 'เพื่อนชาย':
      case 'เพื่อนสาว':
      case 'เพื่อน':
        return 'กันเอง อบอุ่น ใช้ภาษาธรรมชาติ ให้กำลังใจ เข้าใจวัยรุ่น';
      case 'ผู้ปกครอง':
      case 'พ่อ':
      case 'แม่':
      case 'ตา':
      case 'ยาย':
        return 'นุ่มนวล ห่วงใย ชี้แนะแนวทางที่ปลอดภัย เน้นมุมมองระยะยาว';
      case 'ครูอาจารย์':
        return 'ให้คำแนะนำอย่างมีเหตุผล ยกตัวอย่างเป็นขั้นตอน สนับสนุนการเรียนรู้';
      case 'แฟนหนุ่ม':
      case 'แฟนสาว':
        return 'อ่อนโยน เคารพความรู้สึกและขอบเขต ให้ความมั่นคงทางใจ';
      default:
        return 'สุภาพ อบอุ่น เป็นมิตร';
    }
  }

  String _buildSystemPrompt(String persona, String topic) {
    final tone = _toneFor(persona);
    return '''
  คุณคือผู้ช่วยชื่อ **HereMe** สำหรับวัยรุ่น

  # Core Rules (ทำตามเสมอ)
  1) ถ้าผู้ใช้ถามชื่อ → ตอบว่า **HereMe** และบอกว่า “ฉันเปลี่ยนชื่อเรียกตามที่คุณอยากได้” (หากผู้ใช้ตั้งชื่อให้ใหม่ ให้ใช้ชื่อนั้นในการสนทนาต่อไป)
  2) ตอบได้ทุกเรื่องที่ผู้ใช้ถาม (การเรียน ความรัก ครอบครัว เพื่อน สุขภาพใจ การเงิน อาชีพ ฯลฯ) ถ้าเป็นหัวข้อเสี่ยง ให้ให้ข้อมูลทั่วไป + แนะแนวทางที่ปลอดภัย
  3) สวมบทบาท **"$persona"** ให้สมจริงต่อเนื่อง ให้ผู้ใช้ “รู้สึก” ว่าคุยกับคนที่ไว้ใจได้ ไม่ใช่ AI
  4) หากผู้ใช้พิมพ์ด้วยอารมณ์ร้อน/คำหยาบ → สะท้อนความรู้สึกอย่างอ่อนโยน ชวนใจเย็น แล้วจึงอธิบาย/แนะนำอย่างเป็นกลาง
  5) ให้คำตอบในมุมของผู้มีความรู้สูง (ลึก แต่เข้าใจง่าย) พร้อมตัวอย่าง, เช็กลิสต์, หรือขั้นตอนปฏิบัติได้ทันที
  6) ภาษา: 
    • ใช้ “ภาษาเดียวกับที่ผู้ใช้พิมพ์มาในข้อความล่าสุด” โดยอัตโนมัติ  
    • ยึดภาษาที่ผู้ใช้เริ่มหัวข้อไว้เป็นหลัก และ **เปลี่ยนภาษาเฉพาะเมื่อผู้ใช้ขอให้เปลี่ยน**
  7) รูปแบบการสื่อสาร: สะท้อนความรู้สึกก่อน → ให้คำแนะนำเป็นขั้นตอน กระชับ ใช้งานได้จริง → ถามปลายเปิดเมื่อเหมาะสม
  8) สุภาพ อบอุ่น ให้เกียรติ ปลอดภัยเสมอ หากมีสัญญาณเสี่ยง แนะนำติดต่อผู้เชี่ยวชาญ/สายด่วนอย่างอ่อนโยน

  จำไว้เสมอ: 
  - ชื่อของคุณคือ {HereMe} และคุณต้องใช้ชื่อนี้จนกว่าผู้ใช้จะบอกให้เปลี่ยน 
  - ตอบกลับเป็นภาษาเดียวกับที่ผู้ใช้พิมพ์มา เว้นแต่เขาสั่งเปลี่ยน


  # บริบทการสนทนา
  - หัวข้อที่คุย: **"$topic"**
  - บทบาทที่ผู้ใช้เลือก: **"$persona"**
  - โทนการพูดที่ต้องใช้: **$tone**
  ''';
  }

  // ===== Sending / Replying =====
  Future<void> _send() async {
    final text = ctrl.text.trim();
    if (text.isEmpty || AppState.I.currentThread == null) return;

    setState(() => _isSending = true);
    ctrl.clear();

    await AppState.I.addMessageToCurrent(ChatMessage(role: 'user', text: text));
    await Future.delayed(const Duration(milliseconds: 50));
    _scrollToBottom();

    await _replyForCurrentThread();
  }

  Future<void> _replyForCurrentThread() async {
    try {
      setState(() => _isSending = true);

      final msgs = AppState.I.currentThread!.messages
          .map((m) => {'role': m.role, 'text': m.text})
          .toList();

      final full = await _getReply(msgs);

      // สตรีมทีละตัว (และให้หยุดได้)
      await _typeOut(full);

      // บันทึกลง DB หลังสตรีมจบ (ไม่เพิ่มบับเบิลใหม่)
      if (AppState.I.isLoggedIn && !_stopRequested) {
        await DBService.addMessage(
          threadId: AppState.I.currentThread!.id,
          role: 'ai',
          text: full,
        );
      } else {
        AppState.I._persistThreadsLocal();
      }
    } catch (e) {
      await AppState.I.addMessageToCurrent(
        ChatMessage(role: 'ai', text: 'เกิดข้อผิดพลาด: $e'),
      );
    } finally {
      setState(() => _isSending = false);
      await Future.delayed(const Duration(milliseconds: 60));
      _scrollToBottom();
    }
  }

  /// พิมพ์ทีละตัวอักษรลงในบับเบิล ai ล่าสุด (สร้างใหม่ถ้ายังไม่มี)
  Future<void> _typeOut(String full) async {
    _stopRequested = false;
    _isStreaming = true;
    setState(() {});

    // เพิ่มบับเบิล ai เปล่า (ถ้าก้อนสุดท้ายไม่ใช่ ai)
    final t = AppState.I.currentThread!;
    if (t.messages.isEmpty || t.messages.last.role != 'ai') {
      t.messages.add(ChatMessage(role: 'ai', text: ''));
      setState(() {});
    }

    var buffer = '';
    for (int i = 0; i < full.length; i++) {
      if (_stopRequested) break;
      buffer += full[i];
      AppState.I.editLastMessage(buffer);
      await Future.delayed(
          const Duration(milliseconds: 24)); // ปรับความเร็วพิมพ์
      _scrollToBottom();
    }

    _isStreaming = false;
    setState(() {});
  }

  void _stopTyping() {
    _stopRequested = true;
    _isStreaming = false;
    setState(() {});
  }

  Future<String> _getReply(List<Map<String, String>> messages) async {
    if (kOpenAIKey.isEmpty) {
      final last = messages.isNotEmpty ? (messages.last['text'] ?? '') : '';
      return _simulateBotReply(last);
    }

    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final sys = _buildSystemPrompt(
      AppState.I.currentThread!.persona,
      AppState.I.currentThread!.topic,
    );

    final openAiMessages = <Map<String, String>>[
      {'role': 'system', 'content': sys},
      for (final m in messages)
        {
          'role': (m['role'] == 'ai') ? 'assistant' : 'user',
          'content': m['text'] ?? ''
        },
    ];

    final res = await http
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $kOpenAIKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': kOpenAIModel,
            'messages': openAiMessages,
            'temperature': 0.7,
            'max_tokens': 512,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (res.statusCode != 200) {
      throw Exception('OpenAI ${res.statusCode}: ${res.body}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final content =
        (data['choices']?[0]?['message']?['content'] ?? '').toString().trim();
    return content.isEmpty
        ? 'ขอโทษนะ ตอนนี้ฉันตอบไม่ได้ ลองพิมพ์อีกครั้งได้ไหม'
        : content;
  }

  String _simulateBotReply(String userText) {
    final lower = userText.toLowerCase();
    if (lower.contains('เศร้า') || lower.contains('เสียใจ')) {
      return 'เราเห็นว่าคุณรู้สึกเศร้าอยู่ — อยากเล่าเหตุการณ์ล่าสุดที่ทำให้รู้สึกแบบนี้ไหม';
    }
    if (lower.contains('เครียด') || lower.contains('กังวล')) {
      return 'ลองแบ่งเรื่องที่ทำให้เครียดเป็นส่วนย่อย ๆ แล้วจัดลำดับความสำคัญทีละข้อ เราช่วยคิดด้วยกันได้นะ';
    }
    if (lower.contains('สอบ') || lower.contains('เรียน')) {
      return 'เรื่องเรียนกดดันมาก ลอง Pomodoro: โฟกัส 25 นาที พัก 5 นาที แล้วค่อย ๆ ไปนะ';
    }
    return 'ขอบคุณที่เล่าให้ฟังนะ เราฟังอยู่ — อยากให้ช่วยแบบไหนต่อดี: ให้กำลังใจ, วิเคราะห์, หรือช่วยวางแผน?';
  }

  Future<void> _scrollToBottom() async {
    await Future.delayed(const Duration(milliseconds: 50));
    if (!mounted || !scrollCtrl.hasClients) return;
    scrollCtrl.animateTo(
      scrollCtrl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _showSafetySheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('ความเป็นส่วนตัวและความปลอดภัย',
                style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text(
                'เนื้อหานี้ไม่ใช่คำแนะนำทางการแพทย์ หากมีความเสี่ยง โปรดติดต่อผู้เชี่ยวชาญ/สายด่วนใกล้คุณ'),
          ],
        ),
      ),
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = AppState.I.currentThread;

    return Scaffold(
      appBar: AppBar(
        title: Text(
            t == null ? 'คุยกับ AI' : 'คุยกับ AI (${t.persona} · ${t.topic})'),
        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt),
            tooltip: 'ประวัติแชท',
            onPressed: () => Navigator.pushNamed(context, '/history'),
          ),
          IconButton(
            onPressed: _showSafetySheet,
            icon: const Icon(Icons.privacy_tip_outlined),
            tooltip: 'ความปลอดภัย',
          ),
          IconButton(
            tooltip: 'แก้ไขข้อความล่าสุดของฉัน',
            icon: const Icon(Icons.edit_note_outlined),
            onPressed: _promptEditLast,
          ),
        ],
      ),
      body: Column(
        children: [
          if (t == null)
            const Expanded(
              child: Center(
                  child: Text(
                      'ยังไม่มีบทสนทนา เริ่มที่ “Safe Emotional Sharing”')),
            )
          else
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                padding: const EdgeInsets.all(16),
                itemCount: t.messages.length,
                itemBuilder: (context, i) {
                  final m = t.messages[i];
                  final isUser = m.role == 'user';
                  final canEdit = isUser && _isLastUserMsg(i);

                  final bubble = Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.all(12),
                    constraints: const BoxConstraints(maxWidth: 360),
                    decoration: BoxDecoration(
                      color: isUser
                          ? cs.primaryContainer
                          : const Color(0xFFF6F9F7),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(18),
                        topRight: const Radius.circular(18),
                        bottomLeft: Radius.circular(isUser ? 18 : 6),
                        bottomRight: Radius.circular(isUser ? 6 : 18),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(m.text),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _fmtTime(m.time),
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.black45),
                            ),
                            if (canEdit) ...[
                              const SizedBox(width: 6),
                              GestureDetector(
                                onTap: _promptEditLast,
                                child: const Icon(Icons.edit,
                                    size: 16, color: Colors.black45),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  );

                  return Align(
                    alignment:
                        isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: GestureDetector(
                      onLongPress: canEdit ? _promptEditLast : null,
                      child: bubble,
                    ),
                  );
                },
              ),
            ),
          if (_isStreaming || _isSending)
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 6),
              child: Row(
                children: const [
                  SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('กำลังพิมพ์…'),
                ],
              ),
            ),
          ChatInput(
            ctrl: ctrl,
            isSending: _isSending,
            isStreaming: _isStreaming,
            onSend: _send,
            onStop: _stopTyping,
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Chat Input — แสดงปุ่ม Stop ระหว่างสตรีม
// -----------------------------------------------------------------------------
class ChatInput extends StatelessWidget {
  final TextEditingController ctrl;
  final Future<void> Function() onSend;
  final VoidCallback? onStop;
  final bool isSending;
  final bool isStreaming;

  const ChatInput({
    super.key,
    required this.ctrl,
    required this.onSend,
    this.onStop,
    this.isSending = false,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: TextField(
                    controller: ctrl,
                    minLines: 1,
                    maxLines: 4,
                    decoration:
                        const InputDecoration(hintText: 'พิมพ์ข้อความ…'),
                    onSubmitted: (_) => onSend(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
                width: 48,
                child: isStreaming
                    ? FilledButton(
                        onPressed: onStop,
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.redAccent),
                        child: const Icon(Icons.stop_rounded),
                      )
                    : FilledButton(
                        onPressed: isSending ? null : onSend,
                        child: isSending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send_rounded),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Mentor Profile Page (รูป/ชื่อ/ตำแหน่ง/สเปเชียลตี้/เบอร์/อีเมล)
// -----------------------------------------------------------------------------
class MentorProfilePage extends StatelessWidget {
  final String name;
  final String role;
  final String specialty;
  final String phone;
  final String email;
  final String avatarUrl;

  const MentorProfilePage({
    super.key,
    required this.name,
    required this.role,
    required this.specialty,
    required this.phone,
    required this.email,
    required this.avatarUrl,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('โปรไฟล์ผู้เชี่ยวชาญ')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                colors: [cs.primary, cs.secondary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 38,
                  backgroundImage: NetworkImage(avatarUrl),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: DefaultTextStyle(
                    style: const TextStyle(color: Colors.white),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text('$role • $specialty'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.phone),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(phone,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.email_outlined),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(email,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('เกี่ยวกับ',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Text(
                    'ผู้เชี่ยวชาญด้านสุขภาพใจที่มุ่งเน้นการดูแลวัยรุ่น ให้คำปรึกษาเชิงลึกด้วยวิธีการที่ปลอดภัย อบอุ่น และเป็นระบบ',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _SafetyFooter(),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Profile Page
// -----------------------------------------------------------------------------
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('โปรไฟล์ของฉัน')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: cs.primaryContainer,
                    child: const Icon(Icons.person, size: 32),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'HereMe User',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ข้อมูลพื้นฐาน',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  _row('อายุ', app.basicAge ?? '—'),
                  _row('เพศ', app.basicGender ?? '—'),
                  _row('อาชีพ', app.basicOccupation ?? '—'),
                  _row('สถานะ', app.basicStatus ?? '—'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'สรุปวันนี้',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  _row('อารมณ์ (1–6)', '${app.todaysMood}'),
                  _row(
                    'อาการ',
                    app.todaysSymptoms.isEmpty
                        ? '—'
                        : app.todaysSymptoms.join(', '),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(width: 120, child: Text(k)),
            Expanded(child: Text(v, textAlign: TextAlign.right)),
          ],
        ),
      );
}

// -----------------------------------------------------------------------------
// Career Guide (placeholder)
// -----------------------------------------------------------------------------
class CareerGuidePage extends StatelessWidget {
  const CareerGuidePage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Life Planner & Career Guide')),
      body: const Center(
        child: Text('หน้าคู่มือ/ไกด์ วางแผนการเรียนและอาชีพ (ตัวอย่าง)'),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Mentor Matching (styled list)
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
// Mentor Matching (tap to open profile)
// -----------------------------------------------------------------------------
class MentorMatchingPage extends StatelessWidget {
  const MentorMatchingPage({super.key});

  @override
  Widget build(BuildContext context) {
    // ข้อมูลตัวอย่าง (เพิ่มเบอร์/อีเมล/รูป)
    final experts = const [
      {
        'role': 'จิตแพทย์',
        'name': 'นพ. นวมินทร์ อินทรี',
        'specialty': 'จิตเวชวัยรุ่น',
        'phone': '02-123-4567',
        'email': 'navamin@example.com',
        'avatar':
            'https://images.unsplash.com/photo-1550831107-1553da8c8464?w=256&q=80'
      },
      {
        'role': 'นักจิตบำบัด',
        'name': 'ฟ้าใส อุทัยทิพย์',
        'specialty': 'CBT, วิตกกังวล',
        'phone': '081-234-5678',
        'email': 'fahsai@example.com',
        'avatar':
            'https://images.unsplash.com/photo-1520813792240-56fc4a3765a7?w=256&q=80'
      },
      {
        'role': 'นักจิตบำบัด',
        'name': 'อริญา นัยน์ตา',
        'specialty': 'ความสัมพันธ์, ครอบครัว',
        'phone': '089-888-9999',
        'email': 'arinya@example.com',
        'avatar':
            'https://images.unsplash.com/photo-1544005313-94ddf0286df2?w=256&q=80'
      },
      {
        'role': 'นักแนะแนวการเรียน/การทำงาน',
        'name': 'หญิงระดา นรารัตน์',
        'specialty': 'แนะแนวอาชีพ, นักเรียนม.ปลาย',
        'phone': '02-555-0000',
        'email': 'yingrada@example.com',
        'avatar':
            'https://images.unsplash.com/photo-1527980965255-d3b416303d12?w=256&q=80'
      },
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Human Mentor Matching')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: experts.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final e = experts[i];
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundImage: NetworkImage(e['avatar']!),
              ),
              title: Text(
                e['name']!,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text('${e['role']} • ${e['specialty']}'),
              trailing: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.star, size: 18),
                  Icon(Icons.star, size: 18),
                  Icon(Icons.star, size: 18),
                  Icon(Icons.star_half, size: 18),
                ],
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MentorProfilePage(
                      name: e['name']!,
                      role: e['role']!,
                      specialty: e['specialty']!,
                      phone: e['phone']!,
                      email: e['email']!,
                      avatarUrl: e['avatar']!,
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
