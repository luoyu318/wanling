import 'dart:convert';
import '../utils/mono_font.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

/// 文本文件预览页。
/// 通过 GET /api/files/:id 下载字节流，UTF-8 解码后用 SelectableText 渲染。
/// 大文件 (>512KB) 截断前 512KB 并在末尾提示。
class TextPreviewPage extends StatefulWidget {
  final String fileId;
  final String filename;
  final String baseUrl;
  final String token;

  const TextPreviewPage({
    super.key,
    required this.fileId,
    required this.filename,
    required this.baseUrl,
    required this.token,
  });

  @override
  State<TextPreviewPage> createState() => _TextPreviewPageState();
}

class _TextPreviewPageState extends State<TextPreviewPage> {
  String? _text;
  String? _error;
  bool _loading = true;
  bool _truncated = false;

  static const int _maxBytes = 512 * 1024; // 512KB

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: widget.baseUrl,
        headers: {'Authorization': 'Bearer ${widget.token}'},
        responseType: ResponseType.bytes,
      ));
      final res = await dio.get<List<int>>('/api/files/${widget.fileId}');
      final bytes = res.data ?? [];
      if (bytes.length > _maxBytes) {
        final decoded = utf8.decode(bytes.sublist(0, _maxBytes), allowMalformed: true);
        if (mounted) {
          setState(() {
            _text = decoded;
            _truncated = true;
            _loading = false;
          });
        }
      } else {
        final decoded = utf8.decode(bytes, allowMalformed: true);
        if (mounted) {
          setState(() {
            _text = decoded;
            _loading = false;
          });
        }
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _error = '加载失败: ${e.message ?? e.toString()}';
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '加载失败: $e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: const TextStyle(color: Colors.red)),
        ),
      );
    } else {
      body = SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              _text ?? '',
              style: const TextStyle(
                fontSize: 15,
                height: 1.5,
                fontFamily: 'monospace', fontFamilyFallback: kMonoFontFallback,
              ),
            ),
            if (_truncated)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text(
                  '--- 文件较大，仅预览前 512KB ---',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF999999),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.filename)),
      body: body,
    );
  }
}
