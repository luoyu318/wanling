import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:app/services/mini_program_manager.dart';

/// 全局小程序保活管理器(应用生命周期单例)。
final miniProgramManagerProvider =
    ChangeNotifierProvider<MiniProgramManager>((ref) => MiniProgramManager());
