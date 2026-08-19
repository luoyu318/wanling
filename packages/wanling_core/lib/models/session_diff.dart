enum SessionDiffStatus { added, modified, deleted }

class SessionDiffFile {
  final String? file;
  final String? patch;
  final int additions;
  final int deletions;
  final String? status;

  const SessionDiffFile({
    this.file,
    this.patch,
    required this.additions,
    required this.deletions,
    this.status,
  });

  factory SessionDiffFile.fromJson(Map<String, dynamic> json) => SessionDiffFile(
        file: json['file'] as String?,
        patch: json['patch'] as String?,
        additions: (json['additions'] as num).toInt(),
        deletions: (json['deletions'] as num).toInt(),
        status: json['status'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'file': file,
        'patch': patch,
        'additions': additions,
        'deletions': deletions,
        if (status != null) 'status': status,
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
          status == other.status;

  @override
  int get hashCode =>
      Object.hash(file, patch, additions, deletions, status);
}
