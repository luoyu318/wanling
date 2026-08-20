enum SessionDiffStatus { added, modified, deleted }

class SessionDiffFile {
  final String? file;
  final String? patch;
  final int additions;
  final int deletions;
  final String? status;

  /// 二进制文件防护标记(plugin session.diff 上报:patch 为空,UI 显示「二进制文件」)。
  final bool binary;

  /// patch 截断防护标记(plugin 侧超 256KB/帧预算时截断,UI 显示「已截断」提示)。
  final bool truncated;

  const SessionDiffFile({
    this.file,
    this.patch,
    required this.additions,
    required this.deletions,
    this.status,
    this.binary = false,
    this.truncated = false,
  });

  factory SessionDiffFile.fromJson(Map<String, dynamic> json) => SessionDiffFile(
        file: json['file'] as String?,
        patch: json['patch'] as String?,
        additions: (json['additions'] as num).toInt(),
        deletions: (json['deletions'] as num).toInt(),
        status: json['status'] as String?,
        binary: (json['binary'] as bool?) ?? false,
        truncated: (json['truncated'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'file': file,
        'patch': patch,
        'additions': additions,
        'deletions': deletions,
        if (status != null) 'status': status,
        // omitempty:仅 true 时序列化,对齐 plugin 上报口径
        if (binary) 'binary': true,
        if (truncated) 'truncated': true,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionDiffFile &&
          runtimeType == other.runtimeType &&
          file == other.file &&
          patch == other.patch &&
          additions == other.additions &&
          deletions == other.deletions &&
          status == other.status &&
          binary == other.binary &&
          truncated == other.truncated;

  @override
  int get hashCode =>
      Object.hash(file, patch, additions, deletions, status, binary, truncated);
}
