# lua-resty-model ORM 审查报告

- 审查范围：`lib/model/{query,init,sql,parser,expr,utils,fields,validator}.lua`，以及 `docs/orm-*.md` 与实现的一致性
- 审查环境：OpenResty 1.21.4.2（`resty` CLI，timer 上下文）、PostgreSQL 15.15、`/usr/local/openresty/site/lualib/pgmoon`、本机 `test` 库（由 `spec/model_spec.lua` 建表）
- 审查方法：通读源码 + 对照 pgmoon 源码 + 用脚本在真实库上复现。文中标注「已复现」的条目都有实际输出；标注「未复现」的条目说明了原因
- 现有测试：`spec/model_spec.lua`（DB 集成）与 `spec/bug_spec.lua`（纯 SQL 生成）共 263 例，本次运行全部通过；下文的 bug 均不在现有用例覆盖范围内

---

## 1. 概述

### 总体评价

这是一个功能相当完整、经过多轮 review 打磨的 ORM：SQL 拼接层对列名的校验很严（`parser.lua` 对所有 `__` 段做字段/操作符白名单，非法段直接报错），值统一走 `as_literal` 转义，事务用 `xpcall + traceback` 保留错误对象，`field_error` 表能穿透事务原样上抛，Query 实例按 `pool_name` 共享保证跨 model 写入进同一事务。这些都是对的。

真正的风险集中在 `query.lua` 的连接生命周期和几处数据语义上：

1. **连接回收策略不区分「PG 报错」和「传输层错误」**。客户端读超时后 socket 里还滞留着上一条查询的回包，却被 `setkeepalive` 放回池子，下一条借到这个 socket 的查询会读到上一条的结果集，且从此永久错位一格。这是跨请求串数据，在政务 API 场景是最严重的一类问题。
2. **事务内错误被吞掉后 COMMIT 静默变 ROLLBACK**，`transaction()` 正常返回，调用方以为已提交。
3. 大整数、`NULL`、带时区 datetime、JSON 空数组这四类数据在某些路径上会**静默失真**。
4. `meta_query` 接受字符串条件，若应用把请求参数直接喂进去就是注入面。

其余问题多为局部语义与文档不符，修复代价小。

### 问题统计

| 严重程度   | 已确认 | 疑似 | 说明                                               |
| ---------- | ------ | ---- | -------------------------------------------------- |
| 严重（P0） | 1      | 0    | B1 连接池串数据                                    |
| 高（P1）   | 3      | 0    | B2 事务假提交、B3 大整数精度、B4 datetime 时区偏移 |
| 中（P2）   | 7      | 2    | B5–B11；S1、S2                                     |
| 低（P3）   | 6      | 4    | B12–B17；S3–S6                                     |
| 合计       | 17     | 6    |                                                    |

优先级判断依据：是否静默（不报错就出错数据）> 是否跨请求 > 触发概率。

---

## 2. 已确认的 bug

每条包含：位置、触发条件、后果、复现方式。复现代码可直接放进 `spec/` 用 busted 跑，或用 `resty -I lib -I spec` 跑独立脚本（`require "model_spec"` 在非 busted 下返回模型表）。

### B1 [严重] 传输层错误后的连接被放回连接池，后续查询读到上一条的结果集

- 位置：`lib/model/query.lua:356-372`（`send_query`：`pcall(conn.query)` 之后无条件 `conn:release()`）；`lib/model/query.lua:187-199`（`release` 对 nginx socket 一律 `keepalive`）；`lib/model/query.lua:380-411`（事务路径同样：`pcall(conn.rollback)` 后无条件 `release`）
- 触发条件：任意一次 `QUERY_TIMEOUT` 读超时（默认 10 s，慢查询/锁等待/PG 抖动都会触发），或 pgmoon 在收包中途返回的其它传输层错误（`receive_message: failed to ...`）。这类错误发生时 PG 还没发完（或根本还没开始发）当前查询的回包，socket 处于「有未读数据/将有未读数据」状态。
- 机理：pgmoon 只在收到 `ReadyForQuery` 后才返回结果；读超时返回 `nil, msg` 时协议状态未同步。`ConnProxy:query` 把它 `error()` 抛出，`send_query` 捕获后调 `release()` → `sock:setkeepalive()`。cosocket 的 `setkeepalive` 在读超时后**仍然返回成功**（已实测返回 `1`），脏 socket 进池。下一个 `connect()` 复用它，发出新查询，pgmoon 先读到的是上一条查询的回包。若 PG 的滞留回包在 socket 空闲期间到达，nginx 的 keepalive 关闭处理器会把它关掉（这就是为什么等 1.5 s 再查不会复现）；高并发下 socket 几乎立即被复用，这个保护窗口不存在。
- 后果：**跨请求串数据**。请求 B 拿到请求 A 的行；写操作的 `RETURNING` 对不上；`count()`/`exists()` 返回别人的值；该 socket 在池里存活期间每条查询都错位一格。事务路径下 `ROLLBACK` 也会读到滞留回包并「成功」，然后同样入池。
- 复现（已复现，`scratchpad/verify5.lua`）：

```lua
local Q = require("model.query")
local q = Q { DATABASE = 'test', USER = 'postgres', PASSWORD = 'postgres',
              QUERY_TIMEOUT = 1500, POOL_NAME = 'stale' }
local ok = pcall(q, "SELECT pg_sleep(2), 'FROM_TIMED_OUT_QUERY' AS marker")
assert(not ok)                                    -- 读超时
local res = q("SELECT pg_backend_pid() AS pid, 'SECOND' AS marker")
print(res[1].marker)                              -- 实际输出 FROM_TIMED_OUT_QUERY
local res3 = q("SELECT 'THIRD' AS marker")
print(res3[1].marker)                             -- 实际输出 SECOND
```

实测输出：第二条查询的 `marker` 是 `FROM_TIMED_OUT_QUERY`，第三条是 `SECOND`，且三条查询 `pg_backend_pid` 相同（同一 socket）。直接用 pgmoon 验证：`settimeout(300)` 后 `query("SELECT pg_sleep(1)")` 超时，随后 `keepalive()` 返回 `1`。

### B2 [高] 事务内被吞掉的错误让 COMMIT 静默变成 ROLLBACK，`transaction()` 正常返回

- 位置：`lib/model/query.lua:380-411`（`transaction`）、`lib/model/query.lua:218-234`（`ConnProxy:query` 不记录事务是否已进入 aborted 状态）
- 触发条件：callback 内某条 SQL 被 PG 报错（唯一冲突、外键、类型错误等），而调用方用 `pcall` 接住继续执行（「先试插入，失败就走另一条路」是常见写法）。此后 PG 会话处于 `aborted` 状态，`COMMIT` 被 PG 当作 `ROLLBACK` 执行且**不报错**，pgmoon 对 `COMMIT`/`ROLLBACK` 都返回 `true`。
- 后果：`transaction()` 返回 callback 的返回值，上层返回成功响应，但**什么都没写进去**。数据丢失且无日志。
- 复现（已复现，`scratchpad/verify.lua` 第 8 段）：

