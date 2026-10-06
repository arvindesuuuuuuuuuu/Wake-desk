import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pc_control/dashboard_view.dart';
import 'package:pc_control/main.dart';

void main() {
  ThemeData previewTheme(Brightness brightness) {
    final theme = appTheme(brightness);
    final button = theme.filledButtonTheme.style!;
    return theme.copyWith(
      appBarTheme: theme.appBarTheme.copyWith(
        titleTextStyle: theme.appBarTheme.titleTextStyle!.copyWith(
          fontFamily: 'Roboto',
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: button.copyWith(
          textStyle: WidgetStatePropertyAll(
            button.textStyle!.resolve({})!.copyWith(fontFamily: 'Roboto'),
          ),
        ),
      ),
    );
  }

  final settings = <String, dynamic>{
    'name': 'Office PC',
    'url': 'http://192.168.1.50:8787',
    'token': 'example-token-for-visual-preview-only',
    'mac': 'AA:BB:CC:DD:EE:FF',
    'broadcast': '192.168.1.255',
  };
  Future<void> preview(WidgetTester tester, String name) async {
    if (!Platform.isWindows) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final folder = Directory('../dist/mobile-previews');
      await folder.create(recursive: true);
      await File('${folder.path}/$name.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  setUpAll(() async {
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    if (Platform.isWindows) {
      final fonts = '${Platform.environment['WINDIR']}/Fonts';
      final loader = FontLoader('Roboto');
      for (final filename in ['segoeui.ttf', 'segoeuib.ttf']) {
        final file = File('$fonts/$filename');
        if (file.existsSync()) {
          loader.addFont(
            file.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        }
      }
      await loader.load();
    }
  });
  for (final brightness in Brightness.values) {
    testWidgets('Online dashboard ${brightness.name} layout and action', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? selected;
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('preview'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: previewTheme(brightness),
            home: DashboardView(
              settings: settings,
              status: const {
                'name': 'Office PC',
                'addresses': ['192.168.1.50'],
                'uptime_seconds': 93840,
              },
              connection: 'Online',
              ready: true,
              busy: false,
              checking: false,
              onRefresh: () async {},
              onConfigure: () async {},
              onWake: () async {},
              onCommand: (action) async {
                selected = action;
              },
              lastChecked: DateTime(2026, 10, 3, 10, 30),
              activity: 'Lock requested',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await preview(tester, 'dashboard-${brightness.name}');
      await tester.tap(find.text('Lock'));
      expect(selected, 'lock');
      await tester.tap(find.text('Connection details'));
      await tester.pumpAndSettle();
      expect(find.text('AA:BB:CC:DD:EE:FF'), findsOneWidget);
    });
  }
  testWidgets('Narrow dashboard accommodates large text and long PC name', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: previewTheme(Brightness.light),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: DashboardView(
              settings: {...settings, 'name': 'Workstation-Engineering-Office'},
              devices: [
                {...settings, 'name': 'Workstation-Engineering-Office'},
                {...settings, 'name': 'Home PC'},
              ],
              onSelectDevice: (_) async {},
              onAddDevice: () async {},
              status: null,
              connection: 'Authentication failed',
              ready: true,
              busy: false,
              checking: false,
              onRefresh: () async {},
              onConfigure: () async {},
              onWake: () async {},
              onCommand: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Shutdown'), 200);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Control PC menu fits narrow screens and follows saved selection',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final devices = [
        {...settings, 'name': 'Office workstation with a long device name'},
        {...settings, 'name': 'Home workstation with a long device name'},
        for (var i = 0; i < 10; i++) {...settings, 'name': 'PC $i'},
      ];
      var selected = 0;
      int? requested;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.6)),
                child: DashboardView(
                  devices: devices,
                  selectedDevice: selected,
                  settings: devices[selected],
                  status: null,
                  connection: 'Offline',
                  ready: true,
                  busy: false,
                  checking: false,
                  onSelectDevice: (value) async => requested = value,
                  onRefresh: () async {},
                  onConfigure: () async {},
                  onWake: () async {},
                  onCommand: (_) async {},
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      final menu = tester.getRect(find.byType(Scrollable).last);
      expect(menu.left, greaterThanOrEqualTo(0));
      expect(menu.right, lessThanOrEqualTo(320));
      expect(menu.height, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(devices[1]['name'] as String).last);
      await tester.pumpAndSettle();
      expect(requested, 1);
      // Until the parent saves the switch, the displayed PC must stay accurate.
      expect(
        tester
            .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
            .value,
        0,
      );
      update(() => selected = 1);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
            .value,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Connection form preview and token visibility', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('preview'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: previewTheme(Brightness.light),
          home: SettingsPage(initial: settings),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await preview(tester, 'connection');
    await tester.tap(find.byTooltip('Show token'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hide token'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
