import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pc_control/pairing.dart';

void main() {
  final code = {
    'type': 'pc-control',
    'version': 1,
    'name': 'Office PC',
    'url': 'http://192.168.1.50:8787/',
    'token': 'x' * 44,
    'mac': 'AA:BB:CC:DD:EE:FF',
    'broadcast': '192.168.1.255',
  };
  test('imports all connection fields and normalizes URL', () {
    final result = parsePairingCode(jsonEncode(code));
    expect(result['url'], 'http://192.168.1.50:8787');
    expect(result['token'], code['token']);
    expect(result['mac'], code['mac']);
    expect(result['broadcast'], code['broadcast']);
    expect(result['name'], code['name']);
  });
  test('rejects unrelated, incomplete, oversized and malformed codes', () {
    for (final raw in [
      'https://example.com',
      '{}',
      'x' * 4097,
      jsonEncode({...code, 'version': 2}),
      jsonEncode({...code, 'token': 'short'}),
      jsonEncode({...code, 'url': 'http://user:pass@host'}),
      jsonEncode({...code, 'url': 'http://host/?secret=x'}),
      jsonEncode({...code, 'mac': 'invalid'}),
      jsonEncode({...code, 'broadcast': '::1'}),
      jsonEncode({...code, 'name': 123}),
    ]) {
      expect(() => parsePairingCode(raw), throwsFormatException);
    }
  });
}
