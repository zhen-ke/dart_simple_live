import 'package:flutter/material.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/widgets/status/app_empty_widget.dart';
import 'package:simple_live_tv_app/widgets/status/app_error_widget.dart';
import 'package:simple_live_tv_app/widgets/status/app_loadding_widget.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:get/get.dart';

class PageGridView extends StatelessWidget {
  final BasePageController pageController;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets? padding;
  final bool firstRefresh;
  final Function()? onLoginSuccess;
  final bool showPageLoadding;
  final double crossAxisSpacing, mainAxisSpacing;
  final int crossAxisCount;
  const PageGridView({
    required this.itemBuilder,
    required this.pageController,
    this.padding,
    this.firstRefresh = false,
    this.showPageLoadding = false,
    this.onLoginSuccess,
    this.crossAxisSpacing = 0.0,
    this.mainAxisSpacing = 0.0,
    required this.crossAxisCount,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    // 按订阅粒度拆分 Obx：数据列表只依赖 list，加载状态只依赖各状态位。
    // 任何一处变化只重建自己的小分支，不再整棵网格重建
    return Stack(
      children: [
        Obx(
          () => MasonryGridView.count(
            padding: padding,
            controller: pageController.scrollController,
            itemCount: pageController.list.length,
            itemBuilder: itemBuilder,
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: crossAxisSpacing,
            mainAxisSpacing: mainAxisSpacing,
          ),
        ),
        Obx(
          () => Offstage(
            offstage: !pageController.pageEmpty.value,
            child: AppEmptyWidget(
              onRefresh: () => pageController.refreshData(),
            ),
          ),
        ),
        Obx(() {
          // showPageLoadding 默认 false，写成 `showPageLoadding && xxx.value`
          // 会短路，builder 一个 Rx 都没订阅 → GetX 抛错 → 该分支被
          // ErrorWidget（release 下是 94% 不透明灰块）覆盖整个网格并吃掉按键/点击
          final pageLoadding = pageController.pageLoadding.value;
          return Offstage(
            offstage: !(showPageLoadding && pageLoadding),
            child: const AppLoaddingWidget(),
          );
        }),
        Obx(
          () => Offstage(
            offstage: !pageController.pageError.value,
            child: AppErrorWidget(
              errorMsg: pageController.errorMsg.value,
              onRefresh: () => pageController.refreshData(),
            ),
          ),
        ),
      ],
    );
  }
}
