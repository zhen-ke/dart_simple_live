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
- 尚未迁移（两端行为差异大，需先做行为决策）：
  - `services/local_storage_service.dart`（设置键集合两端不同）
  - `services/sync_service.dart`（app 多 tag 同步路由）
  - `app/controller/app_settings_controller.dart`（设置项集合不同）
  - player 核心与 UI 层（差异最大，最后迁）

## 约定

- 只放"两端行为完全一致"的代码；任何一端特有的行为留在各自仓库里
- 共享的 Hive 模型其 TypeAdapter typeId 即数据库二进制格式，
  改动前必须确认双端数据兼容
