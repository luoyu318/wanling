// resolveLocalFile 纯函数回归测试 —— 钉住小程序 WebView 包根映射语义。
// 回归锁: entry 位于子目录(pages/index.html)时 URL 与包根一一对应,不再双倍拼接。
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:app/pages/mini_program_page.dart';

void main() {
  const root = '/tmp/wanling-miniprogram-test/pkg';

  test('扁平 entry:/index.html 映射到包根', () {
    expect(resolveLocalFile(root, '/index.html'), p.join(root, 'index.html'));
  });

  test('子目录 entry:/pages/index.html 映射到包内子目录(不再双倍拼接)', () {
    expect(
      resolveLocalFile(root, '/pages/index.html'),
      p.join(root, 'pages', 'index.html'),
    );
  });

  test('子目录页相对资源 ./app.js → /pages/app.js', () {
    expect(
      resolveLocalFile(root, '/pages/app.js'),
      p.join(root, 'pages', 'app.js'),
    );
  });

  test('子目录页相对资源 ../shared.css → /shared.css', () {
    expect(resolveLocalFile(root, '/shared.css'), p.join(root, 'shared.css'));
  });

  test('/ 根路径解析回包根目录(由调用方按目录走 404)', () {
    expect(resolveLocalFile(root, '/'), root);
  });

  test('段级归一:包根内 ../ 回退与 ./ 折叠仍放行', () {
    expect(
      resolveLocalFile(root, '/pages/../shared.css'),
      p.join(root, 'shared.css'),
    );
    expect(resolveLocalFile(root, '/a/./b.js'), p.join(root, 'a', 'b.js'));
  });

  test('../ 越出包根返回 null(zip-slip 第二层防护)', () {
    expect(resolveLocalFile(root, '/../secret'), isNull);
    expect(resolveLocalFile(root, '/../../etc/passwd'), isNull);
    expect(resolveLocalFile(root, '/pages/../..'), isNull);
  });

  // —— 嵌入模式构造面:路由模式默认无回调;嵌入构造双回调齐备 ——
  test('路由模式默认构造 isEmbedded=false(回调未接)', () {
    const page = MiniProgramPage(appid: 'showcase');
    expect(page.isEmbedded, isFalse);
  });

  test('embedded 构造 isEmbedded=true(最小化/关闭回调接入)', () {
    final page = MiniProgramPage.embedded(
      appid: 'showcase',
      onMinimize: () {},
      onClose: () {},
    );
    expect(page.isEmbedded, isTrue);
  });
}
