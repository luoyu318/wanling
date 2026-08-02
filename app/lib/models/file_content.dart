class FileContent {
  final String path;
  final String type;
  final String mime;
  final int size;
  final String? content;
  final String? contentBase64;
  final bool truncated;

  const FileContent({
    required this.path,
    required this.type,
    required this.mime,
    required this.size,
    this.content,
    this.contentBase64,
    this.truncated = false,
  });

  bool get isText => type == 'text';
  bool get isImage => type == 'image';
  bool get isBinary => type == 'binary';

  factory FileContent.fromJson(Map<String, dynamic> json) => FileContent(
        path: json['path'] as String,
        type: json['type'] as String,
        mime: json['mime'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        content: json['content'] as String?,
        contentBase64: json['content_base64'] as String?,
        truncated: (json['truncated'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'type': type,
        'mime': mime,
        'size': size,
        if (content != null) 'content': content,
        if (contentBase64 != null) 'content_base64': contentBase64,
        if (truncated) 'truncated': true,
      };
}
