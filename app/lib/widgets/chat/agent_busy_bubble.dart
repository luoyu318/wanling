import 'package:flutter/material.dart';
import 'message_bubble.dart' show BubbleWithTail;
import 'three_body_indicator.dart';

class AgentBusyBubble extends StatelessWidget {
  const AgentBusyBubble({super.key});

  @override
  Widget build(BuildContext context) {
    return const Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: BubbleWithTail(
          isMe: false,
          child: SizedBox(
            width: 28,
            height: 16,
            child: ThreeBodyIndicator(),
          ),
        ),
      ),
    );
  }
}
