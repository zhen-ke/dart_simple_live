import 'dart:async';

import 'package:get/get.dart';

import 'package:simple_live_tv_app/app/controller/base_controller.dart';

import 'package:simple_live_tv_app/routes/route_path.dart';

class HomeController extends BaseController {
  var datetime = "00:00".obs;

  /// 时钟只显示到分钟：定时器按分钟边界对齐触发，
  /// 而不是每秒 tick 一次，避免 TV 待机时每秒唤醒
  Timer? _clockTimer;

  @override
  void onInit() {
    _updateClock();
    _scheduleClockTick();
    super.onInit();
  }

  void _scheduleClockTick() {
    var now = DateTime.now();
    var nextMinute = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute + 1,
    );
    _clockTimer = Timer(nextMinute.difference(now), () {
      _updateClock();
      _scheduleClockTick();
    });
  }

  void _updateClock() {
    var now = DateTime.now();
    datetime.value =
        "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
  }

  @override
  void onClose() {
    _clockTimer?.cancel();
    _clockTimer = null;
    super.onClose();
  }

  void toSync() {
    Get.toNamed(RoutePath.kSync);
  }

  void toFollow() {
    Get.toNamed(RoutePath.kFollow);
  }

  void toSettings() {
    Get.toNamed(RoutePath.kSettings);
  }

  void toHistory() {
    Get.toNamed(RoutePath.kHistory);
  }

  void toHotLive() {
    Get.toNamed(RoutePath.kHotLive);
  }

  void toSearchRoom(String keyword) {
    Get.toNamed(RoutePath.kSearchRoom, arguments: keyword);
  }

  void toSearchAnchor(String keyword) {
    Get.toNamed(RoutePath.kSearchAnchor, arguments: keyword);
  }

  void toCategory() {
    Get.toNamed(RoutePath.kCategory);
  }
}
