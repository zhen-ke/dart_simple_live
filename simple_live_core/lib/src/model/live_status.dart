/// 直播间开播状态（三态）
///
/// - [live]：确认在播（含录播轮播）
/// - [offline]：确认未开播
/// - [unknown]：状态查询失败或尚未确认——不能与 offline 混为一谈，
///   查询失败时谎报下播曾导致直播间误显示"未开播"
enum LiveStatus {
  live,
  offline,
  unknown,
}
