import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 原生下拉选择表单项。
///
/// 触发器保留原生 [DropdownButtonFormField]（[InputDecoration] 与上方输入框一致，
/// 避免自定义 trigger 与表单割裂）；仅定制弹出层：
/// - 白底圆角菜单 + 上限高度
/// - 选中项右侧打 ✓(品牌绿)
class AppDropdownFormField<T> extends StatefulWidget {
  final T? value;
  final String label;
  final List<AppDropdownItem<T>> items;
  final ValueChanged<T?>? onChanged;

  const AppDropdownFormField({
    super.key,
    required this.value,
    required this.label,
    required this.items,
    this.onChanged,
  });

  @override
  State<AppDropdownFormField<T>> createState() =>
      _AppDropdownFormFieldState<T>();
}

/// 下拉选择项。
class AppDropdownItem<T> {
  final T value;
  final String label;

  const AppDropdownItem({required this.value, required this.label});
}

class _AppDropdownFormFieldState<T> extends State<AppDropdownFormField<T>> {
  late T? _selected = widget.value;

  @override
  void didUpdateWidget(covariant AppDropdownFormField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) _selected = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      initialValue: _selected,
      decoration: InputDecoration(labelText: widget.label),
      dropdownColor: Colors.white,
      borderRadius: BorderRadius.circular(8),
      menuMaxHeight: 300,
      // 按钮闭合态：只显示 label 文本,与输入框风格一致
      selectedItemBuilder: (context) => [
        for (final item in widget.items)
          Text(
            item.label,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
      ],
      items: [
        for (final item in widget.items)
          DropdownMenuItem<T>(
            value: item.value,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    item.label,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF111111),
                    ),
                  ),
                ),
                if (item.value == _selected)
                  const Icon(
                    Icons.check,
                    size: 18,
                    color: AppColors.accentGreen,
                  ),
              ],
            ),
          ),
      ],
      onChanged: (v) {
        setState(() => _selected = v);
        widget.onChanged?.call(v);
      },
    );
  }
}
