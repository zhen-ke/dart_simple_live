import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';

/// 手动控制请求时序的假分页控制器：
/// 用 Completer 精确编排"旧请求在新请求之后返回"的竞态
class ControlledPageController extends BasePageController<int> {
  final List<Completer<List<int>>> completers = [];

  @override
  Future<List<int>> getData(int page, int pageSize) {
    final completer = Completer<List<int>>();
    completers.add(completer);
    return completer.future;
  }
}

/// 一次返回固定数据的假分页控制器
class FixedPageController extends BasePageController<int> {
  final List<int> result;
  FixedPageController(this.result);

  @override
  Future<List<int>> getData(int page, int pageSize) async => result;
}

/// BasePageController 的请求代次回归网：
/// 刷新/翻页的竞态语义是所有列表页的数据正确性基础
void main() {
  group('请求代次', () {
    test('旧请求晚于新请求返回时，结果被丢弃', () async {
      final controller = ControlledPageController();

      final first = controller.refreshData();
      final second = controller.refreshData();
      expect(controller.completers, hasLength(2));

      // 第二次（新代次）先返回
      controller.completers[1].complete([1, 2]);
      await second;
      expect(controller.list, [1, 2]);

      // 第一次（旧代次）晚到：不得写回列表
      controller.completers[0].complete([9, 9, 9]);
      await first;
      expect(controller.list, [1, 2]);
    });

    test('翻页结果累加，pageEmpty 只在首页为空时置位', () async {
      final controller = ControlledPageController()..pageSize = 2;

      final first = controller.refreshData();
      controller.completers[0].complete([1, 2]);
      await first;
      expect(controller.canLoadMore.value, isTrue);

      final more = controller.loadData();
      controller.completers[1].complete([3]);
      await more;
      expect(controller.list, [1, 2, 3]);
      // 最后一页不足一页：不能再加载
      expect(controller.canLoadMore.value, isFalse);
      expect(controller.pageEmpty.value, isFalse);
    });

    test('首页为空时进入空态', () async {
      final controller = FixedPageController(const []);
      await controller.refreshData();
      expect(controller.pageEmpty.value, isTrue);
      expect(controller.list, isEmpty);
    });

    test('加载中的重复 loadData 不并发发起', () async {
      final controller = ControlledPageController();
      final first = controller.refreshData();
      expect(controller.completers, hasLength(1));

      // loadding 期间 loadData 直接跳过
      final skipped = controller.loadData();
      expect(controller.completers, hasLength(1));
      await skipped;

      controller.completers[0].complete([1]);
      await first;
      expect(controller.list, [1]);
    });
  });
}