```lua
local before = Blog:count()
local ok, ret = pcall(function()
  return Blog:transaction(function()
    Blog:insert { name = 'tx-swallow' }:exec()
    pcall(function() Blog:insert { name = 'tx-swallow' }:exec() end) -- 唯一冲突，被吞
    return "callback returned normally"
  end)
end)
-- 实测：ok == true, ret == "callback returned normally"
-- 但 Blog:count() == before，'tx-swallow' 不存在
```

Django 对此的处理是 `needs_rollback` 标记 + `TransactionManagementError`，这里需要同样的机制（见任务 T2）。

### B3 [高] 大整数在写入和读回两个方向都会静默失真

- 位置：写入 `lib/model/utils.lua:486`（`_escape_factory` 对 number 用 `tostring`，LuaJIT 是 `%.14g`）；读回 pgmoon `init.lua:104,841`（OID 20 `int8` → `tonumber` → double）
- 触发条件：任何绝对值 ≥ 1e14 的整数值（15 位及以上）进入 `where`/`insert`/`update`/`in`；或 `bigint` 列读回值 > 2^53。典型：雪花 ID、微信/支付平台 ID、毫秒时间戳、把身份证/社保号当数字传的调用方。
- 后果：`WHERE T.id = 1.2345678901235e+17` 匹配错行或匹配不到；`INSERT` 写入被四舍五入的值；读回值末位错误。全部静默。
- 复现（已复现）：

```lua
Model.as_literal(123456789012345678)   -- '1.2345678901235e+17'
Model.as_literal(100000000000000)      -- '1e+14'
Blog:where { id = 123456789012345678 }:statement()
-- SELECT * FROM blog T WHERE T.id = 1.2345678901235e+17
local r = Blog.query("SELECT 123456789012345678::bigint AS b")
string.format("%.0f", r[1].b)          -- 123456789012345680
```

附带：`as_literal(0/0)`、`as_literal(math.huge)` 输出 `nan`/`inf`，是 PG 语法错误（会报错，不静默，只是错误信息难懂）。

### B4 [高] 带时区偏移的 datetime 经 CTE 路径 `::timestamp` 转换后丢失偏移

- 位置：`lib/model/sql.lua:1647-1663`（`_array_to_values` 用 `field.db_type` 给 CTE 首行加类型后缀）；`lib/model/fields.lua:1074,1085`（`DatetimeField.timezone = true` 但 `db_type = "timestamp"`）；`lib/model/validator.lua` `datetime` 校验器刻意保留 `+08:00`/`Z`
- 触发条件：`merge`、`updates`、`gets`、`merge_gets`、`with_values`（含 `create_sql_as`）这些走 `_get_cte_values_literal` 的方法，且 datetime 值带时区后缀（前端传 ISO 8601 `...Z` 是常态）。`insert`/`upsert`/`align` 走 `VALUES` 字面量不加 cast，不受影响。列由 `resty.migrate` 建成 `timestamp(0) with time zone`（`timezone = true`），而 CTE 里的转换是 `'2024-01-01 00:00:00+00:00'::timestamp`，PG 对 `timestamp without time zone` 会**忽略偏移**，再隐式转成 `timestamptz` 时按会话时区解释。
- 后果：同一个值走 `insert` 存成 `08:00:00+08`，走 `updates` 存成 `00:00:00+08`，差一个时区偏移量（本地 8 小时）。派单超时、有效期判断整体偏移。
- 复现（已复现，`scratchpad/verify2.lua` 第 10 段）：

```lua
local ins = ViewLog:insert { entry_id = eid, ctime = '2024-01-01T00:00:00Z' }
              :returning('id', 'ctime'):exec()[1]
-- ins.ctime == '2024-01-01 08:00:00+08'  （正确）
local up = ViewLog:updates({ { id = ins.id, ctime = '2024-01-01T00:00:00Z' } }, 'id')
              :returning('ctime'):exec()[1]
-- up.ctime == '2024-01-01 00:00:00+08'   （错了 8 小时）
ViewLog:merge({ { id = 1, entry_id = eid, ctime = '2024-01-01T00:00:00Z' } }, 'id'):statement()
-- ... VALUES (1::integer, 1::integer, '2024-01-01 00:00:00+00:00'::timestamp) ...
```

### B5 [中] NULL 列在结果里缺键，compact/flat 路径下列错位

- 位置：pgmoon `init.lua:831`（`convert_null = false` 时 NULL 列**不写入**结果表）；ORM 从不设置 `convert_null`；`lib/model/sql.lua:2957-2970`（`values_list`）、`2931-2941`（`flat`）、`3179`（`as_set`）、`3000-3041`（`dates/datetimes`）都依赖 compact 数组的位置语义
- 触发条件：被选列含 NULL。
- 后果：`values_list({'id','rating'})` 对 NULL 行返回 `{1}`（长度 1）而不是 `{1, nil}`；`values_list('rating', {flat=true})` 返回的元素数少于行数，与同序的 `id` 列表对不上；`record.rating == nil` 无法区分「列没选」和「值为 NULL」；对外 JSON 序列化时字段直接消失而不是 `null`。
- 复现（已复现，第 7 段）：

```lua
Entry.query("UPDATE entry SET rating = NULL WHERE id = (SELECT min(id) FROM entry)")
local vl = Entry:order('id'):values_list({ 'id', 'rating' })
-- vl[1] == {1}，#vl[1] == 1；vl[2] == {2, 5}
local flat = Entry:order('id'):values_list('rating', { flat = true })
-- #flat == 2，Entry:count() == 3
```

### B6 [中] `validate_create` 把 table 型 default 直接放进数据，跨请求共享同一个表

- 位置：`lib/model/init.lua:1169-1171`（`value = field.default`，没有走 `field:get_default()`；后者会 `clone`）
- 触发条件：字段 default 是 table（array/json/table 字段常见），调用 `Model:create`/`validate_create`/`insert` 时该字段留空，随后调用方修改返回记录里的这个字段（`rec.tags:push(x)`、`rec.payload.k = v`）。
- 后果：修改写回了字段定义上的 default 表，本 worker 后续所有创建都带上这次的修改，直到进程重启。属于跨请求状态泄漏，且极难定位。
- 复现（已复现，第 6 段）：

```lua
local Tmp = Model:create_model {
  table_name = 'tmp', fields = { { 'tags', type = 'array', default = { 'a' } } } }
local d1 = Tmp:validate_create({ x = 1 }); d1.tags[#d1.tags + 1] = 'LEAK'
local d2 = Tmp:validate_create({ x = 1 })
-- table.concat(d2.tags, ',') == 'a,LEAK'；d1.tags == d2.tags 为 true
```

### B7 [中] `get_or_create` 不做字段校验也不做 `prepare_for_db`，值直接进 `as_literal`

