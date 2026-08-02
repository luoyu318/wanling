/// OC 命令条目(对应 server model.SlashCommandInfo)。
/// source 字段: "command"(OC 命令) | "skill"(OC 技能),APP 据此分组渲染。
class SlashCommand {
  final String name;
  final String template;
  final String description;
  final String source;

  const SlashCommand({
    required this.name,
    required this.template,
    required this.description,
    required this.source,
  });

  factory SlashCommand.fromJson(Map<String, dynamic> json) {
    return SlashCommand(
      name: json['name'] as String? ?? '',
      template: json['template'] as String? ?? '',
      description: json['description'] as String? ?? '',
      source: json['source'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'template': template,
        'description': description,
        'source': source,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SlashCommand &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          template == other.template &&
          description == other.description &&
          source == other.source;

  @override
  int get hashCode => Object.hash(name, template, description, source);
}
