import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/widgets/highlight_widget.dart';

/// [foucsNode] 可选：不传时内部创建并自管理生命周期
class SettingsItemWidget extends StatefulWidget {
  final AppFocusNode? foucsNode;
  final Map<dynamic, String> items;
  final dynamic value;
  final String title;
  final bool autofocus;
  final Function(dynamic) onChanged;
  const SettingsItemWidget({
    this.foucsNode,
    required this.items,
    required this.value,
    required this.title,
    required this.onChanged,
    this.autofocus = false,
    super.key,
  });

  @override
  State<SettingsItemWidget> createState() => _SettingsItemWidgetState();
}

class _SettingsItemWidgetState extends State<SettingsItemWidget>
    with ManagedAppFocusNode<SettingsItemWidget> {
  AppFocusNode get _node => resolveFocusNode(widget.foucsNode);

  @override
  Widget build(BuildContext context) {
    return HighlightWidget(
      focusNode: _node,
      autofocus: widget.autofocus,
      borderRadius: AppStyle.radius16,
      onLeftKey: () {
        if (widget.items.isEmpty) return KeyEventResult.handled;
        if (widget.items.keys.first == widget.value) {
          widget.onChanged(widget.items.keys.last);
        } else {
          widget.onChanged(widget.items.keys
              .elementAt(widget.items.keys.toList().indexOf(widget.value) - 1));
        }
        return KeyEventResult.handled;
      },
      onRightKey: () {
        if (widget.items.isEmpty) return KeyEventResult.handled;
        if (widget.items.keys.last == widget.value) {
          widget.onChanged(widget.items.keys.first);
        } else {
          widget.onChanged(widget.items.keys
              .elementAt(widget.items.keys.toList().indexOf(widget.value) + 1));
        }
        return KeyEventResult.handled;
      },
      onTap: () {
        showSettingsDialog();
      },
      child: Obx(
        () => Padding(
          padding: AppStyle.edgeInsetsA24,
          child: Row(
            children: [
              Text(
                widget.title,
                style: _node.isFoucsed.value
                    ? AppStyle.textStyleBlack
                    : AppStyle.textStyleWhite,
              ),
              const Spacer(),
              if (_node.isFoucsed.value && widget.items.isNotEmpty)
                Icon(
                  Icons.chevron_left,
                  size: 40.w,
                  color: _node.isFoucsed.value ? Colors.black : Colors.white,
                ),
              AppStyle.hGap12,
              ConstrainedBox(
                constraints: BoxConstraints(minWidth: 120.w),
                child: Text(
                  widget.items[widget.value] ?? '',
                  style: _node.isFoucsed.value
                      ? AppStyle.textStyleBlack
                      : AppStyle.textStyleWhite,
                  textAlign: _node.isFoucsed.value
                      ? TextAlign.center
                      : TextAlign.right,
                ),
              ),
              AppStyle.hGap12,
              if (_node.isFoucsed.value && widget.items.isNotEmpty)
                Icon(
                  Icons.chevron_right,
                  size: 40.w,
                  color: _node.isFoucsed.value ? Colors.black : Colors.white,
                ),
            ],
          ),
        ),
      ),
    );
  }

  void showSettingsDialog() {
    Get.dialog(
      AlertDialog(
        backgroundColor: Get.theme.cardColor,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.title, style: AppStyle.titleStyleWhite),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: widget.items.keys.map((e) {
            return ListTile(
              title: Text(widget.items[e] ?? '', style: AppStyle.textStyleWhite),
              contentPadding: AppStyle.edgeInsetsH20,
              autofocus: e == widget.value,
              shape: RoundedRectangleBorder(
                borderRadius: AppStyle.radius16,
              ),
              focusColor: Colors.white54,
              onTap: () {
                widget.onChanged(e);
                Get.back();
              },
            );
          }).toList(),
        ),
      ),
    );
  }
}
