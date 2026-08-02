class FileEntry {
  final String name;
  final String type;
  final int size;
  final bool binary;

  const FileEntry({
    required this.name,
    required this.type,
    required this.size,
    this.binary = false,
  });

  bool get isDir => type == 'dir';
  bool get isFile => type == 'file';

  factory FileEntry.fromJson(Map<String, dynamic> json) => FileEntry(
        name: json['name'] as String,
        type: json['type'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        binary: (json['binary'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        'size': size,
        if (binary) 'binary': true,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FileEntry &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          type == other.type;

  @override
  int get hashCode => Object.hash(name, type);
}
