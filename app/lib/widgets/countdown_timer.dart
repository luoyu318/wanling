import 'dart:async';

import 'package:flutter/material.dart';

/// 根据 expiresAt 自算倒计时，每秒刷新。显示「⏱ M:SS」格式。
class CountdownTimer extends StatefulWidget {
  final DateTime expiresAt;

  const CountdownTimer({super.key, required this.expiresAt});

  @override
  State<CountdownTimer> createState() => _CountdownTimerState();
}

class _CountdownTimerState extends State<CountdownTimer> {
  Timer? _timer;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _updateRemaining();
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _updateRemaining(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _updateRemaining() {
    final now = DateTime.now().toUtc();
    final exp = widget.expiresAt.toUtc();
    final r = exp.difference(now);
    setState(() {
      _remaining = r.isNegative ? Duration.zero : r;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_remaining == Duration.zero) return const SizedBox.shrink();
    final m = _remaining.inMinutes;
    final s = _remaining.inSeconds % 60;
    return Text(
      '⏱ $m:${s.toString().padLeft(2, '0')}',
      style: const TextStyle(
        color: Color(0xFF999999),
        fontSize: 11,
      ),
    );
  }
}
