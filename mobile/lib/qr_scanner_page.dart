import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'pairing.dart';

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  bool completed = false;
  String? error;

  void detected(BarcodeCapture capture) {
    if (completed) return;
    for (final barcode in capture.barcodes) {
      if (barcode.format != BarcodeFormat.qrCode || barcode.rawValue == null) {
        continue;
      }
      try {
        final connection = parsePairingCode(barcode.rawValue!);
        completed = true;
        Navigator.pop(context, connection);
        return;
      } on FormatException {
        if (error == null) setState(() => error = 'Invalid WakeDesk QR code');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan PC QR code')),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          onDetect: detected,
          errorBuilder: (context, exception) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.no_photography_outlined, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'Camera unavailable. Check camera permission in Android settings.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Enter manually'),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (error != null)
          Positioned(
            left: 24,
            right: 24,
            bottom: 32,
            child: SafeArea(
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(error!),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
