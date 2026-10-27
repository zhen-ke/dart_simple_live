import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// 拓展FoucsNode
class AppFocusNode extends FocusNode {
  var isFoucsed = false.obs;
  AppFocusNode() {
    isFoucsed.value = hasFocus;
    addListener(updateFoucs);
  }

  updateFoucs() {
    isFoucsed.value = hasFocus;
  }

  @override
  void dispose() {
    removeListener(updateFoucs);
    super.dispose();
  }
}

/// 为 StatefulWidget 提供可选焦点节点的生命周期管理。
///
/// 外部传入节点（控制器/数据项持有，需主动 requestFocus）时由调用方负责释放；
/// 未传入时内部创建、本 State dispose 时释放，调用方不得在 build 中临时 new 节点。
mixin ManagedAppFocusNode<T extends StatefulWidget> on State<T> {
  AppFocusNode? _ownedNode;

  AppFocusNode resolveFocusNode(AppFocusNode? external) {
    return external ?? (_ownedNode ??= AppFocusNode());
  }

  @override
  void dispose() {
    _ownedNode?.dispose();
    super.dispose();
  }
}