- 位置：`lib/model/sql.lua:3333-3373`（只检查字段名存在，`_get_insert_values_token` 直接取原值）。对照 `update_or_create`（`3385-3415`）走了 `validate_update` + `_prepare_db_rows`。
- 触发条件：`params`/`defaults` 含 json/array/table/datetime/foreignkey 字段，或整数字段传 `""`，或字符串字段依赖 `compact/trim`。
- 后果：json 对象 → `error("empty table is not allowed")`；json 数组 `{1,2}` → 渲染成行值 `(1, 2)` → PG 报错或写错列；整数 `""` → `''` 字面量 → PG `invalid input syntax for type integer`；字符串未经 `compact/trim` → 唯一键查找与 `create` 路径不一致（`' 张三'` 与 `'张三'` 被当作两条）。同一份输入 `create` 能过、`get_or_create` 报 500。
- 复现（已复现，第 2 段）：

```lua
Author:get_or_create({ name = 'x' }, { payload = { a = 1 } })  -- error: empty table is not allowed
Author:get_or_create({ name = 'x' }, { payload = { 1, 2 } })   -- VALUES ((1, 2), 'x') 进库报错
Author:get_or_create({ name = 'x' }, { age = '' })             -- VALUES ('', 'x')
```

### B8 [中] `where{col = ngx.null}` 生成 `col = NULL`，恒假

- 位置：`lib/model/expr.lua:42-44`（`eq` 处理器不区分 NULL）、`lib/model/sql.lua:1300-1310`
- 触发条件：调用方用 `Model.NULL`/`ngx.null` 表示「为空」做筛选或更新条件（Django 语义下 `col=None` 会转成 `IS NULL`，从 Django 迁移的开发者会这么写）。
- 后果：查询返回空集、`update ... where{x = NULL}` 更新 0 行，无任何报错。`ne` 同理（`<> NULL` 恒为未知）。
- 复现（已复现，第 3 段）：`Entry:where { rating = NULL }:statement()` → `... WHERE T.rating = NULL`；实际库中有 NULL 行时 `count()` 为 0。

### B9 [中] `meta_query` 接受字符串 `where`/`get`/`try_get`，原样拼进 SQL

- 位置：`lib/model/sql.lua:3465-3480`（`meta_query` 把 `data[arg_name]` 直接 `unpack` 给同名方法）；`lib/model/sql.lua:2256-2270` + `755-772`（`where` 的字符串分支就是裸 SQL）
- 触发条件：应用把请求体/查询参数（JSON）整体传给 `meta_query`。这个方法的定位就是「声明式查询」，文档示例全是 table，但类型上没有拦截字符串。pgmoon 走简单查询协议，`;` 分隔的多语句会被一起执行。
- 后果：SQL 注入，可读任意表、可执行 DDL/DML（`where = "1=1; DELETE FROM ..."`）。
- 复现（已复现，第 5 段）：

```lua
Blog:meta_query { where = "1=1 OR (SELECT pg_sleep(0)) IS NULL", select = { 'id' } }
-- 正常执行，返回全表
Blog:create_sql():where("name = 'a' OR 1=1"):statement()
-- SELECT * FROM blog T WHERE name = 'a' OR 1=1
```

注意：`where(string)` 本身是有意提供的裸 SQL 入口，问题只在 `meta_query` 没有把「数据」和「代码」分开。

### B10 [中] 事务 callback 内经 `coroutine.wrap/create` 发出的查询逃逸事务

- 位置：`lib/model/query.lua:334-345`（事务连接按 `coroutine.running()` 索引）
- 触发条件：callback 内使用任何基于协程的迭代器/生成器/第三方库（用户自己的 `coroutine.wrap` 迭代器、某些模板/流式处理库），在协程内部调用 ORM。
- 后果：协程内的查询拿到新连接、自动提交，事务回滚时它不回滚，形成部分提交。
- 复现（已复现，第 9 段）：

```lua
pcall(function()
  Blog:transaction(function()
    Blog:insert { name = 'tx-co-main' }:exec()
    coroutine.wrap(function() Blog:insert { name = 'tx-co-inner' }:exec() end)()
    error("boom")
  end)
end)
-- 'tx-co-main' 不存在（已回滚），'tx-co-inner' 存在（逃逸）
```

按协程隔离是为了让 `ngx.thread.spawn` 的轻线程各自拿连接、避免并发共用一个 socket（注释里写明了），这个取舍本身合理，但代价没有在文档里说明，也没有给「显式绑定连接」的出口。

### B11 [中] 文档中的 `where(function(ctx))` / `select(function(ctx))` 在无 JOIN 时 `ctx` 为 nil

- 位置：`lib/model/sql.lua:763`、`925`、`1574`（三处回调都直接传 `self._join_proxy_models`，没有先 `_ensure_context()`；`_join_proxy_models` 只在 `_handle_manual_join` 时初始化）；文档 `docs/orm-query-basics.md:31`、`240` 恰好给的就是无 JOIN 的示例
- 触发条件：按文档在一个还没有触发自动 JOIN 的 builder 上用回调形式。
- 后果：`attempt to index local 'ctx' (a nil value)`。
- 复现（已复现，第 12 段）：`Blog:where(function(ctx) return ctx[1].name .. " = 'x'" end):statement()` 抛错。

### B12 [低] `in_bulk({})` 返回全表

- 位置：`lib/model/sql.lua:3165-3176`（`#ids > 0` 才加 `__in`，空表等同于不传）
- 触发条件：调用方把请求里的 id 列表（可能为空）直接传入。
- 后果：一次请求拉整张表；政务库的大表上是明显的性能/DoS 面。Django 的 `in_bulk([])` 返回 `{}`。
- 复现（已复现，第 4 段）：`Blog:in_bulk({})` 返回 2 条（全部）。

### B13 [低] JSON 字段的空数组往返后变成空对象

- 位置：`lib/model/fields.lua:1391-1400`（`JsonField.prepare_for_db` → `cjson.safe.encode`，空表默认编码为 `{}`）；pgmoon `json.lua`（`decode` 未启用 `array_mt`，`[]` 解码成普通空表）
- 触发条件：JSON 字段里任意层级出现空数组；或读出后原样写回。
- 后果：`{"tags":[]}` 变 `{"tags":{}}`，前端按数组处理时崩；数据结构漂移。`array`/`table` 顶层字段不受影响（有 `encode_as_array`）。
- 复现（已复现，第 11 段）：写入 `{ tags = {} }` 库里是 `{"tags": {}}`；库里手工放 `{"tags":[]}`，`get` 后 `update` 写回变成 `{"tags": {}}`。

### B14 [低] 文档写 `local result, err = Blog:transaction(...)`，实现是抛错

- 位置：`docs/orm-model-definition.md:645`；`lib/model/query.lua:380-411`（失败一律 `error`，绝不返回 `nil, err`）
- 后果：按文档写 `if err then ... end` 的分支永远不执行；错误直接上抛，行为本身是对的，但文档误导调用方以为可以就地处理。

### B15 [低] `Sql:update(row)` 类型注解允许 `string|function`，实现只接受 table

