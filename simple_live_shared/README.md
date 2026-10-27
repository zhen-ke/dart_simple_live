# simple_live_shared

`simple_live_app` 与 `simple_live_tv_app` 共享的模型与基础层。

## 背景

两端长期各自维护一份同路径代码，已经出现行为漂移（同一问题在一边修了、
另一边还在）。本包按"先迁低风险层"的路线逐步收敛：

- 第一批：字节级一致、无行为分叉的纯模型与基础类型
  - `models/db/history.dart`（含生成代码，Hive TypeAdapter 两端同源）
  - `models/version_model.dart`
  - `models/account/bilibili_user_info_page.dart`
  - `requests/http_error.dart`
  - `widgets/keep_alive_wrapper.dart`
- 第二批：app 为超集、TV 兼容的模型与基础层（当前状态）
  - `app/log.dart`（自带时间格式与包信息，宿主在 bootstrap 时注入
    `Log.packageInfo`；含崩溃持久化，TV 端因此获得同一套能力）
  - `app/constant.dart`、`app/event_bus.dart`
  - `models/db/follow_user.dart`、`follow_user_tag.dart`（app 版为超集，
    缺失字段走默认值，与 TV 旧数据双向二进制兼容）
  - `requests/http_client.dart`、`requests/custom_log_interceptor.dart`
  - `services/db_service.dart`（box 名可注入：TV 传历史的 TV* 前缀名；
    合并语义单源，app 的 merge* 单测同时覆盖两端）
  - `services/bilibili/douyu/douyin_account_service.dart`（凭据存取与
    站点身份注入由宿主闭包提供，见两端 main.dart 的注册处）
  - `services/local_storage_service.dart`（键集合取两端超集，box 名注入；
    顺带修复 TV 端斗鱼设备号日志未脱敏）
  - `services/sync_service.dart`（UDP 发现/HTTP 服务/配对确认/全部同步
    路由单源；TV 补齐 /sync/tag，同步协议两端完全一致；
    平台标识、设备名兜底、屏蔽词落点与确认弹窗由宿主注入）
- 不再迁移（已用函数级 diff 证实为产品差异而非复制粘贴）：
  - `app/controller/app_settings_controller.dart`（设置项集合两端不同，
    无共同函数）
  - player 核心与 UI 层（两端 player_controller 仅共享 2 个不足 10 行的
    函数；自动隐藏时长、手势、遥控器焦点等均为产品差异）

## 约定

- 只放"两端行为完全一致"的代码；任何一端特有的行为留在各自仓库里
- 共享的 Hive 模型其 TypeAdapter typeId 即数据库二进制格式，
  改动前必须确认双端数据兼容
