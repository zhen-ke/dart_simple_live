import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/widgets/highlight_widget.dart';

/// [focusNode] 可选：不传时内部创建并自管理生命周期
class HighlightButton extends StatefulWidget {
  final String text;
  final IconData? iconData;
  final Widget? icon;
  final AppFocusNode? focusNode;
  final Function()? onTap;
  final bool autofocus;
  final bool selected;
  const HighlightButton({
    this.iconData,
    required this.text,
    this.icon,
    this.onTap,
    this.focusNode,
    this.autofocus = false,
    this.selected = false,
    super.key,
  });

  @override
  State<HighlightButton> createState() => _HighlightButtonState();
}

class _HighlightButtonState extends State<HighlightButton>
    with ManagedAppFocusNode<HighlightButton> {
  AppFocusNode get _node => resolveFocusNode(widget.focusNode);

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => HighlightWidget(
        focusNode: _node,
        borderRadius: AppStyle.radius32,
        color: Colors.white10,
        onTap: widget.onTap,
        autofocus: widget.autofocus,
        selected: widget.selected,
        child: Container(
          height: 64.w,
          //width: 64.w,
          padding: AppStyle.edgeInsetsH24,
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius32,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              buildIcon(),
              Text(
                widget.text,
                style: TextStyle(
                  fontSize: 28.w,
                  color: (_node.isFoucsed.value || widget.selected)
                      ? Colors.black
                      : Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildIcon() {
    if (widget.icon != null || widget.iconData != null) {
      return Padding(
        padding: AppStyle.edgeInsetsR12,
        child: widget.icon ??
            Icon(
              widget.iconData,
              size: 40.w,
              color: (_node.isFoucsed.value || widget.selected)
                  ? Colors.black
                  : Colors.white,
            ),
      );
    }
    return const SizedBox();
  }
}
