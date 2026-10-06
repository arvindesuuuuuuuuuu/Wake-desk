import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class UnlockIdentity {
  UnlockIdentity(this.deviceId, this.publicKey, this.keyPair);
  final String deviceId;
  final String publicKey;
  final SimpleKeyPair keyPair;
}

class UnlockIdentityStore {
  UnlockIdentityStore(this.storage);
  final FlutterSecureStorage storage;
  final algorithm = Ed25519();

  String _unpadded(List<int> bytes) => base64.encode(bytes).replaceAll('=', '');

  Future<UnlockIdentity> loadOrCreate(String agentUrl) async {
    final suffix = base64Url.encode(utf8.encode(agentUrl)).replaceAll('=', '');
    final storageKey = 'unlock_ed25519_$suffix';
    final saved = await storage.read(key: storageKey);
    late final List<int> seed;
    if (saved == null) {
      final generated = await algorithm.newKeyPair();
      // cryptography may return a view backed by the key pair. Copy it before
      // destroying the temporary key so the seed remains usable below.
      seed = List<int>.from(await generated.extractPrivateKeyBytes());
      generated.destroy();
      await storage.write(key: storageKey, value: _unpadded(seed));
    } else {
      seed = base64.decode(base64.normalize(saved));
    }
    final keyPair = await algorithm.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    final digest = await Sha256().hash(publicKey.bytes);
    return UnlockIdentity(
      base64Url.encode(digest.bytes.take(18).toList()).replaceAll('=', ''),
      _unpadded(publicKey.bytes),
      keyPair,
    );
  }
}
