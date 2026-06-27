import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../utils/snackbar.dart';

/// 从扫码内容中提取配对 ticket_id。
/// 识别 `WLPAIR:` 前缀格式，其他内容返回 null。
/// 抽成顶层函数便于单元测试（相机层无法在 widget test 里跑）。
String? extractPairTicketId(String raw) {
  const prefix = 'WLPAIR:';
  if (!raw.startsWith(prefix)) return null;
  final id = raw.substring(prefix.length);
  if (id.isEmpty) return null;
  return id;
}

class ScanPairPage extends StatefulWidget {
  const ScanPairPage({super.key});

  @override
  State<ScanPairPage> createState() => _ScanPairPageState();
}

class _ScanPairPageState extends State<ScanPairPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _navigated = false; // 防止连续多次识别跳多次

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_navigated) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final raw = barcodes.first.rawValue;
    if (raw == null) return;

    final ticketId = extractPairTicketId(raw);
    if (ticketId == null) {
      // 非配对码：toast 提示，继续扫
      showAppSnackBar(context, '非万灵配对码');
      return;
    }

    _navigated = true;
    context.push('/pair/select-agent?ticket=$ticketId');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码连接 hermes')),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          // 底部提示
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.all(16),
              child: const Text(
                '扫描 hermes 终端显示的二维码',
                style: TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