- 位置：`lib/model/sql.lua:2619-2634`（`pairs(row)`）；注解 `sql.lua:136`
- 后果：`Blog:update("tagline = 'x'")` 报 `bad argument #1 to 'pairs'`。`_base_update` 支持字符串，公开方法不支持，改注解。

### B16 [低] `where('col', nil)` 退化为单参裸 SQL

- 位置：`lib/model/sql.lua:1317-1323`（`op == nil` 分支按「一参」处理）
- 触发条件：两参形式的值来自可能为 nil 的变量。
- 后果：生成 `WHERE name`：varchar 列 PG 报类型错误（可见），boolean 列则静默变成 `WHERE flag`（筛选语义改变）。
- 复现（已复现）：`Blog:where('name', nil):statement()` → `SELECT * FROM blog T WHERE name`。

### B17 [低] `get()` 命中多行时返回 `false`，与「不存在」无法区分

- 位置：`lib/model/sql.lua:3055-3070`（`limit(2)` 后 `#records == 1` 才返回，`try_get` 是同一函数）
- 后果：`local r = Blog:get{...}; if not r then create() end` 在数据已重复时再创建一条，越修越多。Django 分别抛 `DoesNotExist`/`MultipleObjectsReturned`。这是设计取舍，但两种情况用同一个返回值确实会掩盖数据问题。

---

## 3. 疑似问题（未能完全确认或依赖部署配置）

### S1 [中] 事务 callback 内调用 `ngx.exit`/`ngx.eof` 会让事务既不提交也不回滚

- 位置：`lib/model/query.lua:396`（`xpcall(callback, ...)`）
- 依据：OpenResty 的 `ngx.exit` 在 content 阶段通过 `lua_yield` 实现，LuaJIT 允许跨 `pcall/xpcall` yield，所以 `xpcall` 不会返回，`COMMIT`/`ROLLBACK`/`release` 都不执行；请求结束时 nginx 关闭未归还的 cosocket，PG 侧回滚。结果是「处理函数写完响应并 `ngx.exit(200)`，事务却没提交」。
- 未复现原因：本次只在 `resty` CLI（timer 上下文）验证，`ngx.exit` 语义与 content 阶段不同。需要起一个 nginx 用 `atomic` 包一个调 `ngx.exit` 的 handler 验证。
- 建议：至少在文档明示；`atomic` 包装层可以在进入前记录 `ngx.ctx`，`log_by_lua` 阶段检查未收尾的事务并告警。

### S2 [中] 转义安全依赖 `standard_conforming_strings = on`

- 位置：`lib/model/utils.lua:481`（只转义 `'`）、`lib/model/expr.lua`（LIKE 用 `ESCAPE '\'`、正则值只转义 `'`）；`lib/model/query.lua:288-310` 有一段被注释掉的强制 `SET standard_conforming_strings = on`
- 依据：该参数为 `off` 时 `\'` 可逃逸字符串字面量（注入），`ESCAPE '\'` 语义也变。本机实测为 `on`（PG 9.1 起默认），但它可以在库级/角色级被改掉，而且 `SET` 只需在新建连接上发一次（已有 `getreusedtimes()==0` 判断），代价极小。
- 建议：恢复那段强制设置，或在新建连接时 `SHOW` 并在不为 `on` 时拒绝建连。

### S3 [低] 没有执行阶段守卫，非 cosocket 阶段的错误从 pgmoon 深处抛出

- 位置：`lib/model/query.lua:263-300`（`make_conn`）、`lib/model/fields.lua:1296-1324`（`ForeignkeyField:load` 的惰性代理在属性访问时发查询）
- 依据：pgmoon 的 `socket.new` 在 `init` 阶段回落到 luasocket（本机装了 `socket` 模块，生产未必有），在 `init_worker`/`set`/`header_filter`/`body_filter`/`log` 阶段 `ngx.socket.tcp` 会报 `API disabled in the context of ...`。库本身不会主动在这些阶段查库，但惰性外键代理让「content 阶段取出的记录」在 `log_by_lua` 里做审计序列化时触发查询，错误信息指向 pgmoon 内部，很难定位。
- 未复现原因：需要 nginx 多阶段环境。
- 建议：`send_query` 入口检查 `ngx.get_phase()`，非 `rewrite/access/content/timer/ssl_*/preread` 直接抛出明确错误；惰性外键加载改为显式（`select_related`）或加开关。

### S4 [低] 连接数无上限、服务端超时默认不下发，高并发下容易打爆 PG

- 位置：`lib/model/query.lua:132`（`pool_size` 默认 100）、`139`（`backlog` 默认 nil）、`135`（`statement_timeout` 默认不下发）
- 依据：cosocket 的 `pool_size` 只限制**空闲**连接数；不设 `backlog` 时并发峰值会无限制新建连接。8 个 worker × 峰值并发很容易越过 PG `max_connections`（默认 100），报 `too many clients`。同时客户端超时不发 cancel，超时后的查询继续在 PG 上跑，慢查询风暴时会堆积。文档已经解释了机制，但默认值对「高并发 API」不安全。这是容量配置而非代码缺陷，故列为疑似。

### S5 [低] 外键惰性代理上模型属性遮蔽同名列

- 位置：`lib/model/fields.lua:1299-1303`（先查 `fk_model[key]` 再查 `fk_model.fields[key]`）
- 依据：被引用模型若有名为 `label`、`admin`、`preload`、`names` 等的列（`RESERVED_FIELD_NAMES` 只拦了一部分），`record.fk.label` 拿到的是模型的 label 而不是行值。实测 `e.blog_id.label` 返回 `'blog'`（模型 label），只是 Blog 没有 `label` 列所以不构成错误。有这类列名的模型会静默读错。

### S6 [低] `_prepend/_append` 的结果集定位假设每个前置语句恰好产生一个结果集

- 位置：`lib/model/sql.lua:2770-2776`（`records[#self._prepend + 1]`）
- 依据：前置项若是含 `;` 的字符串、或空语句（PG 返回 `EmptyQueryResponse`，pgmoon 不计数），下标会偏移，主语句结果被当成别的。现有调用点（`save_cascade_update`）都传 Sql 对象，不会触发；只有外部用 `prepend(string)` 时有风险。

---

## 4. 各专项检查结论

### 连接管理

- 出错路径：PG 报错（有 `ReadyForQuery`）后归还连接是安全的；**传输层错误后归还是不安全的**（B1）。`make_conn` 内 `connect` 失败无需归还，`SET statement_timeout` 失败时正确地 `disconnect` 了。
- 事务未结束的连接：正常路径 `COMMIT`/`ROLLBACK` 都有 `pcall` 兜底后再 `release`，逻辑对；但 aborted 事务的 `COMMIT` 假成功（B2）、传输错误后的 `ROLLBACK` 读脏数据（B1）、`ngx.exit` 中断（S1）三种情况会留下语义错误的连接或未收尾的事务。pgmoon 没有暴露 `ReadyForQuery` 里的事务状态字节（`I`/`T`/`E`），ORM 目前无法在归还前核对「连接确实处于 idle」。
- 超时：`CONNECT_TIMEOUT` 只管握手、`QUERY_TIMEOUT` 管收包、`STATEMENT_TIMEOUT` 走服务端，拆分是合理的；默认 10 s 的客户端超时对 API 偏长，且 `STATEMENT_TIMEOUT` 默认不下发意味着超时后查询继续烧 PG（S4）。`MAX_IDLE_TIMEOUT` 10 s 合理。

