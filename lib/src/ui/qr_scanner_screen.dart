import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Reads a pairing link out of the QR code that `opencode pair` prints in the
/// terminal.
///
/// Scanned content is untrusted input from the camera, so this screen does no
/// interpreting: it hands the raw string to [onScanned], and the caller decides
/// whether it looks like a pairing link.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key, required this.onScanned});

  /// Called once, with the raw payload of the first detected code.
  final ValueChanged<String> onScanned;

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  bool _handled = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      _handled = true;
      _controller.stop();
      widget.onScanned(value);
      return;
    }
  }

  /// Retrying after a permission failure. `start` is fire-and-forget in this
  /// version; failures surface through the scanner's own error builder.
  void _retry() {
    setState(() => _error = null);
    _controller.start();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _CameraError(
              message: switch (error.errorCode) {
                MobileScannerErrorCode.permissionDenied =>
                  'Camera permission was denied',
                MobileScannerErrorCode.unsupported =>
                  'This device has no usable camera',
                _ => error.errorDetails?.message ??
                    'The camera could not be opened',
              },
              onRetry: _retry,
            ),
          ),
          Center(
            child: _ScanReticle(size: MediaQuery.sizeOf(context).width * 0.68),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      IconButton(
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black45,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Point at the QR code in your terminal',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ),
                      ValueListenableBuilder(
                        valueListenable: _controller,
                        builder: (context, state, child) => IconButton(
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black45,
                            foregroundColor: Colors.white,
                          ),
                          tooltip: 'Torch',
                          onPressed: state.torchState == TorchState.unavailable
                              ? null
                              : _controller.toggleTorch,
                          icon: Icon(
                            state.torchState == TorchState.on
                                ? Icons.flashlight_on
                                : Icons.flashlight_off,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                  child: Text(
                    'Run `opencode pair` on the machine running the server and '
                    'scan the code it prints.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// Corner brackets marking the scan area, so aiming does not need guessing.
class _ScanReticle extends StatelessWidget {
  const _ScanReticle({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _ReticlePainter()),
      ),
    );
  }
}

class _ReticlePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    const length = 34.0;
    void corner(Offset origin, double dx, double dy) {
      canvas.drawLine(origin, origin.translate(dx, 0), paint);
      canvas.drawLine(origin, origin.translate(0, dy), paint);
    }

    corner(Offset.zero, length, 0);
    corner(Offset.zero, 0, length);
    corner(Offset(size.width, 0), -length, 0);
    corner(Offset(size.width, 0), 0, length);
    corner(Offset(0, size.height), length, 0);
    corner(Offset(0, size.height), 0, -length);
    corner(Offset(size.width, size.height), -length, 0);
    corner(Offset(size.width, size.height), 0, -length);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
class _CameraError extends StatelessWidget {
  const _CameraError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, color: Colors.white54),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
