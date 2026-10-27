# simple_live_shared

`simple_live_app` 与 `simple_live_tv_app` 共享的模型与基础层。

## 背景

两端长期各自维护一份同路径代码，已经出现行为漂移（同一问题在一边修了、
另一边还在）。本包按"先迁低风险层"的路线逐步收敛：

- 第一批（本批）：字节级一致、无行为分叉的纯模型与基础类型
  - `models/db/history.dart`（含生成代码，Hive TypeAdapter 两端同源）
  - `models/version_model.dart`
  - `models/account/bilibili_user_info_page.dart`
  - `requests/http_error.dart`（取消语义/根因保留，两端同一实现）
  - `widgets/keep_alive_wrapper.dart`
- 后续候选：DB/account/sync 服务层（需要先统一两端的存储键名与行为差异）、
  player 核心逻辑（差异最大，最后迁）

## 约定

- 只放"两端行为完全一致"的代码；任何一端特有的行为留在各自仓库里
- 共享的 Hive 模型其 TypeAdapter typeId 即数据库二进制格式，
  改动前必须确认双端数据兼容
