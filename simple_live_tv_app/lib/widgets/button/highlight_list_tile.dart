import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/widgets/highlight_widget.dart';

/// [focusNode] 可选：不传时内部创建并自管理生命周期
class HighlightListTile extends StatefulWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final AppFocusNode? focusNode;
  final Function()? onTap;
  final bool autofocus;

  const HighlightListTile({
    this.subtitle,
    required this.title,
    this.leading,
    this.onTap,
    this.focusNode,
    this.autofocus = false,
    this.trailing,
    super.key,
  });

  @override
  State<HighlightListTile> createState() => _HighlightListTileState();
}

class _HighlightListTileState extends State<HighlightListTile>
    with ManagedAppFocusNode<HighlightListTile> {
  AppFocusNode get _node => resolveFocusNode(widget.focusNode);

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => IconTheme(
        data: IconThemeData(
          color: _node.isFoucsed.value ? Colors.black : Colors.white,
        ),
        child: HighlightWidget(
          onTap: widget.onTap,
          autofocus: widget.autofocus,
          focusNode: _node,
          borderRadius: AppStyle.radius16,
          child: Padding(
            padding: AppStyle.edgeInsetsA24,
            child: Row(
              children: [
                if (widget.leading != null) widget.leading!,
                if (widget.leading != null) AppStyle.hGap32,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        widget.title,
                        style: _node.isFoucsed.value
                            ? AppStyle.textStyleBlack
                            : AppStyle.textStyleWhite,
                      ),
                      if (widget.subtitle != null)
                        Text(
                          widget.subtitle!,
                          style: _node.isFoucsed.value
                              ? AppStyle.textStyleBlack
                                  .copyWith(fontSize: 24.w)
                              : AppStyle.textStyleWhite
                                  .copyWith(fontSize: 24.w),
                        ),
                    ],
                  ),
                ),
                AppStyle.hGap12,
                if (widget.onTap != null &&
                    _node.isFoucsed.value &&
                    widget.trailing == null)
                  Icon(
                    Icons.chevron_right,
                    size: 40.w,
                    color: _node.isFoucsed.value ? Colors.black : Colors.white,
                  ),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
