import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 关于页：静态信息（应用名 + 版本号 + 简介）。
/// 版本号从原生层读取（pubspec.yaml → build.gradle → PackageInfo），
/// 避免硬编码导致升级后忘了同步。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _version = 'v${info.version}+${info.buildNumber}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/images/logo.png', width: 72, height: 72),
            const SizedBox(height: 12),
            const Text('万灵', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text(_version, style: const TextStyle(color: Color(0xFF999999), fontSize: 13)),
            const SizedBox(height: 16),
            const Text('唤灵 · 即应', style: TextStyle(color: Color(0xFF999999), fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
