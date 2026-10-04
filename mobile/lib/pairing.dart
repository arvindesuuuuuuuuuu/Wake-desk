import 'dart:convert';
import 'dart:io';

String? validateConnectionField(String key, String value) {
  if (value.isEmpty) return 'Required';
  if (value.length > (key == 'token' ? 1024 : 256)) return 'Value is too long';
  if (key == 'url') {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      return 'Enter http(s)://PC-IP:8787';
    }
  }
  if (key == 'token' && (value.length < 32 || RegExp(r'\s').hasMatch(value))) {
    return 'Use an access token of at least 32 characters';
  }
  if (key == 'mac' &&
      !RegExp(r'^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$').hasMatch(value)) {
    return 'Use AA:BB:CC:DD:EE:FF';
  }
  if (key == 'broadcast' &&
      InternetAddress.tryParse(value)?.type != InternetAddressType.IPv4) {
    return 'Enter an IPv4 broadcast address';
  }
  return null;
}

Map<String, String> parsePairingCode(String raw) {
  // Reject unrelated codes before any credentials reach the connection form.
  try {
    if (raw.length > 4096) throw const FormatException();
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        data['type'] != 'pc-control' ||
        data['version'] != 1) {
      throw const FormatException();
    }
    final result = <String, String>{};
    for (final key in ['name', 'url', 'token', 'mac', 'broadcast']) {
      final value = data[key];
      if (value is! String || validateConnectionField(key, value) != null) {
        throw const FormatException();
      }
      result[key] = value;
    }
    result['url'] = result['url']!.replaceFirst(RegExp(r'/$'), '');
    return result;
  } catch (_) {
    throw const FormatException('Not a valid WakeDesk connection code');
  }
}
