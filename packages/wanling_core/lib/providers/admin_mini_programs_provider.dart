// packages/wanling_core/lib/providers/admin_mini_programs_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/admin_mini_program_info.dart';
import 'package:wanling_core/providers/auth_provider.dart';

/// admin 审核全量列表(autoDispose:进页拉取,操作后 invalidate)。
/// 失败向上抛:审核页需区分 403(无权限提示)与网络错误,不静默吞。
final adminMiniProgramsProvider =
    FutureProvider.autoDispose<List<AdminMiniProgramInfo>>(
        (ref) => ref.watch(apiProvider).getAdminMiniPrograms());
