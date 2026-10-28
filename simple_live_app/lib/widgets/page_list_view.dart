import 'dart:io';

import 'package:flutter/material.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/widgets/status/app_empty_widget.dart';
import 'package:simple_live_app/widgets/status/app_error_widget.dart';
import 'package:simple_live_app/widgets/status/app_loadding_widget.dart';

import 'package:flutter_easyrefresh/easy_refresh.dart';
import 'package:get/get.dart';

typedef IndexedWidgetBuilder = Widget Function(BuildContext context, int index);

class PageListView extends StatelessWidget {
  final BasePageController pageController;
  final IndexedWidgetBuilder itemBuilder;
  final IndexedWidgetBuilder? separatorBuilder;
  final EdgeInsets? padding;
  final bool firstRefresh;
  final Function()? onLoginSuccess;
  final bool showPageLoadding;
  final bool showPCRefreshButton;
  const PageListView({
    required this.itemBuilder,
    required this.pageController,
    this.padding,
    this.firstRefresh = false,
    this.showPageLoadding = false,
    this.showPCRefreshButton = true,
    this.separatorBuilder,
    this.onLoginSuccess,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    // 按订阅粒度拆分 Obx：数据列表只依赖 list，加载状态只依赖各状态位。
    // 任何一处变化只重建自己的小分支，不再整棵 EasyRefresh + 列表重建
    return Stack(
      children: [
        Obx(
          () => EasyRefresh(
            header: MaterialHeader(
              completeDuration: const Duration(milliseconds: 400),
            ),
            footer: MaterialFooter(
              completeDuration: const Duration(milliseconds: 400),
            ),
            scrollController: pageController.scrollController,
            controller: pageController.easyRefreshController,
            firstRefresh: firstRefresh,
            onLoad: pageController.loadData,
            onRefresh: pageController.refreshData,
            child: ListView.separated(
              padding: padding,
              itemCount: pageController.list.length,
              itemBuilder: itemBuilder,
              separatorBuilder:
                  separatorBuilder ?? (context, i) => const SizedBox(),
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: // 加载更多按钮
              Obx(() {
            // Rx 必须在参与判断前无条件读取：平台判断放在最前面时，
            // 移动端会在第一个 && 处短路，builder 一个 Rx 都没订阅，
            // GetX 会抛 "improper use of a GetX"，该分支被 ErrorWidget 覆盖
            final canLoadMore = pageController.canLoadMore.value;
            final pageLoadding = pageController.pageLoadding.value;
            final pageEmpty = pageController.pageEmpty.value;
            return Visibility(
              visible: (Platform.isWindows ||
                      Platform.isLinux ||
                      Platform.isMacOS) &&
                  canLoadMore &&
                  !pageLoadding &&
                  !pageEmpty,
              child: Center(
                child: TextButton(
                  onPressed: pageController.loadData,
                  child: const Text("加载更多"),
                ),
              ),
            );
          }),
        ),
        Positioned(
          bottom: 12,
          right: 12,
          child: // 加载更多按钮
              Obx(() {
            // 同上方：先无条件读取 Rx，再参与平台/状态判断
            final canLoadMore = pageController.canLoadMore.value;
            final pageLoadding = pageController.pageLoadding.value;
            final pageEmpty = pageController.pageEmpty.value;
            return Visibility(
              visible: (Platform.isWindows ||
                      Platform.isLinux ||
                      Platform.isMacOS) &&
                  canLoadMore &&
                  !pageLoadding &&
                  !pageEmpty &&
                  showPCRefreshButton,
              child: Center(
                child: IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: Get.theme.cardColor.withAlpha(200),
                    elevation: 4,
                  ),
                  onPressed: () {
                    pageController.refreshData();
                  },
                  icon: const Icon(Icons.refresh),
                ),
              ),
            );
          }),
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
          // ErrorWidget（release 下是 94% 不透明灰块）覆盖整个列表并吃掉点击
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
