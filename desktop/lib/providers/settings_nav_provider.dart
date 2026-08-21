// desktop/lib/providers/settings_nav_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 设置页左侧导航与右侧内容区的联动状态。
///
/// 双向同步:
/// - 点击左侧导航项 → 写 [settingsScrollToProvider] 脉冲(索引),
///   右侧 SettingsPage 监听后 animateTo 对应分区(消费后清零);
/// - 右侧滚动 → SettingsPage 按分区 offset 反推当前分区,写
///   [settingsActiveSectionProvider],左侧导航高亮跟随。
/// 两个 provider 分离避免「点击→滚动→回写高亮」循环触发。
final settingsActiveSectionProvider = StateProvider<int>((ref) => 0);

/// 滚动定位脉冲:null = 无待处理,非 null = 待滚动到的分区索引。
final settingsScrollToProvider = StateProvider<int?>((ref) => null);
