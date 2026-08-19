import 'package:wanling_core/models/conversation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SessionMeta.fromJson 解析 mode/model_id/provider_id/git_branch', () {
    final meta = SessionMeta.fromJson({
      'mode': 'build',
      'model_id': 'glm-5.2',
      'provider_id': 'zhipuai',
      'git_branch': 'main',
    });
    expect(meta.mode, 'build');
    expect(meta.modelId, 'glm-5.2');
    expect(meta.providerId, 'zhipuai');
    expect(meta.gitBranch, 'main');
  });

  test('git_branch 缺省/空串时为 null', () {
    final meta = SessionMeta.fromJson({
      'mode': 'build',
      'model_id': 'glm-5.2',
      'provider_id': 'zhipuai',
    });
    expect(meta.gitBranch, isNull);

    final metaEmpty = SessionMeta.fromJson({
      'mode': 'build',
      'model_id': 'glm-5.2',
      'provider_id': 'zhipuai',
      'git_branch': '',
    });
    expect(metaEmpty.gitBranch, isNull);
  });
}
