/// 消息类型，对应 content JSONB 里的 msg_type 字段。
/// 集中定义便于 IDE 补全、避免拼写错误。
enum MsgType {
  text,
  markdown,
  image,
  file,
  mixed,
  unknown;
}

extension MsgTypeX on MsgType {
  String get value => switch (this) {
        MsgType.text => 'text',
        MsgType.markdown => 'markdown',
        MsgType.image => 'image',
        MsgType.file => 'file',
        MsgType.mixed => 'mixed',
        MsgType.unknown => 'unknown',
      };

  static MsgType fromString(String? raw) {
    switch (raw) {
      case 'text':
        return MsgType.text;
      case 'markdown':
        return MsgType.markdown;
      case 'image':
        return MsgType.image;
      case 'file':
        return MsgType.file;
      case 'mixed':
        return MsgType.mixed;
      default:
        return MsgType.unknown;
    }
  }
}
