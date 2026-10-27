import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/widgets/highlight_widget.dart';

/// [focusNode] 可选：不传时内部创建并自管理生命周期
class HomeBigButton extends StatefulWidget {
  final String text;
  final IconData iconData;
  final AppFocusNode? focusNode;
  final Function()? onTap;
  final bool autofocus;
  const HomeBigButton({
    required this.iconData,
    required this.text,
    this.onTap,
    this.focusNode,
    this.autofocus = false,
    super.key,
  });

  @override
  State<HomeBigButton> createState() => _HomeBigButtonState();
}

class _HomeBigButtonState extends State<HomeBigButton>
    with ManagedAppFocusNode<HomeBigButton> {
  AppFocusNode get _node => resolveFocusNode(widget.focusNode);

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => HighlightWidget(
        onTap: widget.onTap,
        autofocus: widget.autofocus,
        focusNode: _node,
        borderRadius: AppStyle.radius16,
        color: Colors.white10,
        child: Container(
          padding: AppStyle.edgeInsetsA32.copyWith(left: 48.w, right: 48.w),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: AppStyle.edgeInsetsA12,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  widget.iconData,
                  size: 64.w,
                  color: _node.isFoucsed.value ? Colors.black : Colors.white,
                ),
              ),
              AppStyle.vGap24,
              Text(
                widget.text,
                style: TextStyle(
                  fontSize: 36.w,
                  color: _node.isFoucsed.value ? Colors.black : Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
