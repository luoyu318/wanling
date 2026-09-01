// packages/wanling_core/lib/providers/mini_programs_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/providers/auth_provider.dart';

/// 用户可见小程序(published 全量 + 自己的私有)。
/// autoDispose:无 watcher 即释放,重进列表页自动 refetch(新发布/换版本可见);
/// 列表页 skipLoadingOnReload/Refresh 保旧数据,静默刷新不闪 loading。
/// 失败返空列表(列表页展示空态,不炸 UI)。
final miniProgramsProvider =
    FutureProvider.autoDispose<List<MiniProgramInfo>>((ref) async {
  try {
    return await ref.watch(apiProvider).getMiniPrograms();
  } catch (_) {
    return const <MiniProgramInfo>[];
  }
});