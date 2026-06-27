import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'dart:ui' as ui;

class FollowUserItem extends StatefulWidget {
  final FollowUser item;
  final Function()? onRemove;
  final Function()? onTap;
  final Function()? onLongPress;
  final bool playing;
  final bool cardMode;
  const FollowUserItem({
    required this.item,
    this.onRemove,
    this.onTap,
    this.onLongPress,
    this.playing = false,
    this.cardMode = false,
    Key? key,
  }) : super(key: key);

  @override
  State<FollowUserItem> createState() => _FollowUserItemState();
}

class _FollowUserItemState extends State<FollowUserItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    if (widget.cardMode) {
      return _buildDesktopCard(context);
    }

    var site = Sites.allSites[widget.item.siteId]!;
    return ListTile(
      contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 4),
      leading: NetImage(
        widget.item.face,
        width: 48,
        height: 48,
        borderRadius: 24,
      ),
      title: Text.rich(
        TextSpan(
          text: widget.item.userName,
          children: [
            WidgetSpan(
              alignment: ui.PlaceholderAlignment.middle,
              child: Obx(
                () => Offstage(
                  offstage: widget.item.liveStatus.value == 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppStyle.hGap12,
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: widget.item.liveStatus.value == 2
                              ? Colors.green
                              : Colors.grey,
                          borderRadius: AppStyle.radius12,
                        ),
                      ),
                      AppStyle.hGap4,
                      Text(
                        getStatus(widget.item.liveStatus.value),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.normal,
                          color:
                              widget.item.liveStatus.value == 2 ? null : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      subtitle: Wrap(
        runSpacing: 1.0,
        children: [
          Image.asset(
            site.logo,
            width: 20,
          ),
          AppStyle.hGap4,
          Text(
            site.name,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          if (widget.playing)
            Padding(
              padding: AppStyle.edgeInsetsL8,
              child: Text(
                "正在观看",
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          else if (widget.item.liveStatus.value == 2 && widget.item.liveStartTime != null)
            Padding(
              padding: AppStyle.edgeInsetsL8,
              child: Text(
                '开播了${formatLiveDuration(widget.item.liveStartTime)}',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
            ),
        ],
      ),
      trailing: widget.playing
          ? const SizedBox(
              width: 64,
              child: Center(
                child: Icon(
                  Icons.play_arrow,
                ),
              ),
            )
          : (widget.onRemove == null
              ? null
              : IconButton(
                  onPressed: () {
                    widget.onRemove?.call();
                  },
                  icon: const Icon(Remix.dislike_line),
                )),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
    );
  }

  Widget _buildDesktopCard(BuildContext context) {
    var site = Sites.allSites[widget.item.siteId]!;
    bool isLive = widget.item.liveStatus.value == 2;

    // Platform gradient colors
    Gradient headerGradient;
    if (!isLive) {
      // Gray/muted gradient for offline
      headerGradient = const LinearGradient(
        colors: [Color(0xffbdc3c7), Color(0xff95a5a6)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    } else {
      switch (widget.item.siteId) {
        case 'bilibili':
          headerGradient = const LinearGradient(
            colors: [Color(0xfffb7299), Color(0xfffc8ea5)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );
          break;
        case 'douyu':
          headerGradient = const LinearGradient(
            colors: [Color(0xfffe5c00), Color(0xffff8a00)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );
          break;
        case 'huya':
          headerGradient = const LinearGradient(
            colors: [Color(0xffffaa00), Color(0xffffc83b)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );
          break;
        default:
          headerGradient = LinearGradient(
            colors: [
              Theme.of(context).colorScheme.primary.withOpacity(0.8),
              Theme.of(context).colorScheme.primary,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );
      }
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          transform: Matrix4.identity()..translate(0.0, _isHovered ? -4.0 : 0.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(_isHovered ? 0.08 : 0.03),
                blurRadius: _isHovered ? 12 : 6,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: Theme.of(context).dividerColor.withOpacity(0.08),
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 175,
                child: Stack(
                  children: [
                    // Header Gradient background
                    Container(
                      height: 65,
                      decoration: BoxDecoration(
                        gradient: headerGradient,
                      ),
                    ),
                    // Avatar (floating)
                    Positioned(
                      top: 35,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).cardColor,
                              width: 3,
                            ),
                          ),
                          child: NetImage(
                            widget.item.face,
                            width: 52,
                            height: 52,
                            borderRadius: 26,
                          ),
                        ),
                      ),
                    ),
                    // Content
                    Positioned(
                      top: 98,
                      left: 12,
                      right: 12,
                      bottom: 8,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            widget.item.userName,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Image.asset(
                                site.logo,
                                width: 14,
                                height: 14,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                site.name,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Obx(
                                () => Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: widget.item.liveStatus.value == 2
                                        ? Colors.green
                                        : Colors.grey,
                                    shape: BoxShape.circle,
                                    boxShadow: widget.item.liveStatus.value == 2
                                        ? [
                                            BoxShadow(
                                              color: Colors.green.withOpacity(0.5),
                                              blurRadius: 4,
                                              spreadRadius: 1,
                                            )
                                          ]
                                        : null,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Obx(
                                () => Text(
                                  widget.item.liveStatus.value == 2 ? "直播中" : "未开播",
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.normal,
                                    color: widget.item.liveStatus.value == 2
                                        ? Colors.green
                                        : Colors.grey,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Obx(
                            () => widget.playing
                                ? Text(
                                    "正在观看",
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(context).colorScheme.primary,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  )
                                : widget.item.liveStatus.value == 2 &&
                                        widget.item.liveStartTime != null
                                    ? Text(
                                        '开播了${formatLiveDuration(widget.item.liveStartTime)}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey,
                                        ),
                                      )
                                    : const Text(
                                        "离线",
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey,
                                        ),
                                      ),
                          ),
                        ],
                      ),
                    ),
                    // Hover Action - Dislike/Remove button
                    if (widget.onRemove != null)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: AnimatedOpacity(
                          opacity: _isHovered ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 150),
                          child: IgnorePointer(
                            ignoring: !_isHovered,
                            child: GestureDetector(
                              onTap: widget.onRemove,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.4),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Remix.dislike_line,
                                  color: Colors.white,
                                  size: 14,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String getStatus(int status) {
    if (status == 0) {
      return "读取中";
    } else if (status == 1) {
      return "未开播";
    } else {
      return "直播中";
    }
  }

  String formatLiveDuration(String? startTimeStampString) {
    if (startTimeStampString == null ||
        startTimeStampString.isEmpty ||
        startTimeStampString == "0") {
      return "";
    }
    try {
      int startTimeStamp = int.parse(startTimeStampString);
      int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      int durationInSeconds = currentTimeStamp - startTimeStamp;

      int hours = durationInSeconds ~/ 3600;
      int minutes = (durationInSeconds % 3600) ~/ 60;

      String hourText = hours > 0 ? '$hours小时' : '';
      String minuteText = minutes > 0 ? '$minutes分钟' : '';

      if (hours == 0 && minutes == 0) {
        return "不足1分钟";
      }

      return '$hourText$minuteText';
    } catch (e) {
      Log.logPrint('格式化开播时长出错: $e');
      return "--小时--分钟";
    }
  }
}