### 请求隔离

- 模块级状态：`query_cache`、`ENV`、`warned_legacy_timeout`、`method_cache`、`ALIOSS_*` 都是只读或幂等缓存，安全。`txn_conns` 按协程弱键索引，请求间隔离正确（协程逃逸见 B10）。
- 会串数据的点：B1（连接池）、B6（default 表共享）。
- 需要提醒的用法：`Sql` builder 是可变对象，`count/first/last/get/exists/values_list/flat` 这些「终结」方法都会改写 `_select/_order/_limit/_where`，模块级复用一个 builder（`local base = Blog:where{...}`）会在请求间累积条件。`all()` 返回副本可以规避，但没有强制。

### 执行阶段

- 库内没有任何在 `init`/`header_filter`/`log` 阶段主动查库的代码；`Model:create_model` 和 `Query()` 都是惰性的，不在定义期建连（做得对）。风险只来自惰性外键代理（S3）。

### SQL 拼接

- 列名：所有经 `parser.lua` 的路径都对字段名/操作符做白名单，未知段报错；`select_as`/`annotate` 的别名走 `smart_quote`；`with_values`/`merge_gets` 校验标识符。这部分是可靠的。
- 值：`as_literal` 对字符串转义 `'`，数字 `tostring`（B3），布尔/NULL/子查询/数组各有处理。裸 SQL 入口（`where(string)`、`from`、`using`、`with(name, string)`、回调形式）是有意保留的，文档需标明「不可接受用户输入」。
- 注入面：`meta_query`（B9）。其余公开方法未发现可从值参数逃逸的路径。`__regex` 值有长度和嵌套量词的粗过滤，够用。

### 数据转换

- `ngx.null` 与 `nil`：写入方向区分正确（`NULL` → `'NULL'`，`nil` → 不写/`DEFAULT`）；读回方向 NULL 变成缺键（B5）；条件方向 `NULL` 不转 `IS NULL`（B8）。
- 大整数：B3。
- 空结果：`exec` 返回空 `Array`，`get` 返回 `false`，`first/last` 返回 `nil`，`aggregate` 返回 `{}`，一致。
- 多结果集：只在 `_prepend/_append` 路径出现，`return_all()` 可拿全部；定位规则脆弱（S6）。
- datetime：B4；另外 `ctime` 用 `ngx.localtime()`（应用时钟）而 `utime` 用 `CURRENT_TIMESTAMP`（数据库时钟，事务开始时刻），两列时钟源不同，跨机部署时可能出现 `utime < ctime`。列为设计注意点，不算 bug。

### 错误处理

- 约定实际上是统一的：**一律抛错**。查询失败抛字符串（带 `query.lua:230:` 前缀和 PG 位置），校验失败抛 `field_error` 表，事务用 `error(x, 0)` 原样重抛，`field_error` 表能穿透事务（已实测）。只有 `get/try_get`（返回 `false`）和 `first/last`（返回 `nil`）是「找不到不算错」。
- 不一致处：`exists()` 和 `explain()` 里 `if res == nil then error(err)` 是死分支（`model.query` 从不返回 nil）；`ConnProxy:release` 返回 `ok, err`（内部用）；文档 B14。`try_get` 与 `get` 完全同名不同义地共存容易误解（都返回 false）。

---

## 5. 设计建议

每条给出：现状问题、改法、代价、是否破坏现有接口。

### D1 连接健康状态显式化，归还前核对

- 现状：`release()` 只看 `sock_type`，不知道这条连接刚经历了什么（B1、B2）。
- 改法：`ConnProxy` 增加两个状态位。`broken`：`conn:query` 返回值第 3 位（`num_queries`）不是 number，说明没等到 `ReadyForQuery`，是传输层错误 → 置位。`aborted`：在事务中收到 PG 错误 → 置位。`release()` 遇到 `broken` 改为 `disconnect()`；`transaction()` 遇到 `aborted` 主动 `ROLLBACK` 并抛 `transaction aborted by earlier error: <原错误>`。进一步，给 pgmoon（仓库用的是 `xiangnanscu/pgmoon` fork）加一行记录 `ReadyForQuery` 的状态字节，`release()` 时若状态不是 `I` 一律 `disconnect`，这才是根本的兜底。
- 代价：每次查询多两次表写；pgmoon 改动一行。
- 接口：不破坏。B2 修复后，原本「假成功」的事务会开始抛错，这是修正而不是破坏，但上线前要通知调用方。

### D3 NULL 的读回策略

- 现状：NULL 缺键（B5），API 输出丢字段，compact 路径错位。
- 改法：分两档。第一档（默认开）：`ConnProxy:query` 在 `compact = true` 时把 `conn.convert_null` 同步置为 `true`，让 `values_list/flat/dates` 等位置敏感的路径拿到 `ngx.null` 占位，`Array:flat` 保留占位。第二档（可选，`Query` 选项 `CONVERT_NULL`）：非 compact 也转 `ngx.null`，配合 cjson 输出 `null`。同时 `eq/ne` 处理器把 `ngx.null` 映射为 `IS NULL/IS NOT NULL`（B8）。
- 代价：第二档会改变 `if rec.x then` 的真值语义（`ngx.null` 为真），必须由业务方自行选择开启。
- 接口：第一档不破坏（当前输出本来就是错的）；第二档破坏，故做成开关。

### D4 整数字面量与 bigint 策略

- 现状：B3。
- 改法：`as_literal` 对 number 分支：整数且 `|v| < 2^53` 用 `string.format("%d", v)`（LuaJIT 支持 64 位整数格式化）；`|v| >= 2^53` 抛错（double 已经不精确，与其静默不如报错）；`nan/inf` 抛错；增加对 `cdata` int64（`ffi.istype("int64_t")`）的支持，输出去掉 `LL` 后缀。读回方向：`IntegerField` 增加 `db_type = 'bigint'` 时的 `load` 钩子，或给 pgmoon `set_type_deserializer(20, ...)` 让 int8 按字符串/int64 cdata 返回，作为 `Query` 选项。
- 代价：读回方向是行为变化，做成选项。
- 接口：写入方向不破坏（原输出对 15 位以上整数本来就是错的）；读回方向是选项。

### D5 CTE 类型后缀改用独立的 cast token

- 现状：`_array_to_values` 用 `field.db_type` 做 cast（B4），而 `db_type` 同时被 `resty.migrate` 用来比较 schema，两者语义耦合。
- 改法：Field 增加 `get_cast_type()`（默认返回 `db_type`），`DatetimeField`/`TimeField` 根据 `timezone` 返回 `timestamptz`/`timetz`；`_array_to_values` 改调它。
- 代价：极小。
- 接口：不破坏。

