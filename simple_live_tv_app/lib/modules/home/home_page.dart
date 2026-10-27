import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:get/get.dart';
import 'package:lottie/lottie.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/modules/home/home_controller.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/services/follow_user_service.dart';
import 'package:simple_live_tv_app/widgets/app_scaffold.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_button.dart';
import 'package:simple_live_tv_app/widgets/button/highlight_list_tile.dart';
import 'package:simple_live_tv_app/widgets/card/anchor_card.dart';
import 'package:simple_live_tv_app/widgets/button/home_big_button.dart';
import 'package:simple_live_tv_app/widgets/net_image.dart';
import 'package:simple_live_tv_app/widgets/status/app_empty_widget.dart';

class HomePage extends GetView<HomeController> {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      child: Column(
        children: [
          AppStyle.vGap32,
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AppStyle.hGap48,
              Text(
                "Simple Live TV",
                style: AppStyle.titleStyleWhite,
              ),
              AppStyle.hGap24,
              const Spacer(),
              Obx(
                () => Text(
                  controller.datetime.value,
                  style: AppStyle.titleStyleWhite.copyWith(fontSize: 36.w),
                ),
              ),
              AppStyle.hGap32,
              HighlightButton(
                iconData: Icons.settings,
                text: "设置",
                onTap: () {
                  controller.toSettings();
                },
              ),
              AppStyle.hGap48,
            ],
          ),
          Expanded(
            child: ListView(
              padding: AppStyle.edgeInsetsV32,
              children: [
                Padding(
                  padding: AppStyle.edgeInsetsH48,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: HomeBigButton(
                          autofocus: true,
                          text: "热门直播",
                          iconData: Remix.fire_line,
                          onTap: controller.toHotLive,
                        ),
                      ),
                      AppStyle.hGap48,
                      Expanded(
                        child: HomeBigButton(
                          autofocus: true,
                          text: "直播类目",
                          iconData: Remix.apps_line,
                          onTap: controller.toCategory,
                        ),
                      ),
                      AppStyle.hGap48,
                      Expanded(
                        child: HomeBigButton(
                          autofocus: true,
                          text: "搜索直播",
                          iconData: Remix.search_2_line,
                          onTap: showSearchDialog,
                        ),
                      ),
                      // AppStyle.hGap40,
                      // Expanded(
                      //   child: HomeBigButton(
                      //     text: "我的关注",
                      //     iconData: Icons.favorite_border,
                      //     onTap: controller.toFollow,
                      //   ),
                      // ),
                      AppStyle.hGap48,
                      Expanded(
                        child: HomeBigButton(
                          text: "观看记录",
                          iconData: Icons.history,
                          onTap: controller.toHistory,
                        ),
                      ),
                      AppStyle.hGap48,
                      Expanded(
                        child: HomeBigButton(
                          text: "数据同步",
                          iconData: Icons.devices,
                          onTap: controller.toSync,
                        ),
                      ),
                    ],
                  ),
                ),
                AppStyle.vGap32,
                Padding(
                  padding: AppStyle.edgeInsetsH48,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 64.w,
                        height: 64.w,
                        child: Center(
                          child: Icon(
                            Icons.favorite_border,
                            color: Colors.white,
                            size: 56.w,
                          ),
                        ),
                      ),
                      AppStyle.hGap24,
                      Expanded(
                        child: Text(
                          "我的关注",
                          style: AppStyle.titleStyleWhite,
                        ),
                      ),
                      Obx(
                        () => Visibility(
                          visible: FollowUserService.instance.updating.value,
                          child: Row(
                            children: [
                              SizedBox(
                                width: 48.w,
                                height: 48.w,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 4.w,
                                ),
                              ),
                              AppStyle.hGap16,
                              Text(
                                "更新状态中...",
                                style: AppStyle.textStyleWhite,
                              ),
                            ],
                          ),
                        ),
                      ),
                      AppStyle.hGap16,
                      HighlightButton(
                        iconData: Icons.settings,
                        text: "管理",
                        onTap: showManageDialog,
                      ),
                      AppStyle.hGap32,
                      HighlightButton(
                        iconData: Icons.refresh,
                        text: "刷新",
                        onTap: () {
                          FollowUserService.instance.refreshData();
                        },
                      ),
                    ],
                  ),
                ),
                AppStyle.vGap32,
                Obx(
                  () => MasonryGridView.count(
                    padding: AppStyle.edgeInsetsH48,
                    itemCount: FollowUserService.instance.list.length,
                    crossAxisCount: 3,
                    crossAxisSpacing: 48.w,
                    mainAxisSpacing: 48.w,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemBuilder: (_, i) {
                      var item = FollowUserService.instance.list[i];
                      return Obx(
                        () => AnchorCard(
                          face: item.face,
                          name: item.userName,
                          siteId: item.siteId,
                          liveStatus: item.liveStatus.value,
                          roomId: item.roomId,
                        ),
                      );
                    },
                  ),
                ),
                Obx(
                  () => Visibility(
                    visible: FollowUserService.instance.list.isEmpty,
                    child: Column(
                      children: [
                        AppStyle.vGap24,
                        LottieBuilder.asset(
                          'assets/lotties/empty.json',
                          width: 160.w,
                          height: 160.w,
                          repeat: false,
                        ),
                        AppStyle.vGap24,
                        Text(
                          "暂无任何关注\n您可以从其他端同步数据到此处",
                          textAlign: TextAlign.center,
                          style: AppStyle.textStyleWhite,
                        ),
                        AppStyle.vGap16,
                        HighlightButton(
                          iconData: Icons.devices,
                          text: "同步数据",
                          onTap: () {
                            controller.toSync();
                          },
                        ),
                      ],
                    ),
                  ),
                )
              ],
            ),
          ),
        ],
      ),
    );
  }

  void showManageDialog() {
    Utils.showSystemRightDialog(
      //useSystem: true,
      width: 700.w,
      child: Column(
        children: [
          AppStyle.vGap24,
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AppStyle.hGap48,
              HighlightButton(
                iconData: Icons.arrow_back,
                text: "返回",
                onTap: () {
                  //Utils.hideRightDialog();
                  Get.back();
                },
              ),
              AppStyle.hGap32,
              Text(
                "关注管理",
                style: AppStyle.titleStyleWhite.copyWith(
                  fontSize: 36.w,
                  fontWeight: FontWeight.bold,
                ),
              ),
              AppStyle.hGap24,
              const Spacer(),
            ],
          ),
          Expanded(
            child: Stack(
              children: [
                Obx(
                  () => ListView.separated(
                    itemCount: FollowUserService.instance.list.length,
                    separatorBuilder: (_, __) => AppStyle.vGap24,
                    padding: AppStyle.edgeInsetsA40,
                    itemBuilder: (_, i) {
                      return _FollowUserTile(
                        item: FollowUserService.instance.list[i],
                        autofocus: i == 0,
                      );
                    },
                  ),
                ),
                Obx(
                  () => Visibility(
                    visible: FollowUserService.instance.list.isEmpty,
                    child: const AppEmptyWidget(
                      text: "关注列表为空，快去关注一些主播吧",
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void showSearchDialog() {
    showDialog(
      context: Get.context!,
      builder: (_) => _SearchDialog(controller: controller),
    );
  }
}

/// 关注列表项：焦点节点随条目自建自毁，避免在 itemBuilder 里临时创建导致泄漏
class _FollowUserTile extends StatefulWidget {
  const _FollowUserTile({
    required this.item,
    this.autofocus = false,
  });

  final FollowUser item;
  final bool autofocus;

  @override
  State<_FollowUserTile> createState() => _FollowUserTileState();
}

class _FollowUserTileState extends State<_FollowUserTile> {
  final AppFocusNode _focusNode = AppFocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HighlightListTile(
      autofocus: widget.autofocus,
      leading: NetImage(
        widget.item.face,
        width: 64.w,
        height: 64.w,
        borderRadius: 64.w,
      ),
      title: widget.item.userName,
      focusNode: _focusNode,
      trailing: Obx(
        () => Icon(
          Icons.delete_outline_outlined,
          size: 40.w,
          color: _focusNode.isFoucsed.value ? Colors.black : Colors.white,
        ),
      ),
      onTap: () {
        FollowUserService.instance.removeItem(widget.item, refresh: false);
      },
    );
  }
}

/// 搜索弹窗：输入控制器与焦点节点由本组件持有，关闭时统一释放
class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.controller});

  final HomeController controller;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final TextEditingController _textController = TextEditingController();
  final AppFocusNode _roomFocusNode = AppFocusNode()..isFoucsed.value = true;
  final AppFocusNode _anchorFocusNode = AppFocusNode();
  final RxInt _mode = 0.obs;

  @override
  void dispose() {
    _textController.dispose();
    _roomFocusNode.dispose();
    _anchorFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Get.theme.cardColor,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: AppStyle.radius16,
      ),
      contentPadding: AppStyle.edgeInsetsA48,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Obx(
                () => HighlightButton(
                  text: "直播间",
                  iconData: Icons.live_tv,
                  selected: _mode.value == 0,
                  focusNode: _roomFocusNode,
                  autofocus: true,
                  onTap: () {
                    _mode.value = 0;
                  },
                ),
              ),
              AppStyle.hGap40,
              Obx(
                () => HighlightButton(
                  text: "主播",
                  selected: _mode.value == 1,
                  iconData: Icons.person,
                  focusNode: _anchorFocusNode,
                  onTap: () {
                    _mode.value = 1;
                  },
                ),
              ),
            ],
          ),
          AppStyle.vGap48,
          SizedBox(
            width: 700.w,
            child: TextField(
              controller: _textController,
              style: AppStyle.textStyleWhite,
              textInputAction: TextInputAction.search,
              onSubmitted: (e) {
                Get.back();
                if (e.isEmpty) {
                  return;
                }
                if (_mode.value == 0) {
                  widget.controller.toSearchRoom(_textController.text);
                } else {
                  widget.controller.toSearchAnchor(_textController.text);
                }
              },
              decoration: InputDecoration(
                hintText: _mode.value == 0 ? "点击输入关键字搜索" : "点击主播昵称搜索",
                hintStyle: AppStyle.textStyleWhite,
                border: OutlineInputBorder(
                  borderRadius: AppStyle.radius16,
                  borderSide: BorderSide(width: 4.w),
                ),
                filled: true,
                isDense: true,
                fillColor: Get.theme.primaryColor,
                contentPadding: AppStyle.edgeInsetsA32,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
