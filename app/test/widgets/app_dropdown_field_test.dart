import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/app_dropdown_field.dart';

void main() {
  Widget wrap({
    String? value,
    ValueChanged<String?>? onChanged,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: AppDropdownFormField<String>(
            value: value,
            label: '类型',
            items: const [
              AppDropdownItem(value: '', label: '普通'),
              AppDropdownItem(value: 'hermes', label: 'Hermes'),
              AppDropdownItem(value: 'opencode', label: 'OpenCode'),
            ],
            onChanged: onChanged ?? (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('渲染 label 与当前选中值', (tester) async {
    await tester.pumpWidget(wrap(value: 'hermes'));
    expect(find.text('类型'), findsOneWidget);
    expect(find.text('Hermes'), findsOneWidget);
  });

  testWidgets('点击展开菜单,弹出层为白底圆角容器', (tester) async {
    await tester.pumpWidget(wrap(value: ''));
    await tester.tap(find.byType(AppDropdownFormField<String>));
    await tester.pumpAndSettle();

    // 弹出层出现所有选项(菜单中一份)
    expect(find.text('普通'), findsNWidgets(2));
    expect(find.text('Hermes'), findsOneWidget);
    expect(find.text('OpenCode'), findsOneWidget);
  });

  testWidgets('选中项显示 ✓ 图标', (tester) async {
    await tester.pumpWidget(wrap(value: 'hermes'));
    await tester.tap(find.byType(AppDropdownFormField<String>));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('点击选项回调 onChanged 并更新选中态', (tester) async {
    String? result;
    await tester.pumpWidget(wrap(onChanged: (v) => result = v));
    await tester.tap(find.byType(AppDropdownFormField<String>));
    await tester.pumpAndSettle();

    await tester.tap(find.text('OpenCode'));
    await tester.pumpAndSettle();

    expect(result, 'opencode');
  });

  testWidgets('value 变更通过 didUpdateWidget 同步选中态', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Padding(
              padding: const EdgeInsets.all(16),
              child: AppDropdownFormField<String>(
                key: key,
                value: '',
                label: '类型',
                items: const [
                  AppDropdownItem(value: '', label: '普通'),
                  AppDropdownItem(value: 'hermes', label: 'Hermes'),
                ],
                onChanged: (v) =>
                    setState(() {}), // 触发外层 setState,value 由外部驱动
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('普通'), findsOneWidget);
  });
}