### D6 `meta_query` 只接受数据

- 现状：B9。
- 改法：`meta_query` 入口对 `where/get/try_get/having` 强制 `type == 'table'`，对 `select/order/group/distinct/flat` 的每个元素强制 `type == 'string'`（它们本来会经 `parse_column` 校验），对 `limit/offset` 强制 number 或数字字符串；否则抛错。
- 代价：无。
- 接口：不破坏文档用法（示例全是 table）。

### D7 `get_or_create` 与 `update_or_create` 同一套校验

- 现状：B7。
- 改法：`get_or_create` 在拼 token 前对 `dict(params, defaults)` 走 `validate_update` + `_prepare_db_rows`（尊重 `skip_validate`），与 `update_or_create` 对齐。
- 代价：多一次校验；以前能「混过去」的脏值会开始报 `field_error`。
- 接口：不破坏签名；行为更严格。

### D8 终结方法在副本上执行

- 现状：`count/exists/first/last/get/values_list/flat/dates/datetimes` 改写 builder 自身，复用 builder 会串条件。
- 改法：这些方法开头 `self = self:copy()`（`copy` 已存在，浅拷贝）。
- 代价：每次终结调用多一次表拷贝（十几个键），可忽略。
- 接口：返回值不变；唯一变化是「调用 `count()` 后再 `exec()` 同一个 builder」不再返回 count 行，这本来就是误用。

### D9 阶段守卫与惰性外键加载显式化

- 现状：S3。
- 改法：`send_query` 开头检查 `ngx.get_phase()`；`ForeignkeyField:load` 的按需查询加 `Model.LAZY_FK` 开关（默认沿用现状，文档标明），或在非允许阶段抛清晰错误。
- 代价：每次查询一次 `get_phase()` 调用。
- 接口：不破坏。

### D10 连接池默认值面向高并发

- 现状：S4。
- 改法：`BACKLOG` 默认给值（如 `pool_size`），文档给出「`pool_size × worker 数 ≤ max_connections × 0.8`」的配比；`STATEMENT_TIMEOUT` 默认取 `QUERY_TIMEOUT - 2000`（保证服务端先 cancel）。`Query()` 按 `pool_name` 命中缓存时若传入的 timeout/pool_size 与缓存不同，记一次 WARN。
- 代价：配置语义变化需要在升级说明里写清。
- 接口：默认值变化，属于行为变化但不破坏调用代码。

### D11 `default_query` 代理去掉每次查询的重复构造

- 现状：`init.lua:317-324` 每次 `Model.query(...)` 都调 `get_query({})` → `Query({})` → `get_connect_table` 重新读 env、拼 `pool_name`，是最热路径上的无谓开销。
- 改法：首次成功后把结果 `rawset` 到代理上，或用 upvalue 缓存。
- 代价：无。
- 接口：不破坏。

### D12 文档修正

- `transaction` 返回约定（B14）；`get` 多行返回 `false` 的说明（B17）；`values_list`/`flat` 遇 NULL 的行为（B5，修复前后都要写）；裸 SQL 入口（`where(string)`、`from`、`with(name, string)`、回调）不可接受用户输入；`atomic` 内不要 `ngx.exit`（S1）；`transaction` 内协程逃逸（B10）。

---

## 6. 修改任务清单

按执行顺序排列。验收统一用现有测试命令：

```sh
LUA_PATH='...' resty -I lib -I spec --main-conf 'env NODE_ENV;' bin/ngx_busted.lua -o TAP
```

（即 `package.json` 的 `test` 脚本；需要本机 PG 上存在 `test` 库、`postgres/postgres` 账号，与 `spec/model_spec.lua` 一致。）

| 编号 | 优先级 | 涉及文件                                                                 | 依赖   |
| ---- | ------ | ------------------------------------------------------------------------ | ------ |
| T0   | P0     | `spec/review_spec.lua`（新建）                                           | 无     |
| T1   | P0     | `lib/model/query.lua`                                                    | T0     |
| T2   | P1     | `lib/model/query.lua`                                                    | T1     |
| T3   | P1     | `lib/model/sql.lua`                                                      | T0     |
| T4   | P1     | `lib/model/utils.lua`、`lib/model/query.lua`、`lib/model/fields.lua`     | T0     |
| T5   | P1     | `lib/model/fields.lua`、`lib/model/sql.lua`                              | T0     |
| T6   | P2     | `lib/model/init.lua`                                                     | T0     |
| T7   | P2     | `lib/model/sql.lua`                                                      | T0     |
| T8   | P2     | `lib/model/expr.lua`                                                     | T0     |
| T9   | P2     | `lib/model/query.lua`、`lib/model/sql.lua`                               | T1     |
| T10  | P2     | `lib/model/sql.lua`                                                      | T0     |
| T11  | P3     | `lib/model/sql.lua`                                                      | T0     |
| T12  | P3     | `lib/model/fields.lua`、`lib/model/validator.lua`、`lib/model/query.lua` | T0     |
| T13  | P3     | `lib/model/query.lua`                                                    | T1     |
| T14  | P3     | `lib/model/query.lua`、`docs/orm-index.md`                               | T1     |
| T15  | P3     | `lib/model/sql.lua`                                                      | T0     |
| T16  | P3     | `docs/orm-*.md`                                                          | T1–T15 |

### T0 为已确认 bug 补回归测试

- 优先级：P0
- 涉及文件：新建 `spec/review_spec.lua`（复用 `spec/model_spec.lua` 导出的模型；需要 DB）
- 问题描述：B1–B13、B16 都没有现有用例覆盖。后续任务以「对应用例由红转绿」为完成标准。
- 修改方案：每个 bug 一个 `it`，用例名带编号。要点：
  - B1：用独立 `POOL_NAME` 和 `QUERY_TIMEOUT = 1500` 的 `Query`，先 `pcall` 一条 `pg_sleep(2)` 超时，立即查 `SELECT 'SECOND' AS marker`，断言 `marker == 'SECOND'`；再断言两次 `pg_backend_pid()` 不同（脏连接必须被关闭）。事务路径同样写一条。
  - B2：callback 内 `pcall` 吞掉唯一冲突后正常返回，断言 `transaction()` 抛错且错误信息含 `aborted`，断言行未落库。
  - B3：断言 `as_literal(123456789012345678)` 等于 `'123456789012345678'`；`as_literal(2^53)` 抛错或精确；`as_literal(0/0)` 抛错。
  - B4：`ViewLog` 用 `insert` 与 `updates` 各写一次 `'2024-01-01T00:00:00Z'`，断言两次 `returning('ctime')` 相等。
  - B5：把一行 `rating` 置 NULL 后，断言 `values_list({'id','rating'})` 每行长度为 2 且 NULL 位是 `ngx.null`；`values_list('rating',{flat=true})` 长度等于 `count()`。
  - B6：两次 `validate_create` 返回的 default 表不是同一个对象。
  - B7：`Author:get_or_create({name='goc-json'}, {payload={a=1}})` 成功且 `payload.a == 1`；`{age=''}` 写入 NULL 而不是报错。
  - B8：`Entry:where{rating = Model.NULL}:count()` 等于 `Entry:where{rating__isnull=true}:count()`。
  - B9：`Blog:meta_query{ where = "1=1" }` 抛错；`get = "1=1"` 抛错。
  - B10：作为文档化行为写「已知限制」用例。
  - B11：`Blog:where(function(ctx) return ctx[1].name .. " = 'First Blog'" end):get()` 返回记录。
  - B12：`Blog:in_bulk({})` 返回空表。
  - B13：`payload = { tags = {} }` 写入后 `payload::text` 含 `"tags": []`。
  - B16：`Blog:where('name', nil)` 抛错。
