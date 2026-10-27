import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/main.dart';

/// 全量编译冒烟：import main.dart 会把路由表引用的整棵页面树
/// 一起拉进编译单元，任何文件编译失败都会在这里暴露
void main() {
  test('main 模块全量可编译', () {
    expect(MyApp, isNotNull);
  });
}
