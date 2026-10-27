import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_tv_app/app/sites.dart';

/// 站点表是 TV 端所有页面的数据源头，作为最小编译/初始化冒烟
void main() {
  test('站点表固定为 4 个且 id 唯一', () {
    final sites = Sites.supportSites;
    expect(sites, hasLength(4));
    expect(sites.map((e) => e.id).toSet(), hasLength(4));
    expect(sites.map((e) => e.index).toSet(), {0, 1, 2, 3});
  });
}
