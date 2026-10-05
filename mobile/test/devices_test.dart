import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pc_control/dashboard_view.dart';
import 'package:pc_control/main.dart';

Map<String, dynamic> device(String name) => {
  'name': name,
  'url': 'http://${name.toLowerCase()}:8787',
  'token': List.filled(32, name).join(),
  'mac': 'AA:BB:CC:DD:EE:FF',
  'broadcast': '192.168.1.255',
};

class AgentRequests extends HttpOverrides {
  final requests = <AgentRequest>[];
  Completer<HttpClientResponse>? pending;

  @override
  HttpClient createHttpClient(SecurityContext? context) => AgentClient(this);
}

class AgentClient implements HttpClient {
  AgentClient(this.owner);
  final AgentRequests owner;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = AgentRequest(method, url, owner.pending);
    owner.pending = null;
    owner.requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class AgentHeaders implements HttpHeaders {
  final values = <String, Object>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class AgentRequest implements HttpClientRequest {
  AgentRequest(this.method, this.uri, this.pending);
  final String method;
  final Uri uri;
  final Completer<HttpClientResponse>? pending;
  String body = '';

  @override
  final headers = AgentHeaders();

  @override
  void write(Object? object) => body += object.toString();

  @override
  Future<HttpClientResponse> close() async =>
      pending == null ? AgentResponse(uri.host) : await pending!.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class AgentResponse extends Stream<List<int>> implements HttpClientResponse {
  AgentResponse(this.name);
  final String name;

  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(jsonEncode({
    'name': name,
    'addresses': ['192.168.1.50'],
    'uptime_seconds': 60,
  }))).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AgentRequests agents;
  const storage = FlutterSecureStorage();

  setUp(() {
    agents = AgentRequests();
    HttpOverrides.global = agents;
  });
  tearDown(() => HttpOverrides.global = null);

  testWidgets('Existing connection is preserved when adding and editing PCs', (
    tester,
  ) async {
    final first = device('Office');
    final second = device('Home');
    FlutterSecureStorage.setMockInitialValues({
      'connection': jsonEncode(first),
    });
    await tester.pumpWidget(const PcControlApp());
    await tester.pumpAndSettle();
    expect(tester.widget<DashboardView>(find.byType(DashboardView)).devices,
        [first]);
    await tester.tap(find.text('Add PC'));
    await tester.pumpAndSettle();
    expect(tester.widget<SettingsPage>(find.byType(SettingsPage)).initial,
        isEmpty);
    // Return the same payload as saving the shared connection form or QR flow.
    tester.state<NavigatorState>(find.byType(Navigator).first).pop(second);
    await tester.pumpAndSettle();
    var saved = jsonDecode((await storage.read(key: 'devices'))!);
    expect(saved['devices'], [first, second]);
    expect(saved['selected'], 1);
    await tester.tap(find.byTooltip('Connection settings'));
    await tester.pumpAndSettle();
    expect(tester.widget<SettingsPage>(find.byType(SettingsPage)).initial,
        second);
    final edited = {...second, 'name': 'Home desktop'};
    tester.state<NavigatorState>(find.byType(Navigator).first).pop(edited);
    await tester.pumpAndSettle();
    saved = jsonDecode((await storage.read(key: 'devices'))!);
    expect(saved['devices'], [first, edited]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Switching ignores stale status and sends commands to chosen PC', (
    tester,
  ) async {
    final first = device('Office');
    final second = device('Home');
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    FlutterSecureStorage.setMockInitialValues({
      'devices': jsonEncode({'devices': [first, second], 'selected': 0}),
    });
    final delayed = Completer<HttpClientResponse>();
    agents.pending = delayed;
    await tester.pumpWidget(const PcControlApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home').last);
    await tester.pumpAndSettle();
    delayed.complete(AgentResponse('old-office-status'));
    await tester.pumpAndSettle();
    final view = tester.widget<DashboardView>(find.byType(DashboardView));
    expect(view.settings, second);
    expect(view.status?['name'], 'home');
    expect(view.checking, isFalse);
    await tester.ensureVisible(find.text('Lock'));
    await tester.tap(find.text('Lock'));
    await tester.pumpAndSettle();
    final command = agents.requests.singleWhere((r) => r.method == 'POST');
    expect(command.uri.toString(), '${second['url']}/v1/commands');
    expect(command.headers.values['Authorization'], 'Bearer ${second['token']}');
    expect(jsonDecode(command.body), {'command': 'lock'});
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const PcControlApp());
    await tester.pumpAndSettle();
    expect(tester.widget<DashboardView>(find.byType(DashboardView)).settings,
        second);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Device selector is disabled during power confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    FlutterSecureStorage.setMockInitialValues({
      'devices': jsonEncode({
        'devices': [device('Office'), device('Home')],
        'selected': 0,
      }),
    });
    await tester.pumpWidget(const PcControlApp());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Shutdown'));
    await tester.tap(find.text('Shutdown'));
    await tester.pumpAndSettle();
    expect(find.text('Shutdown Office?'), findsOneWidget);
    final view = tester.widget<DashboardView>(find.byType(DashboardView));
    expect(view.busy, isTrue);
    expect(tester.widget<DropdownButtonFormField<int>>(
        find.byType(DropdownButtonFormField<int>)).onChanged, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(agents.requests.where((r) => r.method == 'POST'), isEmpty);
    expect(tester.widget<DashboardView>(find.byType(DashboardView)).busy,
        isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