- 验收标准：新增用例在未修改代码前全部失败（红），现有 263 例仍全部通过。
- 前置任务：无。

### T1 传输层错误后关闭连接而不是归还（B1）

- 优先级：P0
- 涉及文件：`lib/model/query.lua`
- 问题描述：见 B1。
- 修改方案：`ConnProxy:query` 保留 pgmoon 的完整返回值，`result == nil` 时若第 3 个返回值（`num_queries`）不是 number，置 `self.broken = true`；`release()` 在 `broken` 时改调 `disconnect()`（`pcall` 包住，失败只记日志）。`transaction()` 的错误分支在 `conn.broken` 时跳过 `rollback` 直接 `release`。可选：在 pgmoon fork 的 `receive_query_result` 里记录 `ReadyForQuery` 状态字节到 `self.txn_status`，`release()` 时 `txn_status ~= 'I'` 一律 `disconnect`。
- 验收标准：T0 的 B1 用例通过（第二条查询拿到自己的 marker，backend pid 变化）；现有事务用例通过。
- 前置任务：T0。

### T2 事务内出错后禁止提交（B2）

- 优先级：P1
- 涉及文件：`lib/model/query.lua`
- 问题描述：见 B2。
- 修改方案：`ConnProxy:query` 在 `self.in_transaction` 为真且 pgmoon 返回 PG 错误时置 `self.aborted = true`。`transaction()` 在 callback 正常返回后先检查 `conn.aborted`：为真则 `pcall(rollback)`、`release`，再 `error("transaction aborted by earlier error: " .. first_error, 0)`（首个错误在置位时一并记下）。`begin()` 置 `in_transaction = true`，`commit/rollback` 后清零。
- 验收标准：T0 的 B2 用例通过；`model_spec` 第 28 组事务用例通过。
- 前置任务：T1（同一处状态机）。

### T3 `meta_query` 拒绝非数据类型（B9）

- 优先级：P1
- 涉及文件：`lib/model/sql.lua`
- 问题描述：见 B9。
- 修改方案：按 D6 加类型白名单；错误信息指明字段名与期望类型。
- 验收标准：T0 的 B9 用例通过；`model_spec` 中所有 `meta_query` 用例通过。
- 前置任务：T0。

### T4 整数字面量精确渲染与 bigint 读回选项（B3）

- 优先级：P1
- 涉及文件：`lib/model/utils.lua`（`_escape_factory`）、`lib/model/query.lua`（pgmoon 反序列化选项）、`lib/model/fields.lua`（`IntegerField` 的 `bigint` 支持）
- 问题描述：见 B3。
- 修改方案：按 D4。写入侧无条件修复；读回侧新增 `Query` 选项 `BIGINT_AS_STRING`（默认关）。
- 验收标准：T0 的 B3 用例通过；`bug_spec` 全部通过（其中有大量 `statement()` 字符串断言，注意整数渲染不能出现多余的 `.0`）。
- 前置任务：T0。

### T5 datetime CTE 类型后缀（B4）

- 优先级：P1
- 涉及文件：`lib/model/fields.lua`（`get_cast_type`）、`lib/model/sql.lua:1652`
- 问题描述：见 B4。
- 修改方案：按 D5。不要改 `db_type` 本身（`resty.migrate` 依赖它）。
- 验收标准：T0 的 B4 用例通过；`model_spec` 的 merge/updates/gets/merge_gets 用例通过。
- 前置任务：T0。

### T6 `validate_create` 使用 `get_default()`（B6）

- 优先级：P2
- 涉及文件：`lib/model/init.lua:1169-1179`
- 问题描述：见 B6。
- 修改方案：`elseif field.default ~= nil and (value == nil or value == "") then value, err = field:get_default()`，保留对函数返回 `nil, err` 的处理。
- 验收标准：T0 的 B6 用例通过；`model_spec` 第 26 组校验用例通过。
- 前置任务：T0。

### T7 `get_or_create` 走校验与 `prepare_for_db`（B7）

- 优先级：P2
- 涉及文件：`lib/model/sql.lua:3333-3373`
- 问题描述：见 B7。
- 修改方案：按 D7。
- 验收标准：T0 的 B7 用例通过；`model_spec` 第 15 组用例通过。
- 前置任务：T0。

### T8 `NULL` 条件映射为 `IS NULL`（B8）

- 优先级：P2
- 涉及文件：`lib/model/expr.lua`（`eq`、`ne`）
- 问题描述：见 B8。
- 修改方案：`eq`：`value == NULL` 时返回 `key IS NULL`；`ne`：返回 `key IS NOT NULL`。`in` 列表里的 NULL 保持原样（SQL 语义如此）。
- 验收标准：T0 的 B8 用例通过；`bug_spec`、`model_spec` 第 3 组 WHERE 用例通过。
- 前置任务：T0。

### T9 compact 查询下 NULL 占位（B5）

- 优先级：P2
- 涉及文件：`lib/model/query.lua`（`ConnProxy:query` 同步 `convert_null`）、`lib/model/sql.lua`（`values_list/flat` 对 `ngx.null` 的处理）
- 问题描述：见 B5。
- 修改方案：按 D3 第一档；第二档作为 `Query` 选项 `CONVERT_NULL`。
- 验收标准：T0 的 B5 用例通过；`model_spec` 第 18 组 flat/values 用例通过；`count()`、`exists()` 返回值类型不变。
- 前置任务：T1（同一函数）。

### T10 回调形式前初始化 JOIN 上下文（B11）

- 优先级：P2
- 涉及文件：`lib/model/sql.lua:763`、`925`、`1574`
- 问题描述：见 B11。
- 修改方案：三处在调用回调前 `self:_ensure_context()`。
- 验收标准：T0 的 B11 用例通过；`model_spec` 全部通过。
- 前置任务：T0。

### T11 `in_bulk({})`、`where(col, nil)`、`update(string)`（B12、B16、B15）

- 优先级：P3
- 涉及文件：`lib/model/sql.lua`
- 问题描述：见 B12、B16、B15。
- 修改方案：`in_bulk`：`ids ~= nil and #ids == 0` 直接返回 `{}`。`where`：改用 `select('#', ...)` 判断参数个数，两参形式值为 nil 时抛错。`update`：就是应该只接受 table，改注解。
- 验收标准：T0 的 B12、B16 用例通过；文档 `in_bulk()` 不传参返回全集的行为保持。
- 前置任务：T0。

