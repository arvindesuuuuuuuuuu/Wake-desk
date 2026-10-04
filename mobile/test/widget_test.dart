import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pc_control/main.dart';

void main() {
  testWidgets('Unconfigured phone shows disabled power controls and setup', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const PcControlApp());
    await tester.pumpAndSettle();
    expect(find.text('Not connected'), findsOneWidget);
    final power = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Power On'),
    );
    expect(power.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Connection settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Save'),
      200,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .last,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Settings reject unsafe URL and invalid network fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SettingsPage(
          initial: {
            'name': 'Office',
            'url': 'http://user:pass@host/path',
            'token': 'short',
            'mac': 'invalid',
            'broadcast': 'not-an-ip',
          },
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Save'),
      200,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .last,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter http(s)://PC-IP:8787'), findsOneWidget);
    expect(
      find.text('Use an access token of at least 32 characters'),
      findsOneWidget,
    );
    expect(find.text('Use AA:BB:CC:DD:EE:FF'), findsOneWidget);
    expect(find.text('Enter an IPv4 broadcast address'), findsOneWidget);
  });
}
