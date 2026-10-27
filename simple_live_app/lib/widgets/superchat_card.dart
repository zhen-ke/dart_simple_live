import 'dart:async';

import 'package:flutter/material.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

class SuperChatCard extends StatefulWidget {
  final LiveSuperChatMessage message;
  final Function()? onExpire;
  final int? customCountdown;
  const SuperChatCard(
    this.message, {
    required this.onExpire,
    this.customCountdown,
    Key? key,
  }) : super(key: key);

  @override
  State<SuperChatCard> createState() => _SuperChatCardState();
}

class _SuperChatCardState extends State<SuperChatCard> {
  Timer? timer;

  int countdown = 0;

  @override
  void initState() {
    super.initState();
    _resetCountdown();
    // 外部已按秒驱动倒计时（如播放器 SC 浮层传入 customCountdown）时，
    // 内部不再起自己的 1 秒 timer：否则每条浮层 SC 每秒重建两次
    if (widget.customCountdown == null) {
      timer = Timer.periodic(const Duration(seconds: 1), timerCallback);
    }
  }

  @override
  void didUpdateWidget(SuperChatCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 消息或倒计时驱动方式变化时同步内部状态
    if (widget.message != oldWidget.message) {
      _resetCountdown();
    }
    if ((widget.customCountdown == null) !=
        (oldWidget.customCountdown == null)) {
      if (widget.customCountdown == null) {
        _resetCountdown();
        timer ??= Timer.periodic(const Duration(seconds: 1), timerCallback);
      } else {
        timer?.cancel();
        timer = null;
      }
    }
  }

  void _resetCountdown() {
    var currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var endTime = widget.message.endTime.millisecondsSinceEpoch ~/ 1000;

    countdown = endTime - currentTime;
  }

  void timerCallback(e) {
    if (countdown <= 0) {
      timer?.cancel();
      widget.onExpire?.call();
      return;
    }

    setState(() {
      countdown -= 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final displayCountdown = widget.customCountdown ?? countdown;
    return ClipRRect(
      borderRadius: AppStyle.radius8,
      child: Container(
        decoration: BoxDecoration(
          color: Utils.convertHexColor(widget.message.backgroundColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: AppStyle.edgeInsetsA8,
              child: Row(
                children: [
                  NetImage(
                    widget.message.face,
                    width: 48,
                    height: 48,
                    borderRadius: 36,
                  ),
                  AppStyle.hGap12,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          widget.message.userName,
                          style: const TextStyle(
                            color: AppColors.black333,
                          ),
                        ),
                        Text(
                          "￥${widget.message.price}",
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    "$displayCountdown",
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color:
                    Utils.convertHexColor(widget.message.backgroundBottomColor),
              ),
              padding: AppStyle.edgeInsetsA8,
              child: Text(
                widget.message.message,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }
}
