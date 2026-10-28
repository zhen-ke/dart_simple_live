import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/widgets/page_grid_view.dart';

class _FakePageController extends BasePageController<int> {
  @override
  Future<List<int>> getData(int page, int pageSize) async => <int>[];
}

/// 回归网：PageGridView 内部按订阅粒度拆了多个 Obx，
/// 其中"页面加载态"分支写成 `showPageLoadding && pageLoadding.value`。
/// showPageLoadding 默认 false 时 `&&` 会短路，builder 一次 Rx 都没读到，
/// GetX 会抛 "the improper use of a GetX has been detected"，
/// 整个网格被 ErrorWidget（release 下是不透明灰块）覆盖并吃掉所有点击。
void main() {
  testWidgets('默认不展示页面加载态时，PageGridView 不应触发 GetX 异常', (tester) async {
    final controller = Get.put(_FakePageController());

    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: PageGridView(
            pageController: controller,
            crossAxisCount: 2,
            itemBuilder: (_, i) => Text('${controller.list[i]}'),
          ),
        ),
      ),
    );
    await tester.pump();

    final exception = tester.takeException();
    expect(
      exception.toString().contains('improper use of a GetX'),
      isFalse,
      reason: 'Obx 短路未读取 Rx，GetX 抛错后整个网格会被 ErrorWidget 覆盖',
    );
  });
}
