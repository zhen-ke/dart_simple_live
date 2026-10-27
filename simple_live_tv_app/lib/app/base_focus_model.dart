import 'package:simple_live_tv_app/app/app_focus_node.dart';

/// 持有焦点节点的数据项。
///
/// 节点随数据项创建（页面需要按序号 requestFocus），列表替换或控制器销毁时
/// 由 BasePageController 统一调用 [disposeFocusNode] 释放
abstract class FocusNodeOwner {
  void disposeFocusNode();
}

mixin BaseFocusModel implements FocusNodeOwner {
  final AppFocusNode focusNode = AppFocusNode();
  bool _focusNodeDisposed = false;

  bool get isFoucsed => focusNode.isFoucsed.value;

  /// 幂等：列表替换与控制器销毁可能各触发一次
  @override
  void disposeFocusNode() {
    if (_focusNodeDisposed) return;
    _focusNodeDisposed = true;
    focusNode.dispose();
  }
}