### T12 JSON 空数组往返（B13）

- 优先级：P3
- 涉及文件：`lib/model/validator.lua`（`encode/decode` 改用独立 cjson 实例，`encode_empty_table_as_object(false)` 仅对标记为数组的表）、`lib/model/query.lua`（给 pgmoon `set_type_deserializer('json', ...)` 用 `decode_array_with_array_mt(true)` 的实例）
- 问题描述：见 B13。
- 修改方案：ORM 内部用 `require("cjson").new()` 创建独立实例，避免改全局 cjson 配置影响应用其它部分。
- 验收标准：T0 的 B13 用例通过；`model_spec` 第 25 组 JSON 用例通过。
- 前置任务：T0。

### T13 `standard_conforming_strings` 强制（S2）

- 优先级：P3
- 涉及文件：`lib/model/query.lua:288-310`
- 问题描述：见 S2。
- 修改方案：恢复注释掉的 `SET standard_conforming_strings = on`，与 `statement_timeout` 合并成一条 `SET` 语句（一次往返），仅在 `getreusedtimes() == 0` 时发。
- 验收标准：新增用例：新建连接后 `SHOW standard_conforming_strings` 为 `on`；全量测试通过。
- 前置任务：T1。

### T14 阶段守卫与连接池默认值（S3、S4）

- 优先级：P3
- 涉及文件：`lib/model/query.lua`、`docs/orm-index.md`
- 问题描述：见 S3、S4。
- 修改方案：按 D9、D10。
- 验收标准：新增用例：在 `init_worker` 直接调用 `Blog:count()` 得到含 `phase` 字样的明确错误（需 nginx 环境，可先以文档说明代替）；`Query()` 缓存命中且参数不同时日志出现 WARN。
- 前置任务：T1。

### T15 终结方法在副本上执行（D8）

- 优先级：P3
- 涉及文件：`lib/model/sql.lua`
- 问题描述：见「请求隔离」小节与 D8。
- 修改方案：`count/exists/first/last/get/values_list/flat/dates/datetimes/aggregate` 开头 `self = self:copy()`。
- 验收标准：新增用例：`local q = Blog:where{...}; q:count(); q:exec()` 返回记录而不是 count 行；全量测试通过。
- 前置任务：T0。

### T16 文档修正（B14、B17、D12）

- 优先级：P3
- 涉及文件：`docs/orm-model-definition.md`、`docs/orm-query-basics.md`、`docs/orm-index.md`
- 问题描述：见 B14、B17、D12。
- 修改方案：改 `transaction` 示例为 `local ok, err = pcall(...)` 或直接说明抛错；`get` 多行说明；NULL 行为；裸 SQL 入口警示；`atomic` 内禁止 `ngx.exit`；协程逃逸限制。
- 验收标准：文档与 T1–T15 后的实现逐条对照无矛盾。
- 前置任务：T1–T15。

---

## 附录：复现脚本

审查时用的脚本放在会话临时目录，未纳入仓库。核心片段已内联在各条目中；整理成 `spec/review_spec.lua` 是 T0 的内容。运行方式：

```sh
resty -I lib -I spec --main-conf 'env NODE_ENV;' path/to/script.lua
```

脚本开头 `require "model_spec"` 即可拿到 `Blog/Entry/Author/ViewLog` 等模型（该文件在非 busted 下返回模型表）。B1 的复现需要独立 `POOL_NAME`，避免污染其它用例共用的连接池。

---

## 7. 执行中发现

任务执行过程中发现、但第 2 节未列出的问题记在这里（按发现顺序编号 F1、F2…）。

### F1 [高] 现有 263 例在本机并非全绿：5 例因 96ff0ff 的实现变更而失效

- 发现于：T0 开工前跑基线（`yarn test`），实际结果是 **258 ok / 5 not ok**，与第 1 节「本次运行全部通过」的记述不符。失败的 5 例：

| TAP 编号 | 用例                                                    | 报错                                                                   |
| -------- | ------------------------------------------------------- | ---------------------------------------------------------------------- |
| 18       | `bug_spec` REVIEW-B8: time/datetime 边界与负时区        | 期望 `'2023-09-24 13:41:52'`，实际 `'2023-09-24 13:41:52-08:00'`       |
| 23       | `bug_spec` REVIEW-B10d: F 表达式用于 json 字段          | `refuse to run UPDATE without WHERE on table author`                   |
| 158      | `model_spec` upsert from SELECT 子查询 (注入新 name)    | `refuse to run DELETE without WHERE on table blog_bin`                 |
| 159      | `model_spec` upsert from UPDATE+RETURNING 子查询        | `refuse to run UPDATE without WHERE on table blog_bin`                 |
| 166      | `model_spec` updates from SELECT 子查询                 | `refuse to run DELETE without WHERE on table blog_bin`                 |

- 根因（`git log -S` 定位到同一个 commit `96ff0ff`）：
  1. **全表写防呆放在了 `Sql:statement()` 里**（`sql.lua:1744`）。`statement()` 只是拼字符串，既覆盖了「只生成 SQL 不执行」的用法，也覆盖了「写操作被当作子查询/CTE 内嵌进外层语句」的用法（`Blog:upsert(BlogBin:update{...}:returning{...})`）。同时 `Model:delete()` 不传条件本来就是显式的「删全表」写法（Django 的 `.all().delete()` 同义），也被一并拦下。
  2. **`Validator.datetime` 改成保留时区偏移**，但 `bug_spec` REVIEW-B8 锁的是「返回不带偏移的规范形态」。保留偏移的动机（丢弃后 `+00:00` 会被 DB 会话时区重新解释）只对**入库**成立，而 `Validator.datetime` 同时被当作表单校验器导出。
- 处置（按 CLAUDE.md「测试不通过一律改实现代码」，既有断言语义未动）：
  1. 防呆拆成 `Sql:_check_full_table_write()`，只在 `Sql:exec()` 里调用；`Sql:delete()` 不传条件时置 `_allow_full_table`。防呆对真正的事故场景（`Model:update(row):exec()` 漏写 `:where{}`）依然生效。
  2. `validator.lua` 把解析抽成 `parse_datetime()`，分出两个口径：`datetime`（表单口径，不带偏移，恢复 `bug_spec` 锁定的契约）与 `datetime_tz`（入库口径，保留偏移）。`DatetimeField:get_validators` 与 `VALID_FOREIGN_KEY_TYPES.datetime` 改用后者，所以 B4 的前提（带偏移的值确实会进 SQL）不变。
- 改动文件：`lib/model/sql.lua`、`lib/model/validator.lua`、`lib/model/fields.lua`
- 结果：`yarn test` 从 258 ok / 5 not ok 变为 **263 ok / 13 not ok**，13 例全部是 T0 新增的红用例（见 T0 小节的完整输出）。
- 遗留：`allow_full_table()` 这个公开方法在 `docs/orm-*.md` 里没有任何说明，T16 补文档时要一并写上（包括「`delete()` 不传条件即全表」这条语义）。
