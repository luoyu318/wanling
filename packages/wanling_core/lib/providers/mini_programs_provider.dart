// packages/wanling_core/lib/providers/mini_programs_provider.dart
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/services/api_response.dart';

/// 用户可见小程序(published 全量 + 自己的)。
/// autoDispose:无 watcher 即释放,重进列表页自动 refetch(新发布/换版本可见);
/// 列表页 skipLoadingOnReload/Refresh 保旧数据,静默刷新不闪 loading。
///
/// 身份感知:watch 当前账号 id,切换账号(登录/切号)后 provider 自动失效重建——
/// 否则 token 空窗期(logout 黑名单旧 token → 新登录前)的请求 401,空结果
/// 被底栏 mp 槽常驻 watcher 缓存,登录后列表恒「暂无小程序」需手动刷新。
///
/// 失败处理分流:
///   - 鉴权失败(401/403)上抛:不伪装成空数据,列表页错误态呈现
///   - 网络类错误返空列表:维持既有容错(底栏 mp 槽 alive 收缩语义不变)
final miniProgramsProvider =
    FutureProvider.autoDispose<List<MiniProgramInfo>>((ref) async {
  ref.watch(authProvider.select((s) => s.user?.id));
  try {
    return await ref.watch(apiProvider).getMiniPrograms();
  } catch (e) {
    // dio 拦截器把 envelope 错误包装成 DioException(error: ApiException),先解包
    final err = e is DioException ? e.error : e;
    if (err is ApiException &&
        (err.statusCode == 401 || err.statusCode == 403)) {
      rethrow;
    }
    return const <MiniProgramInfo>[];
  }
});
