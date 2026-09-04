class WSMessage {
  final int op;
  final dynamic d;
  final String? t;
  final int? s;

  WSMessage({required this.op, this.d, this.t, this.s});

  factory WSMessage.fromJson(Map<String, dynamic> json) => WSMessage(
    op: json['op'],
    d: json['d'],
    t: json['t'],
    s: json['s'],
  );

  Map<String, dynamic> toJson() => {
    'op': op,
    if (d != null) 'd': d,
    if (t != null) 't': t,
    if (s != null) 's': s,
  };
}

class OpCodes {
  static const dispatch = 0;
  static const heartbeat = 1;
  static const identify = 2;
  static const setActiveConv = 3; // 上报当前正在看的会话（空=退出）
  static const resume = 6;
  static const reconnect = 7;
  static const hello = 10;
  static const heartbeatAck = 11;
  static const stream = 14; // 流式输出快照(plugin→server→正在观看的 user)
  static const mpSubscribe = 15; // 小程序云数据订阅 d:{appid, colls:[...]}
  static const mpUnsubscribe = 16; // 小程序云数据退订 d:{}
}
