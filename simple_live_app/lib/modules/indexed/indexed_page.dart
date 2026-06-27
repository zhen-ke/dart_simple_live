import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';

import 'indexed_controller.dart';

class IndexedPage extends GetView<IndexedController> {
  const IndexedPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return OrientationBuilder(
      builder: (context, orientation) {
        return Scaffold(
          body: Row(
            children: [
              Visibility(
                visible: orientation == Orientation.landscape,
                child: Obx(
                  () => Theme(
                    data: Theme.of(context).copyWith(
                      navigationRailTheme: NavigationRailThemeData(
                        backgroundColor: !Platform.isAndroid && !Platform.isIOS
                            ? (Theme.of(context).brightness == Brightness.light
                                ? const Color(0xfff5f5f7)
                                : const Color(0xff1e1e1f))
                            : null,
                        indicatorColor: Theme.of(context)
                            .colorScheme
                            .primary
                            .withOpacity(0.12),
                        selectedIconTheme: IconThemeData(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        unselectedIconTheme: const IconThemeData(
                          color: Colors.grey,
                        ),
                      ),
                    ),
                    child: NavigationRail(
                      selectedIndex: controller.index.value,
                      onDestinationSelected: controller.setIndex,
                      labelType: NavigationRailLabelType.none,
                      destinations: controller.items
                          .map(
                            (item) => NavigationRailDestination(
                              icon: Icon(item.iconData),
                              label: Text(item.title),
                              padding: AppStyle.edgeInsetsV12,
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Obx(
                  () => Container(
                    decoration: BoxDecoration(
                      border: Border(
                        left: orientation == Orientation.landscape
                            ? BorderSide(
                                color: Colors.grey.withAlpha(50),
                                width: 1,
                              )
                            : BorderSide.none,
                      ),
                    ),
                    child: IndexedStack(
                      index: controller.index.value,
                      children: controller.pages,
                    ),
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar: Visibility(
            visible: orientation == Orientation.portrait,
            child: Obx(
              () => NavigationBar(
                selectedIndex: controller.index.value,
                onDestinationSelected: controller.setIndex,
                height: 56,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
                destinations: controller.items
                    .map(
                      (item) => NavigationDestination(
                        icon: Icon(item.iconData),
                        label: item.title,
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        );
      },
    );
  }
}
