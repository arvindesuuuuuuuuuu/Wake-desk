import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'dashboard_view.dart';
import 'pairing.dart';
import 'qr_scanner_page.dart';
import 'unlock_identity.dart';

void main() => runApp(const PcControlApp());

class PcControlApp extends StatelessWidget {
  const PcControlApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'WakeDesk',
    debugShowCheckedModeBanner: false,
    theme: appTheme(Brightness.light),
    darkTheme: appTheme(Brightness.dark),
    home: const Dashboard(),
  );
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> with WidgetsBindingObserver {
  final storage = const FlutterSecureStorage();
  List<Map<String, dynamic>> devices = [];
  int selectedDevice = 0;
  Map<String, dynamic> get settings =>
      devices.isEmpty ? {} : devices[selectedDevice];
  Map<String, dynamic>? status;
  Timer? timer;
  bool checking = false, busy = false, ready = false;
  String connection = 'Not connected';
  int revision = 0;
  DateTime? lastChecked;
  String? activity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  Future<void> load() async {
    try {
      final raw = await storage.read(key: 'devices');
      if (raw != null) {
        final saved = jsonDecode(raw) as Map<String, dynamic>;
        devices = (saved['devices'] as List)
            .map((device) => Map<String, dynamic>.from(device as Map))
            .toList();
        final selected = saved['selected'] as int? ?? 0;
        selectedDevice = selected >= 0 && selected < devices.length
            ? selected
            : 0;
      } else {
        final legacy = await storage.read(key: 'connection');
        if (legacy != null) {
          final device = jsonDecode(legacy) as Map<String, dynamic>;
          if (device.isNotEmpty) devices = [device];
        }
      }
    } catch (_) {
      connection = 'Could not load saved settings';
    }
    if (!mounted) return;
    setState(() => ready = true);
    startPolling();
  }

  void startPolling() {
    timer?.cancel();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && ready) {
      startPolling();
    } else {
      timer?.cancel();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<Map<String, dynamic>> request(
    String path, {
    String? command,
    Map<String, dynamic>? data,
  }) async {
    final target = settings;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final uri = Uri.parse('${target['url']}$path');
      final req = await client
          .openUrl(command == null && data == null ? 'GET' : 'POST', uri)
          .timeout(const Duration(seconds: 5));
      req.headers.set('Authorization', 'Bearer ${target['token']}');
      if (command != null || data != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(command != null ? {'command': command} : data));
      }
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = await utf8.decoder
          .bind(res)
          .join()
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 401) {
        throw const HttpException('Authentication failed');
      }
      if (res.statusCode != 200) {
        final detail = body.trim();
        throw HttpException(
          detail.isEmpty ? 'Agent error (${res.statusCode})' : detail,
        );
      }
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> refresh() async {
    if (!ready || checking || settings['url'] == null) return;
    setState(() => checking = true);
    final version = revision;
    try {
      final result = await request('/v1/status');
      if (mounted && version == revision) {
        setState(() {
          status = result;
          connection = 'Online';
          lastChecked = DateTime.now();
        });
      }
    } catch (e) {
      if (mounted && version == revision) {
        setState(() {
          status = null;
          connection = e is HttpException ? e.message : 'Offline';
          lastChecked = DateTime.now();
        });
      }
    } finally {
      if (mounted && version == revision) {
        setState(() => checking = false);
      }
    }
  }

  void notice(String message) {
    if (mounted) {
      setState(() => activity = message);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> command(String action) async {
    if (busy || settings.isEmpty) return;
    setState(() => busy = true);
    if (action != 'lock') {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${label(action)} ${settings['name']}?'),
          content: Text(
            action == 'sleep'
                ? 'The PC will disconnect until it wakes.'
                : 'Save any open work before continuing.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(label(action)),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) {
        if (mounted) setState(() => busy = false);
        return;
      }
    }
    try {
      await request('/v1/commands', command: action);
      notice('${label(action)} requested');
    } catch (_) {
      notice('No confirmation received. Check the PC before retrying.');
    } finally {
      if (mounted) setState(() => busy = false);
      refresh();
    }
  }

  Future<void> wake() async {
    if (busy || settings.isEmpty) return;
    setState(() => busy = true);
    RawDatagramSocket? socket;
    try {
      final mac = (settings['mac'] as String? ?? '').replaceAll(
        RegExp('[:-]'),
        '',
      );
      if (!RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(mac)) {
        throw const FormatException();
      }
      final bytes = List.generate(
        6,
        (i) => int.parse(mac.substring(i * 2, i * 2 + 2), radix: 16),
      );
      final packet = <int>[
        ...List.filled(6, 255),
        for (var i = 0; i < 16; i++) ...bytes,
      ];
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final sent = socket.send(
        packet,
        InternetAddress(settings['broadcast'] as String),
        9,
      );
      if (sent != packet.length) throw const SocketException('Send failed');
      notice('Wake packet sent');
    } catch (_) {
      notice('Could not send wake packet. Check MAC and broadcast address.');
    } finally {
      socket?.close();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> enrollPhoneUnlock() async {
    if (busy || settings.isEmpty) return;
    final controller = TextEditingController();
    final username = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enroll phone sign-in'),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Ubuntu username'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Request enrollment'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (username == null ||
        !RegExp(r'^[a-z_][a-z0-9_-]{0,31}$').hasMatch(username)) {
      if (username != null) notice('Enter a valid Ubuntu username.');
      return;
    }
    setState(() => busy = true);
    UnlockIdentity? identity;
    try {
      identity = await UnlockIdentityStore(storage)
          .loadOrCreate(settings['url'] as String);
      await request(
        '/v1/unlock/enrollments',
        data: {
          'id': identity.deviceId,
          'name': 'WakeDesk Android phone',
          'user': username,
          'public_key': identity.publicKey,
        },
      );
      notice(
        'Enrollment requested. Approve this phone in the Ubuntu WakeDesk panel within 5 minutes.',
      );
    } catch (error) {
      notice('Could not request phone enrollment: ${errorText(error)}');
    } finally {
      identity?.keyPair.destroy();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> approvePhoneUnlock() async {
    if (busy || settings.isEmpty) return;
    setState(() => busy = true);
    UnlockIdentity? identity;
    try {
      final authenticated = await LocalAuthentication().authenticate(
        localizedReason:
            'Approve sign-in to ${settings['name'] ?? 'your Ubuntu PC'}',
        biometricOnly: false,
      );
      if (!authenticated) return;
      identity = await UnlockIdentityStore(storage)
          .loadOrCreate(settings['url'] as String);
      final challenge = await request(
        '/v1/unlock/challenges',
        data: {'device_id': identity.deviceId},
      );
      final signature = await Ed25519().sign(
        utf8.encode(challenge['message'] as String),
        keyPair: identity.keyPair,
      );
      await request(
        '/v1/unlock/approvals',
        data: {
          'challenge_id': challenge['challenge_id'],
          'signature': base64.encode(signature.bytes).replaceAll('=', ''),
        },
      );
      notice(
        'Sign-in approved for ${challenge['user']}. At Ubuntu, submit the login form within 30 seconds.',
      );
    } catch (error) {
      notice('Could not approve sign-in: ${errorText(error)}');
    } finally {
      identity?.keyPair.destroy();
      if (mounted) setState(() => busy = false);
    }
  }

  String label(String action) => switch (action) {
    'shutdown' => 'Shutdown',
    'restart' => 'Restart',
    'sleep' => 'Sleep',
    _ => 'Lock',
  };

  String errorText(Object error) {
    final text = error.toString().replaceFirst(
      RegExp(r'^(HttpException|Exception):\s*'),
      '',
    );
    return text.length > 180 ? '${text.substring(0, 177)}…' : text;
  }

  Future<void> saveDevices(
    List<Map<String, dynamic>> updated,
    int selected,
  ) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await storage.write(
        key: 'devices',
        value: jsonEncode({'devices': updated, 'selected': selected}),
      );
      if (!mounted) return;
      setState(() {
        devices = updated;
        selectedDevice = selected;
        status = null;
        lastChecked = null;
        activity = null;
        connection = 'Connecting';
        checking = false;
        revision++;
      });
    } catch (_) {
      notice('Could not save settings');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (mounted) refresh();
  }

  Future<void> selectDevice(int selected) async {
    if (busy || selected == selectedDevice) return;
    await saveDevices(devices, selected);
  }

  Future<void> configure({bool add = false}) async {
    if (busy) return;
    final updated = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          initial: add ? {} : settings,
          adding: add || devices.isEmpty,
        ),
      ),
    );
    if (updated == null || !mounted) return;
    final next = [...devices];
    final selected = add || next.isEmpty ? next.length : selectedDevice;
    if (selected == next.length) {
      next.add(updated);
    } else {
      next[selected] = updated;
    }
    await saveDevices(next, selected);
  }

  @override
  Widget build(BuildContext context) {
    return DashboardView(
      settings: settings,
      devices: devices,
      selectedDevice: selectedDevice,
      onSelectDevice: selectDevice,
      onAddDevice: () => configure(add: true),
      status: status,
      connection: connection,
      ready: ready,
      busy: busy,
      checking: checking,
      onRefresh: refresh,
      onConfigure: () => configure(),
      onWake: wake,
      onCommand: command,
      onEnrollUnlock: enrollPhoneUnlock,
      onApproveUnlock: approvePhoneUnlock,
      lastChecked: lastChecked,
      activity: activity,
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.initial, this.adding = false});
  final bool adding;
  final Map<String, dynamic> initial;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final form = GlobalKey<FormState>();
  bool showToken = false;
  late final Map<String, TextEditingController> fields;
  bool scanned = false;

  Future<void> scan() async {
    final result = await Navigator.push<Map<String, String>>(
      context,
      MaterialPageRoute(builder: (_) => const QrScannerPage()),
    );
    if (result == null || !mounted) return;
    setState(() {
      for (final entry in result.entries) {
        fields[entry.key]!.text = entry.value;
      }
      showToken = false;
      scanned = true;
    });
  }

  @override
  void initState() {
    super.initState();
    fields = {
      for (final key in ['name', 'url', 'token', 'mac', 'broadcast'])
        key: TextEditingController(
          text:
              widget.initial[key] as String? ??
              (key == 'broadcast' ? '255.255.255.255' : ''),
        ),
    };
  }

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  String? validate(String key, String value) {
    return validateConnectionField(key, value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.adding ? 'Add PC' : 'Connection')),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Form(
            key: form,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                OutlinedButton.icon(
                  onPressed: scan,
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: const Text('Scan PC QR code'),
                ),
                const SizedBox(height: 16),
                for (final entry in {
                  'name': 'PC nickname',
                  'url': 'Agent URL',
                  'token': 'Access token',
                  'mac': 'Ethernet MAC address',
                  'broadcast': 'Broadcast address',
                }.entries) ...[
                  if (entry.key == 'name' || entry.key == 'mac')
                    Padding(
                      padding: const EdgeInsets.only(bottom: 18, top: 8),
                      child: Text(
                        entry.key == 'name' ? 'PC agent' : 'Wake-on-LAN',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: TextFormField(
                      controller: fields[entry.key],
                      decoration: InputDecoration(
                        labelText: entry.value,
                        prefixIcon: Icon(switch (entry.key) {
                          'name' => Icons.desktop_windows_outlined,
                          'url' => Icons.link_rounded,
                          'token' => Icons.key_rounded,
                          'mac' => Icons.lan_outlined,
                          _ => Icons.wifi_tethering_rounded,
                        }),
                        suffixIcon: entry.key == 'token'
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: showToken
                                        ? 'Hide token'
                                        : 'Show token',
                                    icon: Icon(
                                      showToken
                                          ? Icons.visibility_off_outlined
                                          : Icons.visibility_outlined,
                                    ),
                                    onPressed: () =>
                                        setState(() => showToken = !showToken),
                                  ),
                                  IconButton(
                                    tooltip: 'Paste token',
                                    icon: const Icon(
                                      Icons.content_paste_rounded,
                                    ),
                                    onPressed: () async {
                                      final data = await Clipboard.getData(
                                        Clipboard.kTextPlain,
                                      );
                                      if (mounted && data?.text != null) {
                                        fields['token']!.text = data!.text!
                                            .trim();
                                      }
                                    },
                                  ),
                                ],
                              )
                            : null,
                      ),
                      obscureText: entry.key == 'token' && !showToken,
                      keyboardType: entry.key == 'url'
                          ? TextInputType.url
                          : TextInputType.text,
                      textInputAction: entry.key == 'broadcast'
                          ? TextInputAction.done
                          : TextInputAction.next,
                      autocorrect: false,
                      enableSuggestions: false,
                      validator: (value) =>
                          validate(entry.key, value?.trim() ?? ''),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () {
                    if (!form.currentState!.validate()) return;
                    final result = {
                      for (final entry in fields.entries)
                        entry.key: entry.value.text.trim(),
                    };
                    result['url'] = result['url']!.replaceFirst(
                      RegExp(r'/$'),
                      '',
                    );
                    Navigator.pop(context, result);
                  },
                  icon: const Icon(Icons.check),
                  label: Text(scanned ? 'Connect' : 'Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
