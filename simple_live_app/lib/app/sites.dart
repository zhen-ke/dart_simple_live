import 'package:simple_live_shared/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';

class Sites {
  static final Map<String, Site> allSites = {
    Constant.kBiliBili: Site(
      id: Constant.kBiliBili,
      logo: "assets/images/bilibili_2.png",
      name: "哔哩哔哩",
      liveSite: BiliBiliSite(),
    ),
    Constant.kDouyu: Site(
      id: Constant.kDouyu,
      logo: "assets/images/douyu.png",
      name: "斗鱼直播",
      liveSite: DouyuSite(),
    ),
    Constant.kHuya: Site(
      id: Constant.kHuya,
      logo: "assets/images/huya.png",
      name: "虎牙直播",
      liveSite: HuyaSite(),
    ),
    Constant.kDouyin: Site(
      id: Constant.kDouyin,
      logo: "assets/images/douyin.png",
      name: "抖音直播",
      liveSite: DouyinSite(),
    ),
  };

  /// 缓存与失效键：siteSort 变化时重建。
  /// 首页/分类/搜索每次 build 都会读它，重排序前没必要反复 map+toList
  static List<Site>? _supportSitesCache;
  static String _supportSitesSortKey = "";

  static List<Site> get supportSites {
    final sort = AppSettingsController.instance.siteSort.join(",");
    if (_supportSitesCache == null || sort != _supportSitesSortKey) {
      _supportSitesSortKey = sort;
      _supportSitesCache = AppSettingsController.instance.siteSort
          .map((key) => allSites[key]!)
          .toList();
    }
    return _supportSitesCache!;
  }
}

class Site {
  final String id;
  final String name;
  final String logo;
  final LiveSite liveSite;
  Site({
    required this.id,
    required this.liveSite,
    required this.logo,
    required this.name,
  });
}
