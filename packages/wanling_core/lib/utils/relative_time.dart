String formatRelativeTime(DateTime t, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final local = t.toLocal();
  final diff = ref.difference(local);

  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  if (diff.inDays < 7) return '${diff.inDays}天前';
  return '${local.month}月${local.day}日';
}
