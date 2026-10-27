import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';

typedef FocusOnKeyDownCallback = KeyEventResult Function();

/// 高亮组件
///
/// [focusNode] 可选：不传时组件内部创建并在销毁时释放；
/// 需要外部主动 requestFocus 时才由调用方传入并自行管理
class HighlightWidget extends StatefulWidget {
  final AppFocusNode? focusNode;
  final Widget child;
  final FocusOnKeyDownCallback? onUpKey;
  final FocusOnKeyDownCallback? onDownKey;
  final FocusOnKeyDownCallback? onLeftKey;
  final FocusOnKeyDownCallback? onRightKey;
  final Function(bool)? onFocusChange;
  final Function()? onTap;
  final Color foucsedColor;
  final Color color;
  final bool autofocus;
  final BorderRadius? borderRadius;
  final double order;
  final bool selected;
  const HighlightWidget({
    this.focusNode,
    required this.child,
    this.onUpKey,
    this.onDownKey,
    this.onLeftKey,
    this.onRightKey,
    this.onFocusChange,
    this.onTap,
    this.autofocus = false,
    this.selected = false,
    this.borderRadius,
    this.order = 0.0,
    this.color = Colors.transparent,
    this.foucsedColor = Colors.white,
    Key? key,
  }) : super(key: key);

  @override
  State<HighlightWidget> createState() => _HighlightWidgetState();
}

class _HighlightWidgetState extends State<HighlightWidget>
    with ManagedAppFocusNode<HighlightWidget> {
  AppFocusNode get _node => resolveFocusNode(widget.focusNode);

  @override
  Widget build(BuildContext context) {
    return FocusTraversalOrder(
      order: NumericFocusOrder(widget.order),
      child: Focus(
        focusNode: _node,
        autofocus: widget.autofocus,
        onFocusChange: widget.onFocusChange,
        onKeyEvent: (node, e) {
          if (e is KeyDownEvent) {
            if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
              return widget.onRightKey?.call() ?? KeyEventResult.ignored;
            }
            if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
              return widget.onLeftKey?.call() ?? KeyEventResult.ignored;
            }
            if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
              return widget.onUpKey?.call() ?? KeyEventResult.ignored;
            }
            if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
              return widget.onDownKey?.call() ?? KeyEventResult.ignored;
            }
            if (e.logicalKey == LogicalKeyboardKey.enter ||
                e.logicalKey == LogicalKeyboardKey.select ||
                e.logicalKey == LogicalKeyboardKey.space) {
              return widget.onTap?.call() ?? KeyEventResult.ignored;
            }
          }

          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: Obx(
            () => AnimatedScale(
              scale: _node.isFoucsed.value ? 1.1 : 1,
              duration: const Duration(milliseconds: 200),
              child: GestureDetector(
                onTap: widget.onTap,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: widget.borderRadius,
                    boxShadow: _node.isFoucsed.value
                        ? AppStyle.highlightShadow
                        : null,
                    color: (_node.isFoucsed.value || widget.selected)
                        ? widget.foucsedColor
                        : widget.color,
                  ),
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
