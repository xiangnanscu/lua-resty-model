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

- 状态：✅ 已完成（2026-09-19，提交见 `T0` 提交信息）
- 改动文件：`spec/review_spec.lua`（新建，13 个 `it`，用例名以 bug 编号开头）
- 实现要点：
  - 不 `require "model_spec"`：busted 下它会再跑一次 `main()`，等于重建表并重复注册 231 个用例。改为在 `review_spec.lua` 里自建 `review_blog` / `review_entry` / `review_view_log` / `review_author` 四张独立表，`POOL_NAME = 'review'` 独立连接池，`before_each` 重建种子，完全不碰 `model_spec` 的数据。
  - B1 单独用 `POOL_NAME = 'review_stale'` + `QUERY_TIMEOUT = 1500`（脏连接会留在这个池子里；这两个参数就是复现条件，不可调整），非事务与事务两条路径各断言一次「下一条查询拿到自己的结果集」+「backend pid 必须变化」。
  - 所有会抛错的路径（B1/B2/B4/B7/B9/B11/B13/B16）统一用 `pcall` 包住再断言，保证红是**断言失败**而不是未捕获的运行时错误；取结果集字段统一走 `first_field/field_of` 兜底，避免 index nil。
- 与本节原方案的差异（3 处）：
  - **B10 没有写用例**。它是「已知限制」而非待修 bug，写出来就是绿的，会让 T0「全红」的验收标准失去意义；改到 T16 的文档任务里写清（协程逃逸）。
  - **B3 的 `as_literal(123456789012345678) == '123456789012345678'` 不可能成立**：Lua number 是 double，这个 19 位整数在词法阶段就已经是 123456789012345680，任何渲染都取不回原值。用例换成三条可满足的断言：15 位整数精确渲染（`1e+14` → `100000000000000`）、`≥ 2^53` 的 number 要么精确要么报错、19 位雪花 ID 以 int64 cdata（`123456789012345678LL`）传入时精确渲染（对应 D4 的 cdata 支持）。T4 实现时按这三条来。
  - **B4 多了一条 statement 级断言**：除「`insert` 与 `updates` 落库时刻相等」外，还断言 `merge` 的 CTE 首行 cast 是 `::timestamptz`，直接锁住 D5 的改法，避免将来 cast 正确但等值断言碰巧成立时漏掉回归。
- 验收结果：13 个新增用例全部因断言失败而红，原有 263 例全绿，输出中无 skip / pending（TAP 计数 `1..276`）。

测试命令：

```sh
yarn test
# 展开后：LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' \
#   LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' \
#   resty -I lib -I spec --main-conf 'env NODE_ENV;' \
#   --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' \
#   bin/ngx_busted.lua -o TAP
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 11:21:51 [warn] 45336#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x09a259e0
	[C]: at 0x098f7230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
not ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
# spec/review_spec.lua @ 151
# Failure message: spec/review_spec.lua:168: B1: 第二条查询必须拿到自己的结果集，而不是上一条超时查询滞留的回包
# Expected objects to be the same.
# Passed in:
# (string) 'SECOND'
# Expected:
# (string) 'FROM_TIMED_OUT_QUERY'
not ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
# spec/review_spec.lua @ 188
# Failure message: spec/review_spec.lua:200: B2: 事务已 aborted 时 transaction() 必须抛错，而不是返回 callback 的返回值
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
not ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
# spec/review_spec.lua @ 210
# Failure message: spec/review_spec.lua:212: B3: 1e14 级整数被渲染成科学计数法会匹配错行
# Expected objects to be the same.
# Passed in:
# (string) '100000000000000'
# Expected:
# (string) '1e+14'
not ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
# spec/review_spec.lua @ 231
# Failure message: spec/review_spec.lua:243: B4: 同一个带时区的值走 insert(VALUES) 与走 updates(CTE) 必须落成同一时刻
# Expected objects to be the same.
# Passed in:
# (string) '2024-01-01 08:00:00+08'
# Expected:
# (string) '2024-01-01 00:00:00+08'
not ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
# spec/review_spec.lua @ 253
# Failure message: spec/review_spec.lua:256: B5: rating 为 NULL 的行长度必须仍是 2，否则 compact 数组的位置语义崩了
# Expected objects to be the same.
# Passed in:
# (number) 2
# Expected:
# (number) 1
not ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
# spec/review_spec.lua @ 265
# Failure message: spec/review_spec.lua:277: B6: 两次 validate_create 拿到的 default 表不能是同一个对象（跨请求状态泄漏）
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
not ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
# spec/review_spec.lua @ 286
# Failure message: spec/review_spec.lua:289: B7: json 型 defaults 应能写入（create 路径能过就不该 500）; err=lib/model/utils.lua:506: empty table is not allowed
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
# spec/review_spec.lua @ 300
# Failure message: spec/review_spec.lua:302: B8: NULL 相等条件应转成 IS NULL; sql=SELECT * FROM review_entry T WHERE T.rating = NULL
# Expected to be truthy, but value was:
# (nil)
not ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
# spec/review_spec.lua @ 313
# Failure message: spec/review_spec.lua:314: B9: where 收到字符串应报错，否则请求参数可原样拼进 SQL
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
not ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
# spec/review_spec.lua @ 328
# Failure message: spec/review_spec.lua:334: B11: 文档给的无 JOIN 回调示例不应抛错; err=spec/review_spec.lua:331: attempt to index local 'ctx' (a nil value)
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
# spec/review_spec.lua @ 346
# Failure message: spec/review_spec.lua:349: B12: 空 id 列表应返回空表（Django 语义），否则一次请求拉整张表
# Expected objects to be the same.
# Passed in:
# (number) 0
# Expected:
# (number) 2
not ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
# spec/review_spec.lua @ 354
# Failure message: spec/review_spec.lua:365: B13: 空数组被编码成空对象，前端按数组处理会崩; payload={"tags": {}}
# Expected to be truthy, but value was:
# (nil)
not ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
# spec/review_spec.lua @ 370
# Failure message: spec/review_spec.lua:374: B16: 两参形式的值为 nil 时应报错，否则生成 `WHERE name` 改变筛选语义; sql=SELECT * FROM review_blog T WHERE name
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
1..276
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
```


### T1 传输层错误后关闭连接而不是归还（B1）

- 优先级：P0
- 涉及文件：`lib/model/query.lua`
- 问题描述：见 B1。
- 修改方案：`ConnProxy:query` 保留 pgmoon 的完整返回值，`result == nil` 时若第 3 个返回值（`num_queries`）不是 number，置 `self.broken = true`；`release()` 在 `broken` 时改调 `disconnect()`（`pcall` 包住，失败只记日志）。`transaction()` 的错误分支在 `conn.broken` 时跳过 `rollback` 直接 `release`。可选：在 pgmoon fork 的 `receive_query_result` 里记录 `ReadyForQuery` 状态字节到 `self.txn_status`，`release()` 时 `txn_status ~= 'I'` 一律 `disconnect`。
- 验收标准：T0 的 B1 用例通过（第二条查询拿到自己的 marker，backend pid 变化）；现有事务用例通过。
- 前置任务：T0。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T1`）
- 改动文件：`lib/model/query.lua`
- 实现要点：
  - `ConnProxy:query` 保留 pgmoon 的全部返回值并区分两种失败形态：PG 报错返回 `nil, err, result, num_queries, ...`（已收到 `ReadyForQuery`，协议状态同步），传输层错误只返回 `nil, err`。判据是错误分支里 `num_queries` 位上是不是 number；不是就置 `self.broken = true`。
  - `ConnProxy:release()` 在 `broken` 时改走 `disconnect()`（`pcall` 包住，失败只记日志），不再 `setkeepalive`——cosocket 的 `setkeepalive` 在读超时后依然返回成功，是脏 socket 进池的直接原因。
  - `transaction()` 的错误分支在 `conn.broken` 时跳过 `ROLLBACK`：那条 ROLLBACK 只会读到滞留回包并「成功」，反而把脏状态坐实。
  - 未改 pgmoon（按 CLAUDE.md 跳过）：可选的 `ReadyForQuery` 状态字节兜底记入「执行中发现」F2。
- 验收结果：B1 用例（非事务 + 事务两条路径，各断言「下一条查询拿到自己的 marker」与「backend pid 必须变化」）转绿；`model_spec` 第 28 组事务用例与其余既有用例不受影响。`264 ok / 12 not ok`，12 例红全部是尚未开工的 T2–T12 对应用例，无 skip/pending。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 11:40:33 [warn] 46721#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x04aec9e0
	[C]: at 0x049be230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
not ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
# spec/review_spec.lua @ 188
# Failure message: spec/review_spec.lua:200: B2: 事务已 aborted 时 transaction() 必须抛错，而不是返回 callback 的返回值
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
not ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
# spec/review_spec.lua @ 210
# Failure message: spec/review_spec.lua:212: B3: 1e14 级整数被渲染成科学计数法会匹配错行
# Expected objects to be the same.
# Passed in:
# (string) '100000000000000'
# Expected:
# (string) '1e+14'
not ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
# spec/review_spec.lua @ 231
# Failure message: spec/review_spec.lua:243: B4: 同一个带时区的值走 insert(VALUES) 与走 updates(CTE) 必须落成同一时刻
# Expected objects to be the same.
# Passed in:
# (string) '2024-01-01 08:00:00+08'
# Expected:
# (string) '2024-01-01 00:00:00+08'
not ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
# spec/review_spec.lua @ 253
# Failure message: spec/review_spec.lua:256: B5: rating 为 NULL 的行长度必须仍是 2，否则 compact 数组的位置语义崩了
# Expected objects to be the same.
# Passed in:
# (number) 2
# Expected:
# (number) 1
not ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
# spec/review_spec.lua @ 265
# Failure message: spec/review_spec.lua:277: B6: 两次 validate_create 拿到的 default 表不能是同一个对象（跨请求状态泄漏）
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
not ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
# spec/review_spec.lua @ 286
# Failure message: spec/review_spec.lua:289: B7: json 型 defaults 应能写入（create 路径能过就不该 500）; err=lib/model/utils.lua:506: empty table is not allowed
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
# spec/review_spec.lua @ 300
# Failure message: spec/review_spec.lua:302: B8: NULL 相等条件应转成 IS NULL; sql=SELECT * FROM review_entry T WHERE T.rating = NULL
# Expected to be truthy, but value was:
# (nil)
not ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
# spec/review_spec.lua @ 313
# Failure message: spec/review_spec.lua:314: B9: where 收到字符串应报错，否则请求参数可原样拼进 SQL
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
not ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
# spec/review_spec.lua @ 328
# Failure message: spec/review_spec.lua:334: B11: 文档给的无 JOIN 回调示例不应抛错; err=spec/review_spec.lua:331: attempt to index local 'ctx' (a nil value)
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
# spec/review_spec.lua @ 346
# Failure message: spec/review_spec.lua:349: B12: 空 id 列表应返回空表（Django 语义），否则一次请求拉整张表
# Expected objects to be the same.
# Passed in:
# (number) 0
# Expected:
# (number) 2
not ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
# spec/review_spec.lua @ 354
# Failure message: spec/review_spec.lua:365: B13: 空数组被编码成空对象，前端按数组处理会崩; payload={"tags": {}}
# Expected to be truthy, but value was:
# (nil)
not ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
# spec/review_spec.lua @ 370
# Failure message: spec/review_spec.lua:374: B16: 两参形式的值为 nil 时应报错，否则生成 `WHERE name` 改变筛选语义; sql=SELECT * FROM review_blog T WHERE name
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
1..276
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
```

### T2 事务内出错后禁止提交（B2）

- 优先级：P1
- 涉及文件：`lib/model/query.lua`
- 问题描述：见 B2。
- 修改方案：`ConnProxy:query` 在 `self.in_transaction` 为真且 pgmoon 返回 PG 错误时置 `self.aborted = true`。`transaction()` 在 callback 正常返回后先检查 `conn.aborted`：为真则 `pcall(rollback)`、`release`，再 `error("transaction aborted by earlier error: " .. first_error, 0)`（首个错误在置位时一并记下）。`begin()` 置 `in_transaction = true`，`commit/rollback` 后清零。
- 验收标准：T0 的 B2 用例通过；`model_spec` 第 28 组事务用例通过。
- 前置任务：T1（同一处状态机）。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T2`）
- 改动文件：`lib/model/query.lua`
- 实现要点：
  - `ConnProxy` 增加事务状态机：`begin()` 成功后置 `in_transaction`，`commit()`/`rollback()` 清零，`rollback_to(name)` 额外清掉 `aborted`（回到 savepoint 后事务重新可写，之前那次报错不该再阻止提交）。
  - `ConnProxy:query` 在「PG 报错 + 处于事务中」时置 `self.aborted = true` 并把首个错误记进 `self.aborted_error`（只记第一个，后续错误都是它的派生）。
  - `transaction()` 在 callback 正常返回后先查 `conn.aborted`：为真则 `pcall(rollback)`（`broken` 时跳过）、`release()`，再 `error("transaction aborted by earlier error: " .. first_error, 0)`。错误信息含 `aborted`，与 T0 用例的断言一致。
  - 行为变化（需在升级说明里告知调用方）：以前「callback 吞掉 PG 报错后照常返回」会得到一个静默空提交，现在会抛错。这是把假成功改成显式失败，不是新增故障。
- 验收结果：B2 用例转绿（`transaction()` 抛错、错误信息含 `aborted`、行未落库）；`model_spec` 第 28 组事务用例（含嵌套 atomic、field_error 穿透、回滚）全部通过。`265 ok / 11 not ok`，11 例红全部是尚未开工的 T3–T12 对应用例，无 skip/pending。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 11:41:10 [warn] 46807#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x05b0b9e0
	[C]: at 0x059dd230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
not ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
# spec/review_spec.lua @ 210
# Failure message: spec/review_spec.lua:212: B3: 1e14 级整数被渲染成科学计数法会匹配错行
# Expected objects to be the same.
# Passed in:
# (string) '100000000000000'
# Expected:
# (string) '1e+14'
not ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
# spec/review_spec.lua @ 231
# Failure message: spec/review_spec.lua:243: B4: 同一个带时区的值走 insert(VALUES) 与走 updates(CTE) 必须落成同一时刻
# Expected objects to be the same.
# Passed in:
# (string) '2024-01-01 08:00:00+08'
# Expected:
# (string) '2024-01-01 00:00:00+08'
not ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
# spec/review_spec.lua @ 253
# Failure message: spec/review_spec.lua:256: B5: rating 为 NULL 的行长度必须仍是 2，否则 compact 数组的位置语义崩了
# Expected objects to be the same.
# Passed in:
# (number) 2
# Expected:
# (number) 1
not ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
# spec/review_spec.lua @ 265
# Failure message: spec/review_spec.lua:277: B6: 两次 validate_create 拿到的 default 表不能是同一个对象（跨请求状态泄漏）
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
not ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
# spec/review_spec.lua @ 286
# Failure message: spec/review_spec.lua:289: B7: json 型 defaults 应能写入（create 路径能过就不该 500）; err=lib/model/utils.lua:506: empty table is not allowed
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
# spec/review_spec.lua @ 300
# Failure message: spec/review_spec.lua:302: B8: NULL 相等条件应转成 IS NULL; sql=SELECT * FROM review_entry T WHERE T.rating = NULL
# Expected to be truthy, but value was:
# (nil)
not ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
# spec/review_spec.lua @ 313
# Failure message: spec/review_spec.lua:314: B9: where 收到字符串应报错，否则请求参数可原样拼进 SQL
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
not ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
# spec/review_spec.lua @ 328
# Failure message: spec/review_spec.lua:334: B11: 文档给的无 JOIN 回调示例不应抛错; err=spec/review_spec.lua:331: attempt to index local 'ctx' (a nil value)
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
# spec/review_spec.lua @ 346
# Failure message: spec/review_spec.lua:349: B12: 空 id 列表应返回空表（Django 语义），否则一次请求拉整张表
# Expected objects to be the same.
# Passed in:
# (number) 0
# Expected:
# (number) 2
not ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
# spec/review_spec.lua @ 354
# Failure message: spec/review_spec.lua:365: B13: 空数组被编码成空对象，前端按数组处理会崩; payload={"tags": {}}
# Expected to be truthy, but value was:
# (nil)
not ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
# spec/review_spec.lua @ 370
# Failure message: spec/review_spec.lua:374: B16: 两参形式的值为 nil 时应报错，否则生成 `WHERE name` 改变筛选语义; sql=SELECT * FROM review_blog T WHERE name
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
1..276
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
```

### T3 `meta_query` 拒绝非数据类型（B9）

- 优先级：P1
- 涉及文件：`lib/model/sql.lua`
- 问题描述：见 B9。
- 修改方案：按 D6 加类型白名单；错误信息指明字段名与期望类型。
- 验收标准：T0 的 B9 用例通过；`model_spec` 中所有 `meta_query` 用例通过。
- 前置任务：T0。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T3`）
- 改动文件：`lib/model/sql.lua`
- 实现要点：
  - `meta_query` 入口按 D6 加类型白名单，错误信息统一为 `meta_query: invalid '<arg>': expect <类型>, got <值> (<lua 类型>)`：
    - `where/get/try_get/having`：必须是 table。数组形式只放行 `{column, value}` / `{column, op, value}`；单元素数组 `{"1=1"}` 解包后等价于 `where(string)`，一并拒绝。
    - `select/order/group/flat/select_related/select_related_labels`：每个元素必须是字符串（之后仍会过 `parse_column` 的字段/操作符白名单）。
    - `limit/offset`：number 或可 `tonumber` 的字符串。
    - `raw/compact/exists`：boolean；`distinct`：boolean 或字符串列表（`true` = 整体 DISTINCT，列表 = DISTINCT ON）。
  - 顺带修掉两个解包形态的问题：`distinct = true` 以前会把 `true` 当列名解包给 `distinct(true)`；`compact = false` 以前会调 `compact(false)`，而该方法忽略入参、照样把 compact 打开。布尔开关类参数（`raw/compact/exists/distinct`）现在只有「开」一种调用形态，值为 `false` 直接跳过。
  - `where(string)`、`from`、`with(name, string)`、回调形式这些裸 SQL 入口本身保持不变（有意提供），只是不再能从 `meta_query` 的数据通道到达。
- 验收结果：B9 用例转绿（`where`/`get`/`try_get` 收到字符串一律抛错，table 形式照常工作）。`model_spec`/`bug_spec` 中没有 `meta_query` 用例，全量 `266 ok / 10 not ok`，无 skip/pending。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 11:43:08 [warn] 47046#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x0fc419e0
	[C]: at 0x0fb13230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
not ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
# spec/review_spec.lua @ 210
# Failure message: spec/review_spec.lua:212: B3: 1e14 级整数被渲染成科学计数法会匹配错行
# Expected objects to be the same.
# Passed in:
# (string) '100000000000000'
# Expected:
# (string) '1e+14'
not ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
# spec/review_spec.lua @ 231
# Failure message: spec/review_spec.lua:243: B4: 同一个带时区的值走 insert(VALUES) 与走 updates(CTE) 必须落成同一时刻
# Expected objects to be the same.
# Passed in:
# (string) '2024-01-01 08:00:00+08'
# Expected:
# (string) '2024-01-01 00:00:00+08'
not ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
# spec/review_spec.lua @ 253
# Failure message: spec/review_spec.lua:256: B5: rating 为 NULL 的行长度必须仍是 2，否则 compact 数组的位置语义崩了
# Expected objects to be the same.
# Passed in:
# (number) 2
# Expected:
# (number) 1
not ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
# spec/review_spec.lua @ 265
# Failure message: spec/review_spec.lua:277: B6: 两次 validate_create 拿到的 default 表不能是同一个对象（跨请求状态泄漏）
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
not ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
# spec/review_spec.lua @ 286
# Failure message: spec/review_spec.lua:289: B7: json 型 defaults 应能写入（create 路径能过就不该 500）; err=lib/model/utils.lua:506: empty table is not allowed
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
# spec/review_spec.lua @ 300
# Failure message: spec/review_spec.lua:302: B8: NULL 相等条件应转成 IS NULL; sql=SELECT * FROM review_entry T WHERE T.rating = NULL
# Expected to be truthy, but value was:
# (nil)
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
not ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
# spec/review_spec.lua @ 328
# Failure message: spec/review_spec.lua:334: B11: 文档给的无 JOIN 回调示例不应抛错; err=spec/review_spec.lua:331: attempt to index local 'ctx' (a nil value)
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
# spec/review_spec.lua @ 346
# Failure message: spec/review_spec.lua:349: B12: 空 id 列表应返回空表（Django 语义），否则一次请求拉整张表
# Expected objects to be the same.
# Passed in:
# (number) 0
# Expected:
# (number) 2
not ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
# spec/review_spec.lua @ 354
# Failure message: spec/review_spec.lua:365: B13: 空数组被编码成空对象，前端按数组处理会崩; payload={"tags": {}}
# Expected to be truthy, but value was:
# (nil)
not ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
# spec/review_spec.lua @ 370
# Failure message: spec/review_spec.lua:374: B16: 两参形式的值为 nil 时应报错，否则生成 `WHERE name` 改变筛选语义; sql=SELECT * FROM review_blog T WHERE name
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
1..276
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
```

### T4 整数字面量精确渲染与 bigint 读回选项（B3）

- 优先级：P1
- 涉及文件：`lib/model/utils.lua`（`_escape_factory`）、`lib/model/query.lua`（pgmoon 反序列化选项）、`lib/model/fields.lua`（`IntegerField` 的 `bigint` 支持）
- 问题描述：见 B3。
- 修改方案：按 D4。写入侧无条件修复；读回侧新增 `Query` 选项 `BIGINT_AS_STRING`（默认关）。
- 验收标准：T0 的 B3 用例通过；`bug_spec` 全部通过（其中有大量 `statement()` 字符串断言，注意整数渲染不能出现多余的 `.0`）。
- 前置任务：T0。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T4`）
- 改动文件：`lib/model/utils.lua`、`lib/model/query.lua`、`lib/model/fields.lua`
- 实现要点（写入侧无条件修复，读回侧做成默认关闭的开关）：
  - `utils.lua` 的 `_escape_factory` 把 number 分支从 `tostring` 换成 `number_literal`：`nan`/`inf` 直接报错（本来就是 PG 语法错误，只是报在 PG 侧信息难懂）；非整数仍按 `%.14g` 渲染；`|v| <= 2^53` 的整数用 `string.format("%d")` 精确渲染（`1e+14` → `100000000000000`）；`|v| > 2^53` 报错并提示改用 int64 cdata 或十进制字符串——到那一步值早就不是调用方写下的那个整数了，静默写入比报错更糟。
  - 新增 `cdata` 分支：`int64_t`/`uint64_t` 去掉 `LL`/`ULL` 后缀后精确渲染，这是 19 位雪花 ID 唯一能精确传进来的形态。
  - `query.lua` 新增 `Query` 选项 `BIGINT_AS_STRING`（也可用 `.env` 的 `PG_BIGINT_AS_STRING=true`），**默认关**。打开后在新建连接上 `set_type_deserializer(20, "int8_text", ...)`，int8 按原始十进制字符串返回，不经 pgmoon 的 `tonumber`。默认关是因为它会把 `rec.id` 从 number 变成 string，属于行为变化。
  - `fields.lua` 的 `IntegerField` 支持 `bigint = true`（等价于 `db_type = 'bigint'`）：校验器换成 bigint 口径（安全范围内转 number，超出范围保留精确的十进制字符串），并只给 bigint 字段挂 `load`（`Model:load` 对每行每列都会查 `field.load`，普通 integer 列不该为此多付一次调用）。
- 实测（`spec` 外的独立脚本，不入库）：`as_literal(100000000000000)` → `100000000000000`；`as_literal(123456789012345678LL)` → `123456789012345678`；`BIGINT_AS_STRING` 关时 `SELECT 123456789012345678::bigint` 读回 `123456789012345680`（number），开时读回 `'123456789012345678'`（string）；`bigint` 字段 `where { sid = '123456789012345678' }` 渲染成 `T.sid = '123456789012345678'`，PG 侧按 bigint 解析。
- 验收结果：B3 用例转绿（15 位整数精确渲染、`2^53` 精确、超出 2^53 的 number 报错、int64 cdata 精确、`nan`/`inf` 报错）。`bug_spec` 的 `statement()` 字符串断言全部通过——整数渲染没有多出 `.0`（`%d` 而不是 `%g`/`%f`）。全量 `267 ok / 9 not ok`，无 skip/pending。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 11:45:43 [warn] 47356#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x071d49e0
	[C]: at 0x070a6230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
not ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
# spec/review_spec.lua @ 231
# Failure message: spec/review_spec.lua:243: B4: 同一个带时区的值走 insert(VALUES) 与走 updates(CTE) 必须落成同一时刻
# Expected objects to be the same.
# Passed in:
# (string) '2024-01-01 08:00:00+08'
# Expected:
# (string) '2024-01-01 00:00:00+08'
not ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
# spec/review_spec.lua @ 253
# Failure message: spec/review_spec.lua:256: B5: rating 为 NULL 的行长度必须仍是 2，否则 compact 数组的位置语义崩了
# Expected objects to be the same.
# Passed in:
# (number) 2
# Expected:
# (number) 1
not ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
# spec/review_spec.lua @ 265
# Failure message: spec/review_spec.lua:277: B6: 两次 validate_create 拿到的 default 表不能是同一个对象（跨请求状态泄漏）
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
not ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
# spec/review_spec.lua @ 286
# Failure message: spec/review_spec.lua:289: B7: json 型 defaults 应能写入（create 路径能过就不该 500）; err=lib/model/utils.lua:559: empty table is not allowed
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
# spec/review_spec.lua @ 300
# Failure message: spec/review_spec.lua:302: B8: NULL 相等条件应转成 IS NULL; sql=SELECT * FROM review_entry T WHERE T.rating = NULL
# Expected to be truthy, but value was:
# (nil)
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
not ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
# spec/review_spec.lua @ 328
# Failure message: spec/review_spec.lua:334: B11: 文档给的无 JOIN 回调示例不应抛错; err=spec/review_spec.lua:331: attempt to index local 'ctx' (a nil value)
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
# spec/review_spec.lua @ 346
# Failure message: spec/review_spec.lua:349: B12: 空 id 列表应返回空表（Django 语义），否则一次请求拉整张表
# Expected objects to be the same.
# Passed in:
# (number) 0
# Expected:
# (number) 2
not ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
# spec/review_spec.lua @ 354
# Failure message: spec/review_spec.lua:365: B13: 空数组被编码成空对象，前端按数组处理会崩; payload={"tags": {}}
# Expected to be truthy, but value was:
# (nil)
not ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
# spec/review_spec.lua @ 370
# Failure message: spec/review_spec.lua:374: B16: 两参形式的值为 nil 时应报错，否则生成 `WHERE name` 改变筛选语义; sql=SELECT * FROM review_blog T WHERE name
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
1..276
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
```

### T5 datetime CTE 类型后缀（B4）

- 优先级：P1
- 涉及文件：`lib/model/fields.lua`（`get_cast_type`）、`lib/model/sql.lua:1652`
- 问题描述：见 B4。
- 修改方案：按 D5。不要改 `db_type` 本身（`resty.migrate` 依赖它）。
- 验收标准：T0 的 B4 用例通过；`model_spec` 的 merge/updates/gets/merge_gets 用例通过。
- 前置任务：T0。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T5`）
- 改动文件：`lib/model/fields.lua`、`lib/model/sql.lua`
- 实现要点：
  - 按 D5 给 `BaseField` 加 `get_cast_type()`（默认返回 `db_type`），`DatetimeField` 在 `timezone = true` 时返回 `timestamptz`、`TimeField` 返回 `timetz`。
  - `sql.lua:_array_to_values` 的类型后缀改调 `field:get_cast_type()`。**没有动 `db_type` 本身**：它同时被 `resty.migrate` 拿去比对 schema，两个用途的语义不同——一个是「列建成什么」，一个是「值在 SQL 里按什么解释」，datetime/time 上恰好不一致。
  - 受影响路径就是走 `_get_cte_values_literal` 的那几个：`merge`、`updates`、`gets`、`merge_gets`、`with_values`（含 `create_sql_as`）。`insert`/`upsert`/`align` 走 VALUES 字面量、本来就不加 cast，不受影响。
- 验收结果：B4 用例转绿——同一个 `'2024-01-01T00:00:00Z'` 走 `insert` 与走 `updates` 落库时刻相等（此前差 8 小时），且 `merge` 的 CTE 首行 cast 是 `::timestamptz`。`model_spec` 的 merge/updates/gets/merge_gets 用例全部通过。全量 `268 ok / 8 not ok`，无 skip/pending。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 11:47:02 [warn] 47554#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x0660b9e0
	[C]: at 0x064dd230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
not ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
# spec/review_spec.lua @ 253
# Failure message: spec/review_spec.lua:256: B5: rating 为 NULL 的行长度必须仍是 2，否则 compact 数组的位置语义崩了
# Expected objects to be the same.
# Passed in:
# (number) 2
# Expected:
# (number) 1
not ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
# spec/review_spec.lua @ 265
# Failure message: spec/review_spec.lua:277: B6: 两次 validate_create 拿到的 default 表不能是同一个对象（跨请求状态泄漏）
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
not ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
# spec/review_spec.lua @ 286
# Failure message: spec/review_spec.lua:289: B7: json 型 defaults 应能写入（create 路径能过就不该 500）; err=lib/model/utils.lua:559: empty table is not allowed
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
# spec/review_spec.lua @ 300
# Failure message: spec/review_spec.lua:302: B8: NULL 相等条件应转成 IS NULL; sql=SELECT * FROM review_entry T WHERE T.rating = NULL
# Expected to be truthy, but value was:
# (nil)
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
not ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
# spec/review_spec.lua @ 328
# Failure message: spec/review_spec.lua:334: B11: 文档给的无 JOIN 回调示例不应抛错; err=spec/review_spec.lua:331: attempt to index local 'ctx' (a nil value)
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
# spec/review_spec.lua @ 346
# Failure message: spec/review_spec.lua:349: B12: 空 id 列表应返回空表（Django 语义），否则一次请求拉整张表
# Expected objects to be the same.
# Passed in:
# (number) 0
# Expected:
# (number) 2
not ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
# spec/review_spec.lua @ 354
# Failure message: spec/review_spec.lua:365: B13: 空数组被编码成空对象，前端按数组处理会崩; payload={"tags": {}}
# Expected to be truthy, but value was:
# (nil)
not ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
# spec/review_spec.lua @ 370
# Failure message: spec/review_spec.lua:374: B16: 两参形式的值为 nil 时应报错，否则生成 `WHERE name` 改变筛选语义; sql=SELECT * FROM review_blog T WHERE name
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
1..276
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
```

### T6 `validate_create` 使用 `get_default()`（B6）

- 优先级：P2
- 涉及文件：`lib/model/init.lua:1169-1179`
- 问题描述：见 B6。
- 修改方案：`elseif field.default ~= nil and (value == nil or value == "") then value, err = field:get_default()`，保留对函数返回 `nil, err` 的处理。
- 验收标准：T0 的 B6 用例通过；`model_spec` 第 26 组校验用例通过。
- 前置任务：T0。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T6`）
- 改动文件：`lib/model/init.lua`
- 实现要点：
  - `validate_create` 回填 default 时改走 `field:get_default()`（对 table 型 default 会 `clone` 一份），不再把字段定义上的那张表直接放进返回数据。
  - 条件按 T6 方案从 `field.default and ...` 改成 `field.default ~= nil and ...`：`default = false`（boolean 字段）以前会被 `and` 吞掉、回填不上，现在与其它 default 一致。
  - 保留对「函数型 default 返回 `nil, err`」的处理：只有 `type(field.default) == "function"` 且返回 nil 才转成 `field_error`，table/标量型 default 不受影响。
- 验收结果：B6 用例转绿（两次 `validate_create` 的 default 表不是同一个对象；改了上一次返回的 default 不污染下一次）。`model_spec` 第 26 组校验用例全部通过。全量 `269 ok / 7 not ok`，无 skip/pending。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 11:47:45 [warn] 47652#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x007049e0
	[C]: at 0x005d6230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
not ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
# spec/review_spec.lua @ 253
# Failure message: spec/review_spec.lua:256: B5: rating 为 NULL 的行长度必须仍是 2，否则 compact 数组的位置语义崩了
# Expected objects to be the same.
# Passed in:
# (number) 2
# Expected:
# (number) 1
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
not ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
# spec/review_spec.lua @ 286
# Failure message: spec/review_spec.lua:289: B7: json 型 defaults 应能写入（create 路径能过就不该 500）; err=lib/model/utils.lua:559: empty table is not allowed
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
# spec/review_spec.lua @ 300
# Failure message: spec/review_spec.lua:302: B8: NULL 相等条件应转成 IS NULL; sql=SELECT * FROM review_entry T WHERE T.rating = NULL
# Expected to be truthy, but value was:
# (nil)
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
not ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
# spec/review_spec.lua @ 328
# Failure message: spec/review_spec.lua:334: B11: 文档给的无 JOIN 回调示例不应抛错; err=spec/review_spec.lua:331: attempt to index local 'ctx' (a nil value)
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
# spec/review_spec.lua @ 346
# Failure message: spec/review_spec.lua:349: B12: 空 id 列表应返回空表（Django 语义），否则一次请求拉整张表
# Expected objects to be the same.
# Passed in:
# (number) 0
# Expected:
# (number) 2
not ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
# spec/review_spec.lua @ 354
# Failure message: spec/review_spec.lua:365: B13: 空数组被编码成空对象，前端按数组处理会崩; payload={"tags": {}}
# Expected to be truthy, but value was:
# (nil)
not ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
# spec/review_spec.lua @ 370
# Failure message: spec/review_spec.lua:374: B16: 两参形式的值为 nil 时应报错，否则生成 `WHERE name` 改变筛选语义; sql=SELECT * FROM review_blog T WHERE name
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
1..276
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
```

### T7 `get_or_create` 走校验与 `prepare_for_db`（B7）

- 优先级：P2
- 涉及文件：`lib/model/sql.lua:3333-3373`
- 问题描述：见 B7。
- 修改方案：按 D7。
- 验收标准：T0 的 B7 用例通过；`model_spec` 第 15 组用例通过。
- 前置任务：T0。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T7`）
- 改动文件：`lib/model/sql.lua`
- 实现要点：
  - `get_or_create` 在拼 `INSERT ... ON CONFLICT` 的 token 之前，对 `dict(params, defaults)` 走 `validate_update` + `_prepare_db_rows`，与 `update_or_create` 完全同一套口径；`skip_validate()` 仍然能跳过校验（只跳 `validate_update`，`_prepare_db_rows` 照常，与 `update_or_create` 一致）。
  - 原有的字段名存在性检查保留在前面（列名会直接拼进 INSERT 列清单和 ON CONFLICT，必须先确认是本模型的字段）。
  - 修掉的具体症状：json 对象撞 `empty table is not allowed`、json 数组被渲染成行值 `(1, 2)`、整数字段的 `''` 变成 `''` 字面量让 PG 报 `invalid input syntax for type integer`、字符串没经 `compact/trim` 导致唯一键查找与 `create` 路径口径不一致（`' 张三'` 与 `'张三'` 被当成两条）。
- 验收结果：B7 用例转绿（`{payload = {a = 1}}` 正常写入且读回 `payload.a == 1`；`{age = ''}` 落成 NULL 而不是报错）。`model_spec` 第 15 组 get_or_create / update_or_create 用例全部通过。全量 `270 ok / 6 not ok`，无 skip/pending。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 11:48:36 [warn] 47807#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x0a7c89e0
	[C]: at 0x0a69a230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
not ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
# spec/review_spec.lua @ 253
# Failure message: spec/review_spec.lua:256: B5: rating 为 NULL 的行长度必须仍是 2，否则 compact 数组的位置语义崩了
# Expected objects to be the same.
# Passed in:
# (number) 2
# Expected:
# (number) 1
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
not ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
# spec/review_spec.lua @ 300
# Failure message: spec/review_spec.lua:302: B8: NULL 相等条件应转成 IS NULL; sql=SELECT * FROM review_entry T WHERE T.rating = NULL
# Expected to be truthy, but value was:
# (nil)
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
not ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
# spec/review_spec.lua @ 328
# Failure message: spec/review_spec.lua:334: B11: 文档给的无 JOIN 回调示例不应抛错; err=spec/review_spec.lua:331: attempt to index local 'ctx' (a nil value)
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
# spec/review_spec.lua @ 346
# Failure message: spec/review_spec.lua:349: B12: 空 id 列表应返回空表（Django 语义），否则一次请求拉整张表
# Expected objects to be the same.
# Passed in:
# (number) 0
# Expected:
# (number) 2
not ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
# spec/review_spec.lua @ 354
# Failure message: spec/review_spec.lua:365: B13: 空数组被编码成空对象，前端按数组处理会崩; payload={"tags": {}}
# Expected to be truthy, but value was:
# (nil)
not ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
# spec/review_spec.lua @ 370
# Failure message: spec/review_spec.lua:374: B16: 两参形式的值为 nil 时应报错，否则生成 `WHERE name` 改变筛选语义; sql=SELECT * FROM review_blog T WHERE name
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
1..276
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
```

### T8 `NULL` 条件映射为 `IS NULL`（B8）

- 优先级：P2
- 涉及文件：`lib/model/expr.lua`（`eq`、`ne`）
- 问题描述：见 B8。
- 修改方案：`eq`：`value == NULL` 时返回 `key IS NULL`；`ne`：返回 `key IS NOT NULL`。`in` 列表里的 NULL 保持原样（SQL 语义如此）。
- 验收标准：T0 的 B8 用例通过；`bug_spec`、`model_spec` 第 3 组 WHERE 用例通过。
- 前置任务：T0。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T8`）
- 改动文件：`lib/model/expr.lua`
- 实现要点：
  - `eq` 在 `value == Model.NULL`（即 `ngx.null`）时返回 `key IS NULL`，`ne` 返回 `key IS NOT NULL`。SQL 的三值逻辑下 `col = NULL` / `col <> NULL` 恒为 unknown——筛选永远空集、`update ... where {x = NULL}` 永远 0 行，且不报任何错；调用方写 `Model.NULL` 的意图就是「为空」（Django 的 `col=None` 同样转 `IS NULL`）。
  - `in`/`notin` 列表里的 NULL 保持原样：SQL 语义本就如此（`IN (NULL)` 不匹配任何行），改写反而会偏离标准。
  - 只改条件通道（`EXPR_OPERATORS` 只被 `_get_expr_token` 使用），`update {col = NULL}` 的 SET 子句不经这里，仍然写字面量 `NULL`，语义正确。
- 遗留（已记入「执行中发现」F3）：两参 `where('col', Model.NULL)` 与三参 `where('col', '=', Model.NULL)` 不走 `EXPR_OPERATORS`，仍生成 `= NULL`。
- 验收结果：B8 用例转绿（`where {rating = NULL}` 生成 `IS NULL` 且与 `rating__isnull = true` 命中同样的行；`rating__ne = NULL` 生成 `IS NOT NULL`）。`bug_spec` 与 `model_spec` 第 3 组 WHERE 用例全部通过。全量 `271 ok / 5 not ok`，无 skip/pending。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 11:49:44 [warn] 47937#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x064249e0
	[C]: at 0x062f6230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
not ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
# spec/review_spec.lua @ 253
# Failure message: spec/review_spec.lua:256: B5: rating 为 NULL 的行长度必须仍是 2，否则 compact 数组的位置语义崩了
# Expected objects to be the same.
# Passed in:
# (number) 2
# Expected:
# (number) 1
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
not ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
# spec/review_spec.lua @ 328
# Failure message: spec/review_spec.lua:334: B11: 文档给的无 JOIN 回调示例不应抛错; err=spec/review_spec.lua:331: attempt to index local 'ctx' (a nil value)
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
# spec/review_spec.lua @ 346
# Failure message: spec/review_spec.lua:349: B12: 空 id 列表应返回空表（Django 语义），否则一次请求拉整张表
# Expected objects to be the same.
# Passed in:
# (number) 0
# Expected:
# (number) 2
not ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
# spec/review_spec.lua @ 354
# Failure message: spec/review_spec.lua:365: B13: 空数组被编码成空对象，前端按数组处理会崩; payload={"tags": {}}
# Expected to be truthy, but value was:
# (nil)
not ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
# spec/review_spec.lua @ 370
# Failure message: spec/review_spec.lua:374: B16: 两参形式的值为 nil 时应报错，否则生成 `WHERE name` 改变筛选语义; sql=SELECT * FROM review_blog T WHERE name
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
1..276
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
```

### T9 compact 查询下 NULL 占位（B5）

- 优先级：P2
- 涉及文件：`lib/model/query.lua`（`ConnProxy:query` 同步 `convert_null`）、`lib/model/sql.lua`（`values_list/flat` 对 `ngx.null` 的处理）
- 问题描述：见 B5。
- 修改方案：按 D3 第一档；第二档作为 `Query` 选项 `CONVERT_NULL`。
- 验收标准：T0 的 B5 用例通过；`model_spec` 第 18 组 flat/values 用例通过；`count()`、`exists()` 返回值类型不变。
- 前置任务：T1（同一函数）。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T9`）
- 改动文件：`lib/model/query.lua`
- 实现要点（D3 第一档默认开，第二档做成开关）：
  - `ConnProxy:query` 现在同步 `conn.convert_null`：**compact 查询无条件置 true**。compact 结果集的语义就是「按位置取列」，而 pgmoon 在 `convert_null = false` 时根本不写入 NULL 列，整行少一格——`values_list({'id','rating'})` 对 NULL 行返回 `{1}`、`flat` 的元素数少于行数，与同序的 id 列表对不上。
  - 非 compact 路径默认保持「NULL 列缺键」的老行为，`Query` 选项 `CONVERT_NULL`（或 `.env` 的 `PG_CONVERT_NULL=true`）打开第二档。默认关是因为 `ngx.null` 是真值，打开后 `if rec.x then` 的判断会变——必须由业务方自己选。
  - `make_conn` 把 `conn.NULL` 统一成 `Model.NULL`（`ngx.null`）：pgmoon 自带的哨兵是它内部的 `{"NULL"}` 表，与 ORM 对外暴露的 NULL 不是同一个对象，不统一的话调用方 `v == Model.NULL` 永远为假。
  - `sql.lua` 不需要改：`Array:flat` 对非 table 元素原样保留，占位值补齐后 `values_list`/`flat`/`dates` 的位置语义自动成立；`count()`/`exists()` 取的是 `res[1][1]`，返回值类型不变。
- 验收结果：B5 用例转绿（NULL 行长度仍是 2、NULL 位是 `ngx.null`、`flat` 元素数等于 `count()`）。`model_spec` 第 18 组 flat/values 用例全部通过，`count()`/`exists()` 相关用例不受影响。全量 `272 ok / 4 not ok`，无 skip/pending。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 11:51:52 [warn] 48159#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x0cc899e0
	[C]: at 0x0cb5b230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
not ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
# spec/review_spec.lua @ 328
# Failure message: spec/review_spec.lua:334: B11: 文档给的无 JOIN 回调示例不应抛错; err=spec/review_spec.lua:331: attempt to index local 'ctx' (a nil value)
# Expected objects to be the same.
# Passed in:
# (boolean) false
# Expected:
# (boolean) true
not ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
# spec/review_spec.lua @ 346
# Failure message: spec/review_spec.lua:349: B12: 空 id 列表应返回空表（Django 语义），否则一次请求拉整张表
# Expected objects to be the same.
# Passed in:
# (number) 0
# Expected:
# (number) 2
not ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
# spec/review_spec.lua @ 354
# Failure message: spec/review_spec.lua:365: B13: 空数组被编码成空对象，前端按数组处理会崩; payload={"tags": {}}
# Expected to be truthy, but value was:
# (nil)
not ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
# spec/review_spec.lua @ 370
# Failure message: spec/review_spec.lua:374: B16: 两参形式的值为 nil 时应报错，否则生成 `WHERE name` 改变筛选语义; sql=SELECT * FROM review_blog T WHERE name
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
1..276
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
```

### T10 回调形式前初始化 JOIN 上下文（B11）

- 优先级：P2
- 涉及文件：`lib/model/sql.lua:763`、`925`、`1574`
- 问题描述：见 B11。
- 修改方案：三处在调用回调前 `self:_ensure_context()`。
- 验收标准：T0 的 B11 用例通过；`model_spec` 全部通过。
- 前置任务：T0。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T10`）
- 改动文件：`lib/model/sql.lua`
- 实现要点：
  - 三处回调入口（`_base_get_condition_token` 的 where 回调、`_get_column_tokens` 的 select 回调、`_get_order_column_tokens` 的 order 回调）在调用回调前先 `self:_ensure_context()`。
  - `_join_proxy_models` 原先只在 `_handle_manual_join` 里初始化，所以没有触发过 JOIN 的 builder 上回调拿到的 `ctx` 是 nil——而 `docs/orm-query-basics.md:31`、`:240` 给的示例恰好都是无 JOIN 的，照着文档写必然 `attempt to index local 'ctx' (a nil value)`。
  - `_ensure_context()` 是幂等的（`if not self._join_proxy_models`），已经有 JOIN 的 builder 上不产生任何变化，主表代理的别名取 `self._as or self.table_name`，与 JOIN 路径一致。
- 验收结果：B11 用例转绿（`where(function(ctx) return ctx[1].name .. " = '...'" end):get()` 返回记录；`select(function(ctx) return ctx[1].name end)` 正常）。`model_spec` 全部通过。全量 `273 ok / 3 not ok`，无 skip/pending。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 11:52:37 [warn] 48323#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x05d629e0
	[C]: at 0x05c34230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
not ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
# spec/review_spec.lua @ 346
# Failure message: spec/review_spec.lua:349: B12: 空 id 列表应返回空表（Django 语义），否则一次请求拉整张表
# Expected objects to be the same.
# Passed in:
# (number) 0
# Expected:
# (number) 2
not ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
# spec/review_spec.lua @ 354
# Failure message: spec/review_spec.lua:365: B13: 空数组被编码成空对象，前端按数组处理会崩; payload={"tags": {}}
# Expected to be truthy, but value was:
# (nil)
not ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
# spec/review_spec.lua @ 370
# Failure message: spec/review_spec.lua:374: B16: 两参形式的值为 nil 时应报错，否则生成 `WHERE name` 改变筛选语义; sql=SELECT * FROM review_blog T WHERE name
# Expected objects to be the same.
# Passed in:
# (boolean) true
# Expected:
# (boolean) false
1..276
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
```

### T11 `in_bulk({})`、`where(col, nil)`、`update(string)`（B12、B16、B15）

- 优先级：P3
- 涉及文件：`lib/model/sql.lua`
- 问题描述：见 B12、B16、B15。
- 修改方案：`in_bulk`：`ids ~= nil and #ids == 0` 直接返回 `{}`。`where`：改用 `select('#', ...)` 判断参数个数，两参形式值为 nil 时抛错。`update`：就是应该只接受 table，改注解。
- 验收标准：T0 的 B12、B16 用例通过；文档 `in_bulk()` 不传参返回全集的行为保持。
- 前置任务：T0。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T11`）
- 改动文件：`lib/model/sql.lua`
- 实现要点：
  - **B12**：`in_bulk` 在 `ids ~= nil and #ids == 0` 时直接返回 `{}`。空 id 列表的语义是「没有要取的东西」，不是「不筛选」；以前空表等同于不传参，一个「请求里 id 列表恰好为空」就把整张表拉回来。不传参仍然是「取全集」（文档行为保持）。
  - **B16**：`Sql:where` 改成 `...` 接参，用 `select('#', ...)` 数参数个数——声明成具名形参时 `where('name', nil)` 与 `where("name = 'x'")` 在函数体里完全无法区分，前者被当成一参裸 SQL 生成 `WHERE name`：varchar 列 PG 报类型错误（还能发现），boolean 列则静默变成「筛选该列为真的行」。现在两参形式值为 nil 时抛错，并在错误信息里给出 `Model.NULL` / `__isnull` 两种正确写法。只拦 `argc == 2 and op == nil and type(cond) == 'string'`，内部以三参形式转发的调用点（`get`/`exclude`/`_base_*`）不受影响。
  - **B15**：`Sql:update` 只接受 table，改注解（`---@field update fun(self, row: Record, ...)`）并在方法上写明——实现直接 `pairs(row)`，传字符串报 `bad argument #1 to 'pairs'`；`_base_update` 的字符串支持是内部裸 SQL 通道，公开方法不提供。
- 验收结果：B12、B16 用例转绿（`in_bulk()` 仍返回全集 2 条、`in_bulk {}` 返回空表；`where('name', nil)` 抛错、`where('name', 'review-blog-1')` 照常）。全量 `275 ok / 1 not ok`，仅剩 T12 对应的 B13，无 skip/pending。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 11:53:55 [warn] 48455#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x0d5269e0
	[C]: at 0x0d3f8230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
not ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
# spec/review_spec.lua @ 354
# Failure message: spec/review_spec.lua:365: B13: 空数组被编码成空对象，前端按数组处理会崩; payload={"tags": {}}
# Expected to be truthy, but value was:
# (nil)
ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
1..276
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.
```

### T12 JSON 空数组往返（B13）

- 优先级：P3
- 涉及文件：`lib/model/validator.lua`（`encode/decode` 改用独立 cjson 实例，`encode_empty_table_as_object(false)` 仅对标记为数组的表）、`lib/model/query.lua`（给 pgmoon `set_type_deserializer('json', ...)` 用 `decode_array_with_array_mt(true)` 的实例）
- 问题描述：见 B13。
- 修改方案：ORM 内部用 `require("cjson").new()` 创建独立实例，避免改全局 cjson 配置影响应用其它部分。
- 验收标准：T0 的 B13 用例通过；`model_spec` 第 25 组 JSON 用例通过。
- 前置任务：T0。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T12`）
- 改动文件：`lib/model/validator.lua`、`lib/model/query.lua`
- 实现要点：
  - `validator.lua` 的 `encode`/`decode` 改用 `require("cjson.safe").new()` 的**独立实例**，配置 `encode_empty_table_as_object(false)` + `decode_array_with_array_mt(true)`。用独立实例是关键：直接改全局 cjson 的配置会波及应用里所有用到 cjson 的地方。
  - `query.lua` 给 json(114) / jsonb(3802) 注册自己的反序列化器（同样开 `decode_array_with_array_mt`），pgmoon 默认的 decode 不开这个开关，库里的 `[]` 解出来是普通空表，「读出 → 改一个字段 → 存回」一轮就变成 `{}`。解不开的内容原样按文本返回，不丢数据。
  - 实例级的 `array_mt`/`empty_array_mt` 与全局 cjson 是同一张表（实测 `inst.empty_array_mt == cjson.empty_array_mt`），所以 `Validator.encode_as_array`（`ArrayField`/`TableField` 用）不受影响。
  - 代价（已记入「执行中发现」F4）：Lua 区分不了空表与空数组，本意是**空对象**的 `{}` 现在也会编码成 `[]`。这是两害相权：JSON 字段里的空表绝大多数是空数组，编码成 `{}` 会让前端按数组处理时崩。
- 验收结果：B13 用例转绿（`payload = { tags = {} }` 入库后 `payload::text` 是 `{"tags": []}`）。`model_spec` 第 25 组 JSON 用例、array/table 字段相关用例全部通过。
- **全量 `276 ok / 0 not ok`，无 skip / pending（TAP 计数 `1..276`）**——T0 的 13 个回归用例与原有 263 例同时全绿。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 11:56:09 [warn] 48741#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x0b25b9e0
	[C]: at 0x0b12d230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
1..276
Done in 4.09s.
```

### T13 `standard_conforming_strings` 强制（S2）

- 优先级：P3
- 涉及文件：`lib/model/query.lua:288-310`
- 问题描述：见 S2。
- 修改方案：恢复注释掉的 `SET standard_conforming_strings = on`，与 `statement_timeout` 合并成一条 `SET` 语句（一次往返），仅在 `getreusedtimes() == 0` 时发。
- 验收标准：新增用例：新建连接后 `SHOW standard_conforming_strings` 为 `on`；全量测试通过。
- 前置任务：T1。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T13`）
- 改动文件：`lib/model/query.lua`、`spec/review_spec.lua`（新增 1 个用例）
- 实现要点：
  - `make_conn` 里把取 `getreusedtimes()` 的判断从 `if statement_timeout then` 里提了出来：会话初始化现在**无条件**在新建连接上跑一次（以前只有配了 `STATEMENT_TIMEOUT` 才跑），`SET standard_conforming_strings = on` 是必发项，`SET statement_timeout` 仍是可选项，两条用 `;` 拼成一条简单查询，**一次往返**。复用连接（`getreusedtimes() > 0`）上一条往返都不加 —— 会话级参数在池里的 socket 上本来就还在。
  - 失败处理与原来一致并扩大到两个参数：`SET` 不成功就 `disconnect` 再抛错，不把这条连接放回池里。转义假设不成立的连接比连不上更危险。错误信息改成 `failed to init session (standard_conforming_strings/statement_timeout)`。
  - 删掉了原来那段注释掉的代码。
- 与本节原方案的差异（1 处）：
  - 原注释块里还有一条 `SET TIME ZONE`（来自上游模板的 `PGTIMEZONE`），**没有恢复**。本节方案只写了 `standard_conforming_strings`，而锁定会话时区会改变 `timestamptz` 列的回读字符串形态，属于行为变更而非安全修复，且会与 T5（B4）刚定下的时区口径纠缠。记入末尾「执行中发现」F5，留给需要的部署自己配。
- 验收结果：新增用例 `S2/T13` 修复前红、修复后绿。用例不满足于「读一下默认值」——它先用独立的管理连接 `ALTER DATABASE test SET standard_conforming_strings = off` 把库级默认改掉（这正是 S2 说的「可以在库级/角色级被改掉」），再用独立 POOL_NAME 建新连接，断言两件事：`SHOW standard_conforming_strings` 仍为 `on`；值 `a\'b` 经 `as_literal` 往返后原样返回（scs=off 时 `'a\''b'` 的字面量会提前闭合，后半截漏进 SQL 正文，就是 S2 的注入面）。断言之前无条件 `RESET` 回去，用例中途失败也不会把本机环境留在 `off`。
- **全量 `277 ok / 0 not ok`，无 skip / pending（TAP 计数 `1..277`）**。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 13:15:57 [warn] 53327#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x050159e0
	[C]: at 0x04ee7230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
ok 277 - REVIEW: 疑似问题与设计建议回归 S2/T13 新建连接必须强制 standard_conforming_strings = on
1..277
Done in 4.10s.
```

### T14 阶段守卫与连接池默认值（S3、S4）

- 优先级：P3
- 涉及文件：`lib/model/query.lua`、`docs/orm-index.md`
- 问题描述：见 S3、S4。
- 修改方案：按 D9、D10。
- 验收标准：新增用例：在 `init_worker` 直接调用 `Blog:count()` 得到含 `phase` 字样的明确错误（需 nginx 环境，可先以文档说明代替）；`Query()` 缓存命中且参数不同时日志出现 WARN。
- 前置任务：T1。

- 状态：✅ 已完成（2026-09-21，提交信息含 `T14`）
- 改动文件：`lib/model/query.lua`、`lib/model/fields.lua`、`lib/model/init.lua`、`docs/orm-index.md`、`spec/review_spec.lua`（新增 4 个用例）
- 实现要点：
  - **阶段守卫（D9）**：`create_query` 里按 `connect_table` 造一个 `check_phase` 闭包，`send_query` 与 `transaction` 入口各调一次。允许的阶段取 cosocket 真正可用的那一组：`rewrite`/`access`/`content`/`timer`/`preread`/`ssl_cert`/`ssl_session_fetch`/`ssl_client_hello`。两个放行的例外：`init` 阶段（pgmoon 的 `socket.new` 在这里自己回落到 luasocket，迁移脚本靠这条活着）、以及显式配了非 `nginx` 的 `SOCKET_TYPE`（根本不走 cosocket）。错误信息点名阶段，并指出最常见的触发路径是外键惰性加载。
  - **`Model.LAZY_FK`（D9）**：开关本体是 `model/fields.lua` 的 `fk_config.lazy`（`fields` 不能反向 `require` `init`，只能由 `init` 转发），`ForeignkeyField:load` 的 `__index` 在真正要发 SQL 之前读它。`init.lua` 给 `Model` 的元表补 `__index`/`__newindex` 做转发。**`LAZY_FK` 不能写成 `Model` 的直接键**：`__newindex` 只在键不存在时触发，写成直接键后第二次赋值就绕过转发了（而且会被建模时的 `pairs` 复制成快照）。默认 `true`，沿用现状。
  - **`STATEMENT_TIMEOUT` 默认值（D10）**：抽出 `resolve_statement_timeout`，不配时取 `QUERY_TIMEOUT - 2000`。**派生值必须为正**：`QUERY_TIMEOUT` 本身不足 2s 的池子派生出来是负数，下发后每条 SQL 一发出去就被服务端 cancel —— B1 用例用的正是 `QUERY_TIMEOUT = 1500` 的池子，这条不加判断就会把 B1 的复现条件破坏掉（而 CLAUDE.md 明确禁止调整该用例的参数）。另外补了两种显式写法：`0` = 服务端不限（照常下发），`false` / `PG_STATEMENT_TIMEOUT=off` = 一条 `SET` 都不发（完全回到老行为）。
  - **`BACKLOG` 默认值（D10）**：抽出 `resolve_backlog`，默认取 `pool_size`，并新增 `PG_BACKLOG` env 键与 `off` 关闭值。`backlog` 由 pgmoon 原样透传给 cosocket 的 `connect` 选项，给了它之后 `pool_size` 才从「空闲连接数」变成「每 worker 的并发连接数硬上限」。
  - **`Query()` 缓存冲突 WARN（D10）**：新增 `query_configs` 记录每个池首次构造时的 `ConnOpts`，命中缓存时逐键比对 `POOL_SENSITIVE_KEYS`（不含 `DEBUG` 与 `pool_name` 本身），不同就打 WARN 点名是哪个键被忽略了。**行为不变**（仍以首个实例为准，事务共享连接依赖这点），只是不再无声无息。`password` 在日志里打 `***`。每个 `(pool_name, 键)` 只提醒一次，热路径不刷屏。
  - 顺手把 `warn_legacy_timeout` 里那段 `ngx.log` / `io.stderr` 的分支抽成 `log_warn`，两处 WARN 共用一个出口。
- 与本节原方案的差异（2 处）：
  - **验收标准里的「需 nginx 环境，可先以文档说明代替」没有用上**：阶段守卫读的就是 `ngx.get_phase()`，用例里把它临时换掉即可走到与真实 `log_by_lua` 完全相同的那条分支，不需要起 nginx。所以 T14 是按「有用例」而不是「只写文档」完成的，`log`/`header_filter`/`body_filter`/`init_worker`/`set` 五个阶段各断言一次，事务入口另断言一次，用例结束前把 `ngx.get_phase` 还原并再查一次确认没有留下副作用。
  - **多加了两个用例**：`STATEMENT_TIMEOUT` 的派生值（用 `SHOW statement_timeout` 断言默认池是 `8s`、1500ms 池是 `0`、显式 `0`/`3000` 原样生效）与 `Model.LAZY_FK` 的开关效果。前者是因为「派生出非正值」会直接破坏 B1 的复现条件，必须锁住；后者是 D9 的另一半，光有阶段守卫锁不住它。
- 验收结果：4 个新增用例全绿，原有 278 例不受影响。**全量 `282 ok / 0 not ok`，无 skip / pending（TAP 计数 `1..282`）**。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/21 10:36:59 [warn] 30709#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x7fbf81b1d6d0
	[C]: at 0x7fbf81abafa0
	[C]: in function 'pcall'
	/usr/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:210):47: in function <init_worker_by_lua(nginx.conf:210):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:210):54: in function <init_worker_by_lua(nginx.conf:210):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
ok 277 - REVIEW: 疑似问题与设计建议回归 S2/T13 新建连接必须强制 standard_conforming_strings = on
ok 278 - REVIEW: 疑似问题与设计建议回归 D8/T15 终结方法必须在副本上执行（复用 builder 不串条件）
ok 279 - REVIEW: 疑似问题与设计建议回归 S3/T14 非 cosocket 阶段发查询必须报含 phase 的明确错误
2026/09/21 10:37:02 [warn] 30709#0: *2 [lua] query.lua:100: log_warn(): [model.query] Query{POOL_NAME="review_pool_warn_1789958222593"} 已被构造过，query_timeout 以首次构造的值为准：沿用 8000，忽略本次传入的 600000。需要不同配置请换一个 POOL_NAME，详见 docs/orm-index.md「数据库连接与超时」, context: ngx.timer
2026/09/21 10:37:02 [warn] 30709#0: *2 [lua] query.lua:100: log_warn(): [model.query] Query{POOL_NAME="review_pool_warn_1789958222593"} 已被构造过，statement_timeout 以首次构造的值为准：沿用 6000，忽略本次传入的 598000。需要不同配置请换一个 POOL_NAME，详见 docs/orm-index.md「数据库连接与超时」, context: ngx.timer
ok 280 - REVIEW: 疑似问题与设计建议回归 S4/T14 Query() 缓存命中且配置不同时必须记 WARN
ok 281 - REVIEW: 疑似问题与设计建议回归 S4/T14 STATEMENT_TIMEOUT 默认比 QUERY_TIMEOUT 早 2 秒，且不会派生出非正值
ok 282 - REVIEW: 疑似问题与设计建议回归 D9/T14 Model.LAZY_FK = false 时外键属性访问必须报错而不是偷偷发查询
1..282
Done in 3.79s.
```

### T15 终结方法在副本上执行（D8）

- 优先级：P3
- 涉及文件：`lib/model/sql.lua`
- 问题描述：见「请求隔离」小节与 D8。
- 修改方案：`count/exists/first/last/get/values_list/flat/dates/datetimes/aggregate` 开头 `self = self:copy()`。
- 验收标准：新增用例：`local q = Blog:where{...}; q:count(); q:exec()` 返回记录而不是 count 行；全量测试通过。
- 前置任务：T0。

- 状态：✅ 已完成（2026-09-19，提交信息含 `T15`）
- 改动文件：`lib/model/sql.lua`、`spec/review_spec.lua`（新增 1 个用例）
- 实现要点：
  - 16 个终结方法开头加 `self = self:copy()`：`count`、`exists`、`first`、`last`、`get`（`try_get` 走 `get`，自动覆盖）、`values`、`values_list`、`flat`、`dates`、`datetimes`、`aggregate`、`latest`、`earliest`、`contains`、`in_bulk`、`as_set`。完整说明写在 `count()` 里，其余指过去。
  - `copy()` 已存在（`all()` 就是它的别名），浅拷贝十几个键，相对一次数据库往返可以忽略。
  - `exec`/`execr`/`explain` **没有加**：`exec` 是所有路径的公共出口（终结方法自己也走它），在这里再拷一次纯属重复；`explain` 只读 `statement()`，本来就不改状态。
- 与本节原方案的差异（1 处，范围扩大）：
  - 原方案列了 10 个方法（`count/exists/first/last/get/values_list/flat/dates/datetimes/aggregate`），实现多加了 6 个：`values`、`latest`、`earliest`、`contains`、`in_bulk`、`as_set`。它们同样「返回数据而不是 self」且同样改写 builder——`latest`/`earliest` 直接写 `self._order = nil` 再 `order()`，`contains` 加 `where`，`in_bulk` 加 `where`，`values`/`as_set` 改 `_select`/`_compact`/`_raw`。只修列出的 10 个会留下一半同类问题，而且 `latest()` 里的 `order()` 改的是原 builder、`first()` 拷贝的是改完之后的副本，修一半反而更难解释。
- 验收结果：新增用例 `D8/T15` 修复前红、修复后绿。用例把一个 `q = ReviewEntry:where{blog_id=...}` 从头用到尾，每个终结方法调用之后都回头断言 `q` 本身没变：`count()` 后 `exec()` 仍返回 2 条**记录**（修复前返回的是 count 行）、`count(cond)` 的条件不累积、`exists()` 的 `select 1/limit 1` 不残留、`first()/last()` 的 `limit 1` 不残留、`get(cond)` 的条件与 `limit 2` 不残留、`values_list()` 之后 `_select` 不只剩 id、`latest()` 的 order 不残留，最后一次 `exec()` 与第一次的行数和行身份一致。
- **全量 `278 ok / 0 not ok`，无 skip / pending（TAP 计数 `1..278`）**。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/19 13:18:33 [warn] 53757#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x09c629e0
	[C]: at 0x09b34230
	[C]: in function 'pcall'
	/usr/local/openresty/luajit/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/local/openresty/luajit/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:216):47: in function <init_worker_by_lua(nginx.conf:216):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:216):54: in function <init_worker_by_lua(nginx.conf:216):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
ok 277 - REVIEW: 疑似问题与设计建议回归 S2/T13 新建连接必须强制 standard_conforming_strings = on
ok 278 - REVIEW: 疑似问题与设计建议回归 D8/T15 终结方法必须在副本上执行（复用 builder 不串条件）
1..278
Done in 4.27s.
```

### T16 文档修正（B14、B17、D12）

- 优先级：P3
- 涉及文件：`docs/orm-model-definition.md`、`docs/orm-query-basics.md`、`docs/orm-index.md`
- 问题描述：见 B14、B17、D12。
- 修改方案：改 `transaction` 示例为 `local ok, err = pcall(...)` 或直接说明抛错；`get` 多行说明；NULL 行为；裸 SQL 入口警示；`atomic` 内禁止 `ngx.exit`；协程逃逸限制。
- 验收标准：文档与 T1–T15 后的实现逐条对照无矛盾。
- 前置任务：T1–T15。

- 状态：✅ 已完成（2026-09-21，提交信息含 `T16`）
- 改动文件：`docs/orm-model-definition.md`、`docs/orm-query-basics.md`、`docs/orm-query-advanced.md`、`docs/orm-index.md`（纯文档，无代码改动）
- 实现要点（按来源逐条）：
  - **B14**：`Model:transaction` 的示例从 `local result, err = ...` 改成 `pcall` 包裹，并把「错误通道是抛错、绝不返回 `nil, err`」写成小节开头第一句；同时把反例（`if err then` 永远进不去）留在示例里。`orm-index.md` 速查表那一行也补上了。
  - **B17**：`Sql:get` 补「命中多行同样返回 `false`」的警告块，给出会「越修越多」的反面写法，以及两种正确做法（`limit(2)` 自己判断 / 唯一键上用 `get_or_create`）。速查表同步。
  - **B5 / D3**：`values_list` 一节补「NULL 会占位」：compact 路径（`values_list`/`flat`/`as_set`/`dates`/`datetimes`）行长度恒等于列数、`flat` 元素数恒等于 `count()`，判空必须 `v == Model.NULL` 而不是 `if v then`；非 compact 路径默认仍然缺键，要占位用 `CONVERT_NULL`。`CONVERT_NULL` 与 `BIGINT_AS_STRING` 两个连接项此前完全没文档，一并补进 `orm-index.md` 的连接项表。
  - **裸 SQL 入口（D12）**：`orm-query-basics.md` 新增「裸 SQL 入口清单」一节，把 `where(string)`/`where_or`/`or_where`/`exclude`/`having`、三种回调、`from`/`using`、`with(name, string)`、`Model.token`、`exec_statement`/`Model.query` 列成表并统一警示；`meta_query` 一节补「只接受数据」的参数类型白名单表与四个正反例。
  - **S1**：`transaction` 一节新增「callback 里不要调 `ngx.exit` / `ngx.eof`」，写清 `lua_yield` 跨 `xpcall` 的机理与「写完响应却没提交」的现象，给出「先让 transaction 返回，再在事务外 exit」的做法。
  - **B10**：同一节新增「协程逃逸」，给出 `coroutine.wrap` 里的写入自动提交、回滚不了的完整例子（已实测：`esc_exists=true` / `tx1_exists=false`）。
  - **B2**：新增「被吞掉的错误会阻止提交」，说明 PG 的 aborted 会话语义、`transaction aborted by earlier error` 这条错误，以及替代写法（savepoint / `ON CONFLICT`）。
  - **F1 遗留**：`Sql:update` 一节补全表写防呆与 `allow_full_table()`，写清「只在真正执行时检查、子查询/CTE 不拦」与「`delete()` 不传条件本身就是删全表」两条语义；`Sql:delete` 一节补 `delete(cond)` 的 `cond` 为 nil 时等于删全表的陷阱。速查表补 `Sql:allow_full_table()`。
  - **F5 遗留**：`orm-index.md` 新增「会话参数：ORM 管什么、不管什么」，说明只强制 `standard_conforming_strings`（安全修复）、会话时区交给部署方（`PGTZ` / `PGOPTIONS` / `ALTER ROLE`）及其理由。
  - **B3 / D4**：字段文档 `integer` 一节新增「大整数（bigint）」与「数字字面量」两小节：`bigint` 选项、三种传值形态的正反例、`BIGINT_AS_STRING` 读回开关，以及 `resty.migrate` 按 `type` 而非 `db_type` 建表这一限制（见下面的 F9）。
  - **B4 / T5**：`date/datetime/time` 一节补「带偏移量的值原样入库」，说明 CTE 路径用 `::timestamptz` 而不是 `::timestamp`，以及 `Validator.datetime`（表单口径）与 `Validator.datetime_tz`（入库口径）的分工。
  - **B6**：通用字段选项表的 `default` 行补「table 型每次取用都会 clone」，正文说明污染字段定义的后果，并写明 `default = false` 现在算「有默认值」。
  - **B13 / F4**：`json` 一节补「空表编码成 `[]` 不是 `{}`」的取舍说明与需要存空对象时的替代方案。
  - **B8 / B16 / F3**：`where` 的键值对形式补 `Model.NULL` → `IS NULL` / `IS NOT NULL`；情形 4 补「值不能是 nil」的报错说明与「两参/三参不认 `Model.NULL`」的警告；情形 5 补「第三个参数为 nil 会退化成两参、把运算符当成值」的例子。
  - **B12**：`in_bulk` 补 `in_bulk({})` 返回空表的例子与理由。
  - **B7 / D7**：`get_or_create` 补「校验口径与 `update_or_create` 一致」（`validate_update` + `prepare_for_db`、`skip_validate` 的范围、`compact`/`trim` 对唯一键查找的影响）。
  - **T13**：裸 SQL 一节末尾说明「每条新建连接强制 `SET standard_conforming_strings = on`，设不上就拒绝使用这条连接」，把原来「请勿把它改成 off」的请求式表述换成现在的强制事实。
  - 顺手修了 `orm-query-advanced.md` 里 `select_for_update` 示例漏 `:exec()` 的问题（`update()` 只挂条件，不执行），并从那里链到事务一节的四条限制。
- 与本节原方案的差异（1 处，范围扩大）：原方案只列了 B14、B17、D12 三组。实际对照下来，T4（bigint / 数字字面量）、T5（datetime 偏移）、T6（table 型 default）、T7（`get_or_create` 校验）、T9（`CONVERT_NULL`）、T12（JSON 空表）、T13（`standard_conforming_strings`）这些**改变了用户可见语义**的任务都没有对应文档，以及 F1 的 `allow_full_table`、F5 的会话时区两条遗留，一并补齐——否则「文档与实现逐条对照无矛盾」这个验收标准过不了。
- 验收结果：无代码改动，**全量 `282 ok / 0 not ok`，无 skip / pending（TAP 计数 `1..282`）**。文档里每条新写的行为都在 `scratchpad/verify_docs.lua` 里实跑确认过（`allow_full_table` 放行、`delete()` 删全表、嵌套事务报 `transaction already started`、`transaction` 抛错、aborted 事务的错误信息、协程逃逸的 `esc_exists=true`/`tx1_exists=false`、`get` 命中多行返回 `false`）。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/21 10:42:08 [warn] 436#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x7f5b3cd9c6d0
	[C]: at 0x7f5b3cd39fa0
	[C]: in function 'pcall'
	/usr/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:210):47: in function <init_worker_by_lua(nginx.conf:210):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:210):54: in function <init_worker_by_lua(nginx.conf:210):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
ok 277 - REVIEW: 疑似问题与设计建议回归 S2/T13 新建连接必须强制 standard_conforming_strings = on
ok 278 - REVIEW: 疑似问题与设计建议回归 D8/T15 终结方法必须在副本上执行（复用 builder 不串条件）
ok 279 - REVIEW: 疑似问题与设计建议回归 S3/T14 非 cosocket 阶段发查询必须报含 phase 的明确错误
2026/09/21 10:42:12 [warn] 436#0: *2 [lua] query.lua:100: log_warn(): [model.query] Query{POOL_NAME="review_pool_warn_178995853236"} 已被构造过，query_timeout 以首次构造的值为准：沿用 8000，忽略本次传入的 600000。需要不同配置请换一个 POOL_NAME，详见 docs/orm-index.md「数据库连接与超时」, context: ngx.timer
2026/09/21 10:42:12 [warn] 436#0: *2 [lua] query.lua:100: log_warn(): [model.query] Query{POOL_NAME="review_pool_warn_178995853236"} 已被构造过，statement_timeout 以首次构造的值为准：沿用 6000，忽略本次传入的 598000。需要不同配置请换一个 POOL_NAME，详见 docs/orm-index.md「数据库连接与超时」, context: ngx.timer
ok 280 - REVIEW: 疑似问题与设计建议回归 S4/T14 Query() 缓存命中且配置不同时必须记 WARN
ok 281 - REVIEW: 疑似问题与设计建议回归 S4/T14 STATEMENT_TIMEOUT 默认比 QUERY_TIMEOUT 早 2 秒，且不会派生出非正值
ok 282 - REVIEW: 疑似问题与设计建议回归 D9/T14 Model.LAZY_FK = false 时外键属性访问必须报错而不是偷偷发查询
1..282
Done in 3.79s.
```

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

### F2 [中] pgmoon 未暴露 `ReadyForQuery` 的事务状态字节，连接健康检查只能靠返回值形态推断

- 发现于：T1 实现。D1 的「根本兜底」是让 `release()` 在 PG 会话状态不是 `I`（idle）时一律 `disconnect`，这需要 pgmoon 的 `receive_query_result` 把 `ready_for_query` 消息体里的状态字节（`I`/`T`/`E`）记到 `self.txn_status`。
- 处置：按 CLAUDE.md「不要修改 pgmoon」跳过。T1 改用**返回值形态**推断：错误分支里 `num_queries` 位上不是 number ⇒ 没等到 `ReadyForQuery` ⇒ 传输层错误 ⇒ `broken`。
- 这个替代判据的覆盖差异：
  - 能覆盖：读超时、连接中断、`receive_message` 失败等所有「没走到 `ReadyForQuery`」的情况（B1 的全部触发条件）。
  - 覆盖不到：查询**成功返回**但会话仍处于 `T`（事务未收尾）的连接。目前只有「调用方绕过 `transaction()` 手工发 `BEGIN`」会造成，`transaction()` 自身的路径由 T2 的 `in_transaction`/`aborted` 状态机覆盖。
  - 误判方向是安全的：`simple_query` 的客户端前置检查（如 `invalid null byte in query`）也会被当成 `broken` 而多关一条连接，代价只是一次重连。
- 遗留：若将来允许改 pgmoon fork，按 D1 加 `self.txn_status` 后，`release()` 应改为「`txn_status ~= 'I'` 一律 disconnect」，本条可关闭。

### F3 [中] 两参/三参 `where('col', Model.NULL)` 仍生成 `= NULL`

- 发现于：T8 实现。B8 的位置只写了 `expr.lua` 的 `eq`/`ne` 与 `_get_condition_token_from_table`，T8 的涉及文件也只有 `expr.lua`，而 `where` 的两参/三参形式在 `sql.lua:_get_condition_token` 里**自己拼** `%s = %s`，不经过 `EXPR_OPERATORS`：

```lua
Entry:where('rating', Model.NULL):statement()        -- ... WHERE T.rating = NULL（恒假）
Entry:where('rating', '=', Model.NULL):statement()   -- 同上
Entry:where { rating = Model.NULL }:statement()      -- ... WHERE T.rating IS NULL（T8 已修）
```

- 后果与 B8 完全相同（静默空集），只是入口不同；触发概率低于 table 形式，但「同一个语义两种写法给出不同 SQL」本身就是坑。
- 处置：按 CLAUDE.md「发现文档未列出的新问题追加到本节，不要直接改」，本次不改。
- 建议改法（一行）：`_get_condition_token` 的两参分支把 `format("%s = %s", col, as_literal(op))` 换成 `EXPR_OPERATORS.eq(col, op)`；三参分支在 `op` 为 `=`/`<>` 且值为 NULL 时同样改走 `eq`/`ne`，其余操作符保持原样（`> NULL` 这类写法本身就没有意义，让它照常生成即可）。

### F4 [低] 修掉 B13 之后，本意为「空对象」的 `{}` 会被编码成 `[]`

- 发现于：T12 实现。Lua 里 `{}` 既是空表也是空数组，cjson 只能二选一：
  - 修复前（`encode_empty_table_as_object` 默认 true）：空数组丢失，`{"tags":[]}` 写回变 `{"tags":{}}`（就是 B13）；
  - 修复后（false）：空对象丢失，本意是 `{}` 的空表被编码成 `[]`。
- 取舍依据：JSON 字段里出现的空表绝大多数是空数组（`tags`/`items`/`children`/`attachments`），编码成 `{}` 会让按数组处理的前端直接崩；而空对象在业务上通常可以用「字段缺失」或 `null` 表达。这也是 B13 在报告里的定性（空数组变空对象是 bug）。
- 影响面：只影响 json/jsonb 字段里**深层**的空表。顶层 `array`/`table` 字段走 `encode_as_array`（`empty_array_mt`），本来就稳定输出 `[]`，不受这条影响。
- 若某个业务确实需要存空对象：存一个带哨兵键的对象（如 `{ _empty = true }`），或把该字段拆成独立列。彻底的做法是给 cjson 实例加「空对象标记元表」，但当前 `lua-cjson` 只提供 `empty_array_mt`，没有对应的空对象标记，需要改 C 模块，不在本次范围内。

### F5 [低] T13 只恢复了 `standard_conforming_strings`，`SET TIME ZONE` 没有恢复

- 发现于：T13 实现。`lib/model/query.lua` 里被注释掉的那段代码除了 `standard_conforming_strings`，还有一条按 `PGTIMEZONE`（默认 `Asia/Shanghai`）下发的 `SET TIME ZONE`，来自上游模板。
- 没恢复的理由：两条性质完全不同。`standard_conforming_strings = on` 是**安全修复**——不锁住它，`as_literal` 的转义假设就不成立；`SET TIME ZONE` 是**行为选择**——`datetime` 列是 `timestamptz`，会话时区只改变回读的字符串形态（同一时刻，不同写法），不锁定也不会读错数据。在库里强行写死一个业务时区，会让所有使用方的回读格式随 ORM 版本变化，还会与 T5（B4）刚统一的「带偏移量的字面量原样入库」口径纠缠。
- 影响：同一份数据在 PG 会话 UTC 与应用机 UTC+8 下解析出的**字符串**不同。需要固定回读形态的部署，应在 `.env` 里配 `PGTZ`/`PGOPTIONS`，或在角色级 `ALTER ROLE ... SET timezone`，而不是由 ORM 代劳。
- 建议：T16 写文档时在「数据库连接与超时」一节说明这条：ORM 只强制 `standard_conforming_strings`，会话时区交给部署方。

### F6 [高] `as_literal` 现在会拒绝所有大浮点数，`float` 列出现回归

- 发现于：T14/T16 完工后回头复查 T4 的实现（`lib/model/utils.lua` 的 `number_literal`）。
- 现象：判据是 `value % 1 ~= 0` 才算「非整数」，而 `1e20`、`1e300` 这些**浮点数**的小数部分同样是 0，于是被当成「超过 2^53 的整数」直接抛错：

```lua
Model.as_literal(1e20)    -- ERR integer 100000000000000000000 exceeds 2^53 and has already lost precision ...
Model.as_literal(1e300)   -- ERR 同上
P:where { score = 1e20 }:statement()  -- 同样报错，score 是 float 列
```

- 与修复前的对比：T4 之前走 `tostring`，渲染成 `1e+20` / `1e+300`，PG 的 `float8`/`numeric` 解析这两个字面量完全正常。所以这是一条**由 B3 的修复引入的回归**：原本能跑的代码现在在拼 SQL 阶段就崩。
- 影响面：任何往 `float` / `double precision` / `numeric` 列写大数量级值的业务（科学计量、天文/金融的极值、某些用浮点存的计数器）。整数列不受影响（本来就该报错）。现有测试没有覆盖大浮点，所以全绿。
- 根因：`number_literal` 在**字面量层**做整数精度检查，而字面量层拿不到目标列的类型——它无法区分「调用方写的是一个整数，只是超了 2^53」和「调用方写的就是一个浮点数」。
- 处置：按 CLAUDE.md「发现文档未列出的新问题追加到本节，不要直接改」，发现时未改；2026-09-21 经用户确认后修复。
- 状态：✅ 已修复（2026-09-21，提交信息含 `F6`）
- 改动文件：`lib/model/utils.lua`、`lib/model/fields.lua`、`lib/model/parser.lua`、`lib/model/sql.lua`、`spec/review_spec.lua`（新增 1 个用例）、`docs/orm-model-definition.md`
- 实现要点：
  - **字面量层按量级分三档**（`utils.number_literal`）：`|v| <= 2^53` 照旧 `%d`；`|v| >= 2^63` 超出 int8，任何整数列都装不下，只可能是浮点，交给新增的 `float_literal`（最短往返渲染，见 F7）；中间的 `(2^53, 2^63)` 是雪花 ID / bigint 的量级，**仍然报错**——字面量层拿不到列类型，这一档放行就等于撤掉 B3 的修复（`review_spec` B3 用例锁的 `123456789012345678` 正落在这里）。报错信息补了一句浮点值的字符串写法。
  - **列类型已知时由 float 字段接走中间那一档**：新增 `utils.float_column_value`，把这一档的 number 转成预先渲染好的浮点 token（函数值，`as_literal` 原样拼接）。
    - 写入：`FloatField:prepare_for_db` 调它。`prepared` 只用于拼 SQL，回填给调用方的是 `RETURNING` 的值，看不到这个 token。覆盖 `create` / `insert` / `update` / `updates` / `merge` / `upsert`。
    - 条件：`parser.parse_column` 增加第三个返回值——最终被比较的那一列的字段。只在解析到实体列时记录，json 路径段、annotate、反向外键一律清空，避免把 json 子路径误认成 float 列。`_get_condition_token_from_table` 本来就把 `_parse_column(k)` 的返回值整体透传给 `_get_expr_token`，于是 `where{}` / `exclude{}` / `Q{}` 自动拿到字段；`_get_expr_token` 对 float 字段的 `eq/ne/lt/lte/gt/gte` 转单值、`in/notin/range` 逐个转元素。两参/三参的 `where('score', v)` / `where('score', '>', v)` 在 `_get_condition_token` 里单独处理。
    - 其余调用点只取 `_parse_column` 的前一两个返回值（`local col, op =`、括号截断、`format` 中间参数），多一个返回值不改变它们的行为。
- 与建议改法的差异：建议里只写了「超出 2^63 按浮点渲染」。只做这一半的话，`(2^53, 2^63)` 里的 float 值照样报错，而修复 B3 之前它们是能写能查的，所以回归只修了一半。补上 float 字段这条路后，这一档对 float 列的写入与条件都恢复可用，对整数列与不知道列类型的裸 `as_literal` 仍然报错。
- 验收结果：新增用例覆盖三档字面量、float 列的 6 种写入/条件写法与整数列仍报错；修复前该用例为 `not ok`（已用 `git stash` 回退 `lib/` 实测），修复后转绿。**全量 `283 ok / 0 not ok`，无 skip / pending（TAP 计数 `1..283`）**。
- 建议改法：把「超过 2^53 就报错」的判据收紧到**看起来像整数**的那一档。一个可行的口径是只对 `|value| < 2^63` 的整数值做精确性检查（雪花 ID / 数据库 bigint 的实际范围），超出这个范围的一律按浮点走 `%.17g` 渲染——真正想写 bigint 的人不会写出 `1e20` 这种量级，而想写浮点的人也不该被整数规则拦住。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/21 11:48:17 [warn] 967#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x7f95441726d0
	[C]: at 0x7f954410ffa0
	[C]: in function 'pcall'
	/usr/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:211):47: in function <init_worker_by_lua(nginx.conf:211):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:211):54: in function <init_worker_by_lua(nginx.conf:211):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
ok 277 - REVIEW: 疑似问题与设计建议回归 S2/T13 新建连接必须强制 standard_conforming_strings = on
ok 278 - REVIEW: 疑似问题与设计建议回归 D8/T15 终结方法必须在副本上执行（复用 builder 不串条件）
ok 279 - REVIEW: 疑似问题与设计建议回归 S3/T14 非 cosocket 阶段发查询必须报含 phase 的明确错误
2026/09/21 11:48:21 [warn] 967#0: *2 [lua] query.lua:100: log_warn(): [model.query] Query{POOL_NAME="review_pool_warn_1789962501046"} 已被构造过，query_timeout 以首次构造的值为准：沿用 8000，忽略本次传入的 600000。需要不同配置请换一个 POOL_NAME，详见 docs/orm-index.md「数据库连接与超时」, context: ngx.timer
2026/09/21 11:48:21 [warn] 967#0: *2 [lua] query.lua:100: log_warn(): [model.query] Query{POOL_NAME="review_pool_warn_1789962501046"} 已被构造过，statement_timeout 以首次构造的值为准：沿用 6000，忽略本次传入的 598000。需要不同配置请换一个 POOL_NAME，详见 docs/orm-index.md「数据库连接与超时」, context: ngx.timer
ok 280 - REVIEW: 疑似问题与设计建议回归 S4/T14 Query() 缓存命中且配置不同时必须记 WARN
ok 281 - REVIEW: 疑似问题与设计建议回归 S4/T14 STATEMENT_TIMEOUT 默认比 QUERY_TIMEOUT 早 2 秒，且不会派生出非正值
ok 282 - REVIEW: 疑似问题与设计建议回归 D9/T14 Model.LAZY_FK = false 时外键属性访问必须报错而不是偷偷发查询
ok 283 - REVIEW: 执行中发现（F 系列）回归 F6 大浮点数不能被当成丢了精度的整数拒掉（float 列回归）
1..283
Done in 3.81s.
```

### F7 [中] 非整数的数字字面量仍然走 `tostring`（`%.14g`），浮点精度照样静默丢失

- 发现于：同上。B3 的标题是「大整数在写入和读回两个方向都会静默失真」，T4 只修了整数那一半，浮点那一半原样留着：

```lua
Model.as_literal(0.1 + 0.2)   -- '0.3'              （真值 0.30000000000000004）
Model.as_literal(1/3)         -- '0.33333333333333' （只剩 14 位有效数字）
Model.as_literal(1e15 + 0.5)  -- '1e+15'            （.5 直接没了，还是科学计数法）
```

- 后果与 B3 完全同源：`double precision` 列写进去的值不是调用方给的那个值，`WHERE score = x` 匹配不到自己刚写进去的行，而且全程不报错。
- 严重度低于 F6 的原因：这是**修复前就存在**的行为，不是回归；且 `float8` 列上 14 位有效数字对多数业务够用。
- 处置：发现时按 CLAUDE.md 未改；2026-09-21 经用户确认后修复。
- 状态：✅ 已修复（2026-09-21，提交信息含 `F7`）
- 改动文件：`lib/model/utils.lua`、`spec/review_spec.lua`（新增 1 个用例）、`docs/orm-model-definition.md`
- 实现要点：`number_literal` 的非整数分支从 `tostring(value)` 换成 F6 引入的 `float_literal`，即建议改法里的最短往返：依次试 `%.15g`、`%.16g`、`%.17g`，取第一个 `tonumber()` 回来与原值相等的。17 位是 IEEE 754 双精度的往返保证位数，所以最后一档必然成立。先试 15 位是为了让 `0.1`、`3.14` 这类值保持原样，不会变成 `0.10000000000000001`，SQL 日志的可读性不受影响。
- 兼容性：对原本就能用 ≤14 位有效数字精确表示的值（绝大多数业务里写的小数），15 位与 14 位的输出完全相同，所以既有用例的 SQL 断言一条都没受影响。输出只在原来会丢精度的那些值上变长。
- 验收结果：新增用例断言 5 个典型值的渲染，并实写 `float` 列后按同一个值 `where` 查回自己、读回值逐位相同。修复前该用例为 `not ok`（`git stash` 回退 `lib/` 实测），修复后转绿。**全量 `284 ok / 0 not ok`，无 skip / pending（TAP 计数 `1..284`）**。
- 建议改法：非整数分支从 `tostring(value)` 换成 `format("%.17g", value)`。17 位是 IEEE 754 双精度的往返（round-trip）保证位数，PG 侧解析回来与 Lua 里的 double 逐位相同。代价是 `0.1` 会渲染成 `0.10000000000000001` —— 如果嫌难看，可以先试 `%.15g`、`%.16g`、`%.17g`，取第一个 `tonumber()` 回来等于原值的（shortest round-trip，标准做法）。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/21 11:49:54 [warn] 2498#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x7f7ef87fd6d0
	[C]: at 0x7f7ef879afa0
	[C]: in function 'pcall'
	/usr/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:210):47: in function <init_worker_by_lua(nginx.conf:210):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:210):54: in function <init_worker_by_lua(nginx.conf:210):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
ok 277 - REVIEW: 疑似问题与设计建议回归 S2/T13 新建连接必须强制 standard_conforming_strings = on
ok 278 - REVIEW: 疑似问题与设计建议回归 D8/T15 终结方法必须在副本上执行（复用 builder 不串条件）
ok 279 - REVIEW: 疑似问题与设计建议回归 S3/T14 非 cosocket 阶段发查询必须报含 phase 的明确错误
2026/09/21 11:49:57 [warn] 2498#0: *2 [lua] query.lua:100: log_warn(): [model.query] Query{POOL_NAME="review_pool_warn_1789962597887"} 已被构造过，query_timeout 以首次构造的值为准：沿用 8000，忽略本次传入的 600000。需要不同配置请换一个 POOL_NAME，详见 docs/orm-index.md「数据库连接与超时」, context: ngx.timer
2026/09/21 11:49:57 [warn] 2498#0: *2 [lua] query.lua:100: log_warn(): [model.query] Query{POOL_NAME="review_pool_warn_1789962597887"} 已被构造过，statement_timeout 以首次构造的值为准：沿用 6000，忽略本次传入的 598000。需要不同配置请换一个 POOL_NAME，详见 docs/orm-index.md「数据库连接与超时」, context: ngx.timer
ok 280 - REVIEW: 疑似问题与设计建议回归 S4/T14 Query() 缓存命中且配置不同时必须记 WARN
ok 281 - REVIEW: 疑似问题与设计建议回归 S4/T14 STATEMENT_TIMEOUT 默认比 QUERY_TIMEOUT 早 2 秒，且不会派生出非正值
ok 282 - REVIEW: 疑似问题与设计建议回归 D9/T14 Model.LAZY_FK = false 时外键属性访问必须报错而不是偷偷发查询
ok 283 - REVIEW: 执行中发现（F 系列）回归 F6 大浮点数不能被当成丢了精度的整数拒掉（float 列回归）
ok 284 - REVIEW: 执行中发现（F 系列）回归 F7 非整数的数字字面量必须能逐位往返（不能走 %.14g）
1..284
Done in 3.83s.
```

### F8 [中] B16 的修复只覆盖了 `Sql:where`，同族入口与三参形式仍然静默生成错误 SQL

- 发现于：同上。T11 把参数个数判断加在了 `Sql:where` 上，但条件类入口不止这一个：

```lua
P:where_or('ok', nil):statement()      -- SELECT ... WHERE ok          （B16 原样复现）
P:or_where('ok', nil):statement()      -- SELECT ... WHERE ok
P:or_where_or('ok', nil):statement()   -- SELECT ... WHERE ok
P:delete('ok', nil):statement()        -- DELETE FROM p AS T WHERE ok  （删掉所有 ok 为真的行）
```

  `count(cond, op, dval)` / `get` / `delete` 这类转发方法总是按三个实参调 `where`，所以它们的两参调用（`Model:delete('ok', nil)`）也绕过了守卫。

- 更糟的是**三参形式**，它连 B16 的警示都没有，而且退化得更隐蔽 —— 把运算符当成了值：

```lua
P:where('ok', '=', nil):statement()    -- WHERE T.ok = '='
P:where('n', '>', nil):statement()     -- WHERE T.n = '>'
```

- 后果：与 B16 相同（boolean 列静默改变筛选语义），但 `delete` 这条是**数据丢失**级别的。
- 与 F3 的区别：F3 说的是 `where('col', Model.NULL)` 生成恒假的 `= NULL`（空集，方向安全）；本条说的是 `nil`，方向是「条件被悄悄换成另一个条件」。两条都落在 `_get_condition_token` 的两参/三参分支上，适合一起改。
- 处置：发现时按 CLAUDE.md 未改；2026-09-21 经用户确认后修复。
- 状态：✅ 已修复（2026-09-21，提交信息含 `F8`）
- 改动文件：`lib/model/sql.lua`、`spec/review_spec.lua`（新增 1 个用例）、`docs/orm-query-basics.md`
- 实现要点：
  - 把 `Sql:where` 里那段 `select('#')` 判断抽成 `sql.lua` 的局部函数 `check_condition_args(method, argc, cond, op, dval)`，报错信息里的方法名用调用方实际调的那个（`delete('ok', nil): value is nil ...`），不会一律显示成 `where`。
  - **条件入口**：`where` / `where_or` / `or_where` / `or_where_or` / `exclude` 全部改成以 `...` 接参，先调守卫再走原逻辑。
  - **转发方法**：`delete` / `count` / `get` / `try_get` 改成以 `...` 接参，各自先按自己的名字调一次守卫，再**原样转发 `...`** 给 `where`。F8 的根因正是这些方法按三个具名形参转发，把 `delete('ok', nil)` 补成了三个实参。
  - **三参形式**：`argc >= 3`、`dval == nil`、第二参是 `PG_OPERATORS` 里的运算符时报错。第二参**不是**运算符时仍按两参处理，这是为了兼容 `function(c, o, v) return M:where(c, o, v) end` 这类定长转发的两参调用：`where('name', 'x', nil)` 照旧是 `T.name = 'x'`。
- 没有改的边界：
  - `where('ok', nil, nil)` 这种三个实参、后两个都是 nil 的调用，与「定长转发的一参裸 SQL」无法区分，仍按裸 SQL 处理。框架自己的转发已全部改成原样转发 `...`，这种形态只会来自调用方自己的定长封装。
  - 一参 `delete(nil)` 仍等价于 `delete()`（删全表），这是既有的文档化语义，不在本条范围内，另记为 F11。
  - F3（两参/三参 `Model.NULL` 生成 `= NULL`）同样落在 `_get_condition_token`，但不在本次修复范围内，未动。
- 验收结果：新增用例对 8 个入口的两参 nil、5 个入口的三参 nil 断言报错，并断言一参裸 SQL、两参、三参、定长转发两参、`delete()` 这些合法写法不受影响。修复前该用例为 `not ok`（`git stash` 回退 `lib/` 实测），修复后转绿。**全量 `285 ok / 0 not ok`，无 skip / pending（TAP 计数 `1..285`）**。
- 建议改法：把 `Sql:where` 里那段 `select('#', ...)` 的判断下沉到 `Sql:_get_condition_token`（以及 `_get_condition_token_or`），让所有入口共用；同时在三参分支里，`dval == nil` 时也报同一条错误，而不是滑进两参分支。转发方法（`count`/`get`/`delete`）改成按实际传入个数转发，或者在自己那一层先判断。

测试命令：

```sh
yarn test
```

完整输出：

```tap
yarn run v1.22.22
$ LUA_PATH='/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;;' LUA_CPATH='/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;' yarn resty -I spec bin/ngx_busted.lua -o TAP
$ resty -I lib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec bin/ngx_busted.lua -o TAP
2026/09/21 11:52:26 [warn] 4164#0: *2 [lua] _G write guard:12: writing a global Lua variable ('lfs') which may lead to race conditions between concurrent requests, so prefer the use of 'local' variables
stack traceback:
	[C]: at 0x7f38a59ef6d0
	[C]: at 0x7f38a598cfa0
	[C]: in function 'pcall'
	/usr/share/lua/5.1/pl/path.lua:24: in main chunk
	[C]: in function 'require'
	/usr/share/lua/5.1/busted/runner.lua:3: in main chunk
	[C]: in function 'require'
	bin/ngx_busted.lua:6: in function 'file_gen'
	init_worker_by_lua(nginx.conf:210):47: in function <init_worker_by_lua(nginx.conf:210):45>
	[C]: in function 'xpcall'
	init_worker_by_lua(nginx.conf:210):54: in function <init_worker_by_lua(nginx.conf:210):52>, context: ngx.timer
ok 1 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1: _parse_having_column 必须拒绝嵌套 traversal
ok 2 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B1b: _parse_having_column 拒绝未知 op
ok 3 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2: annotate 后再 traversal 应当显式报错
ok 4 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B2b: annotate + 单个 op 仍然合法
ok 5 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化
ok 6 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素
ok 7 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作
ok 8 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)
ok 9 - sql.lua _parse_column / _parse_having_column 已修复 bug BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文
ok 10 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较
ok 11 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: text 类 op (startswith) 走 ->> 文本提取
ok 12 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 多段 + 普通 op 走 #> jsonb
ok 13 - sql.lua _parse_column / _parse_having_column 已修复 bug JSON path: 现有 has_key / contains / eq 行为不变
ok 14 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B3: __year 用半开区间而非 BETWEEN，timestamp 列不漏年末数据
ok 15 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B4: 自引用 FK 传表值能取出 reference_column
ok 16 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B5: 两个 FK 指向同一 model 且都用默认 related_query_name 应报错
ok 17 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B6: related_query_name 与被引用方实体字段同名应报错
ok 18 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B8: time/datetime 边界与负时区
ok 19 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B9: copy() 不克隆 model，身份比较保持成立
ok 20 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10a: split_string 支持任意长度分隔符
ok 21 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10b: get_keys 的 columns 种子参与去重且不丢失
ok 22 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10c: 数字 choices 的 StringField 不再崩溃
ok 23 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-B10d: F 表达式用于 json 字段不再被 cjson 编码
ok 24 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D3: 空 __in 报错信息带列名
ok 25 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D11: 复合 Q 在 having 里保持 having 解析路径
ok 26 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D12: 字段名与 Model/Sql 方法同名应报错
ok 27 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D13: 单段整数样式 JSON 路径按数组下标 (Django 对齐)
ok 28 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D14: annotate 别名为 PG 关键字时自动加引号
ok 29 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D15: group 自动 select 不重复追加已选列
ok 30 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D17: Count DISTINCT / FILTER 语法生成
ok 31 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D16: 无法推断子查询列名时提前报错
ok 32 - REVIEW 2026-07-15 回归 (statement 级，无 DB) REVIEW-D10: TableField 显式 max_rows 才校验行数
ok 33 - 1. 模型定义 Model:create_model 基础属性
ok 34 - 1. 模型定义 Model:create_model mixins 覆盖父字段属性
ok 35 - 1. 模型定义 auto_primary_key=false 不自动生成 id
ok 36 - 1. 模型定义 unique_together 标准化为 [[...]]
ok 37 - 1. 模型定义 外键 reversed_fields 自动登记到目标模型
ok 38 - 1. 模型定义 Model(opts) 简写自动混入 BaseModel (id/ctime/utime)
ok 39 - 1. 模型定义 Model:is_model_class / is_instance
ok 40 - 1. 模型定义 Model:check_unique_key
ok 41 - 1. 模型定义 Model:to_json 导出元数据
ok 42 - 1. 模型定义 Model:make_field_from_json 动态构造字段
ok 43 - 2. SELECT select 单个字段
ok 44 - 2. SELECT select 多字段 (vararg)
ok 45 - 2. SELECT select 多字段 (table)
ok 46 - 2. SELECT select 链式追加
ok 47 - 2. SELECT select 不调用 = SELECT *
ok 48 - 2. SELECT select_as 重命名字段
ok 49 - 2. SELECT select_literal 选择字面量
ok 50 - 2. SELECT select_literal_as 命名字面量 (含空格)
ok 51 - 2. SELECT select_literal_as 命名字面量 (无空格)
ok 52 - 2. SELECT select 外键字段 (跨表)
ok 53 - 2. SELECT select_as 跨表字段重命名
ok 54 - 2. SELECT select 嵌套外键 (ViewLog -> Entry -> Blog)
ok 55 - 2. SELECT select_as 嵌套外键重命名
ok 56 - 2. SELECT select 反向外键
ok 57 - 2. SELECT select 反向外键 + order_by ASC
ok 58 - 2. SELECT select 反向外键 + order_by DESC
ok 59 - 2. SELECT only 覆盖式选择列
ok 60 - 2. SELECT defer 排除指定列
ok 61 - 3. WHERE 基础等值
ok 62 - 3. WHERE 比较运算符 __gt / __lt / __gte / __lte / __ne
ok 63 - 3. WHERE __in / __notin
ok 64 - 3. WHERE __range
ok 65 - 3. WHERE __contains / __icontains / __startswith / __endswith
ok 66 - 3. WHERE __null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)
ok 67 - 3. WHERE 跨表 (1 级) 正向外键
ok 68 - 3. WHERE 跨表 (1 级) 正向外键 + lookup
ok 69 - 3. WHERE 跨表 (2 级) ViewLog -> Entry -> Blog
ok 70 - 3. WHERE 跨表 + 同一查询多次 where (AND)
ok 71 - 3. WHERE 反向外键
ok 72 - 3. WHERE 两参数 where
ok 73 - 3. WHERE 三参数 where
ok 74 - 3. WHERE 两参数 where 跨表
ok 75 - 3. WHERE Q 对象: OR
ok 76 - 3. WHERE Q 对象: AND
ok 77 - 3. WHERE Q 对象: NOT
ok 78 - 3. WHERE Q 嵌套 + 跨表
ok 79 - 3. WHERE 反向 FK + 正向 FK + 反向 FK 链路 (Django parity, 三次 JOIN)
ok 80 - 3. WHERE 正向 FK + 反向 FK 链路 (case 4 修复在 1.4.2 cascade 也成立)
ok 81 - 3. WHERE 链路缓存: 同一条 chain 多次 where 不重复建 join
ok 82 - 3. WHERE 简单反向 FK 不受 case 4 修复影响 (regression)
ok 83 - 3. WHERE 跨 jsonb / model 字段链路保留 json_keys (issue #5 regression)
ok 84 - 3. WHERE 非法链路报错信息包含上下文 (issue #4)
ok 85 - 3. WHERE having 支持普通字段 (issue #8)
ok 86 - 3. WHERE exclude 单条件
ok 87 - 3. WHERE exclude 多条件 (整体 NOT)
ok 88 - 3. WHERE exclude + Q
ok 89 - 3. WHERE where_in (单列)
ok 90 - 3. WHERE where_in (子查询)
ok 91 - 3. WHERE where_in (多列)
ok 92 - 3. WHERE where_not_in
ok 93 - 3. WHERE where_or 表内 OR
ok 94 - 3. WHERE or_where 与上一个 where 用 OR
ok 95 - 3. WHERE annotate 后再 traversal 显式报错 (B2)
ok 96 - 3. WHERE annotate + 单个 op 仍然合法 (cnt__gte)
ok 97 - 3. WHERE blog_id__id__notop 错误信息保留 FK 上下文 (B4)
ok 98 - 3. WHERE blog_id__id 冗余 FK 后缀仍正常生成 (回归)
ok 99 - 4. ORDER / LIMIT / OFFSET / DISTINCT order ASC / DESC
ok 100 - 4. ORDER / LIMIT / OFFSET / DISTINCT order_by 别名
ok 101 - 4. ORDER / LIMIT / OFFSET / DISTINCT 多字段 order
ok 102 - 4. ORDER / LIMIT / OFFSET / DISTINCT nulls_last / nulls_first
ok 103 - 4. ORDER / LIMIT / OFFSET / DISTINCT reverse 翻转排序
ok 104 - 4. ORDER / LIMIT / OFFSET / DISTINCT limit / offset
ok 105 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct (无参)
ok 106 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct ON
ok 107 - 4. ORDER / LIMIT / OFFSET / DISTINCT distinct_on 自动 prepend ORDER BY
ok 108 - 5. GROUP BY / HAVING group + annotate Count
ok 109 - 5. GROUP BY / HAVING group + annotate Sum
ok 110 - 5. GROUP BY / HAVING 数字索引 annotate 自动命名
ok 111 - 5. GROUP BY / HAVING having
ok 112 - 5. GROUP BY / HAVING having + Q
ok 113 - 5. GROUP BY / HAVING alias 不加入 SELECT 但可在 having 引用
ok 114 - 5. GROUP BY / HAVING aggregate 终端方法
ok 115 - 5. GROUP BY / HAVING aggregate StdDev (样本)
ok 116 - 5. GROUP BY / HAVING Count DISTINCT
ok 117 - 5. GROUP BY / HAVING Count + FILTER (kwargs 条件表)
ok 118 - 5. GROUP BY / HAVING Count + FILTER (Q 复合条件)
ok 119 - 5. GROUP BY / HAVING DISTINCT + FILTER 组合，annotate 同样支持
ok 120 - 5. GROUP BY / HAVING having 拒绝嵌套 traversal (cnt__nope__gte)
ok 121 - 5. GROUP BY / HAVING having 拒绝未知 op (cnt__bogus)
ok 122 - 6. F 表达式 F 字段比较
ok 123 - 6. F 表达式 F + 算术 + annotate
ok 124 - 6. F 表达式 F 在 update 中: 字符串拼接
ok 125 - 6. F 表达式 F 在 update 中: 跨表赋值
ok 126 - 6. F 表达式 increase 单字段 +1
ok 127 - 6. F 表达式 increase 单字段指定 amount
ok 128 - 6. F 表达式 increase 多字段
ok 129 - 6. F 表达式 decrease 单字段
ok 130 - 7. INSERT 插入单行
ok 131 - 7. INSERT 插入单行 + returning
ok 132 - 7. INSERT returning vararg 与 table 结果一致
ok 133 - 7. INSERT 批量插入
ok 134 - 7. INSERT 批量插入 + returning *
ok 135 - 7. INSERT 使用默认值
ok 136 - 7. INSERT 指定 columns 限制写入
ok 137 - 7. INSERT 从 SELECT 子查询插入
ok 138 - 7. INSERT 从 SELECT + select_literal 插入 (显式列)
ok 139 - 7. INSERT 从 UPDATE+RETURNING 子查询插入 (含 source 表更新)
ok 140 - 7. INSERT 从 DELETE+RETURNING 子查询插入 (常用于归档)
ok 141 - 7. INSERT 插入抛错: 唯一冲突
ok 142 - 7. INSERT 插入抛错: 单行长度超限 (ValidateError)
ok 143 - 7. INSERT 插入抛错: 批量行长度超限 (batch_index)
ok 144 - 7. INSERT 插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)
ok 145 - 7. INSERT 插入抛错: 批量+复合字段 (batch_index + index)
ok 146 - 7. INSERT 插入抛错: 子查询列数不一致
ok 147 - 8. UPDATE 基础 update
ok 148 - 8. UPDATE update + returning
ok 149 - 8. UPDATE update with cross-table where
ok 150 - 8. UPDATE update 抛错: 字段超限
ok 151 - 9. DELETE delete 带条件 + affected_rows
ok 152 - 9. DELETE delete 链式 where
ok 153 - 9. DELETE delete 三参数
ok 154 - 9. DELETE delete + returning
ok 155 - 9. DELETE delete 不匹配返回 0
ok 156 - 10. UPSERT 基本 upsert (key 自动取唯一字段)
ok 157 - 10. UPSERT upsert 单条 + 显式 key
ok 158 - 10. UPSERT upsert from SELECT 子查询 (注入新 name)
ok 159 - 10. UPSERT upsert from UPDATE+RETURNING 子查询
ok 160 - 10. UPSERT upsert 抛错: 单条 age 超限
ok 161 - 10. UPSERT upsert 抛错: 多条第二条出错 (batch_index=2)
ok 162 - 11. MERGE merge 已有更新 + 新增插入
ok 163 - 11. MERGE merge 仅插入新行不变更已有
ok 164 - 11. MERGE merge 抛错: 第二条 age 超限
ok 165 - 12. UPDATES (批量更新) updates 仅命中已存在主键
ok 166 - 12. UPDATES (批量更新) updates from SELECT 子查询
ok 167 - 12. UPDATES (批量更新) updates 抛错: 缺主键值
ok 168 - 12. UPDATES (批量更新) updates 抛错: 多条第二条 age 超限
ok 169 - 12. UPDATES (批量更新) updates 抛错: 非法字段名 (字符串)
ok 170 - 13. ALIGN (upsert + 删除多余) align 同步子集
ok 171 - 14. GET / TRY_GET / GETS / MERGE_GETS get 单条命中
ok 172 - 14. GET / TRY_GET / GETS / MERGE_GETS get 不存在返回 false
ok 173 - 14. GET / TRY_GET / GETS / MERGE_GETS get 两参数 / 三参数
ok 174 - 14. GET / TRY_GET / GETS / MERGE_GETS try_get 等价于 get
ok 175 - 14. GET / TRY_GET / GETS / MERGE_GETS gets 批量按键 (CTE RIGHT JOIN)
ok 176 - 14. GET / TRY_GET / GETS / MERGE_GETS merge_gets 合并字典
ok 177 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 已存在 → 不创建
ok 178 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 不存在 → 创建
ok 179 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 不存在 → 创建
ok 180 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: 已存在 → 更新
ok 181 - 15. GET_OR_CREATE / UPDATE_OR_CREATE update_or_create: defaults 为空 → 退化为 get_or_create
ok 182 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: params 列无唯一约束 → 报错 (原子版前提)
ok 183 - 15. GET_OR_CREATE / UPDATE_OR_CREATE get_or_create: 重复调用幂等且 created 标志准确 (xmax 判定)
ok 184 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS filter: where + exec 快捷
ok 185 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS count 无参 / 有参
ok 186 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS exists
ok 187 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 默认按主键
ok 188 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 指定字段索引
ok 189 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS in_bulk: 不传 ids 返回全集
ok 190 - 16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS contains: 主键命中
ok 191 - 17. FIRST / LAST / LATEST / EARLIEST first 默认按主键升序
ok 192 - 17. FIRST / LAST / LATEST / EARLIEST last 默认按主键降序
ok 193 - 17. FIRST / LAST / LATEST / EARLIEST first 与 order 配合
ok 194 - 17. FIRST / LAST / LATEST / EARLIEST latest
ok 195 - 17. FIRST / LAST / LATEST / EARLIEST earliest
ok 196 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 单列
ok 197 - 18. FLAT / VALUES / VALUES_LIST / AS_SET flat 在 CUD 之后
ok 198 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values 字典数组 (不经 load)
ok 199 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list 元组数组
ok 200 - 18. FLAT / VALUES / VALUES_LIST / AS_SET values_list flat 单列
ok 201 - 18. FLAT / VALUES / VALUES_LIST / AS_SET as_set
ok 202 - 19. SELECT_RELATED select_related 单字段 (返回 flat key blog_id__name)
ok 203 - 19. SELECT_RELATED select_related 数组形式
ok 204 - 19. SELECT_RELATED select_related * 全部字段
ok 205 - 19. SELECT_RELATED select_related_labels 全外键 LEFT JOIN
ok 206 - 20. UNION / EXCEPT / INTERSECT union 去重
ok 207 - 20. UNION / EXCEPT / INTERSECT union_all 不去重
ok 208 - 20. UNION / EXCEPT / INTERSECT except
ok 209 - 20. UNION / EXCEPT / INTERSECT intersect
ok 210 - 21. CTE with_values + from (用 Model.token 注入原始列引用)
ok 211 - 21. CTE where_recursive (Category 自引用)
ok 212 - 22. RETURNING returning *
ok 213 - 22. RETURNING returning 跨表列 (delete 后取 fk)
ok 214 - 22. RETURNING returning 链式追加
ok 215 - 22. RETURNING returning_literal
ok 216 - 23. EXEC 控制 (statement / compact / raw / skip_validate) statement 返回 SQL 字符串 (不执行)
ok 217 - 23. EXEC 控制 (statement / compact / raw / skip_validate) compact 紧凑模式
ok 218 - 23. EXEC 控制 (statement / compact / raw / skip_validate) raw + execr 不调用 field:load
ok 219 - 23. EXEC 控制 (statement / compact / raw / skip_validate) skip_validate 跳过校验 (本应超长的字段也通过)
ok 220 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) copy 不影响原对象
ok 221 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) all 返回 builder 副本 (对齐 Django QuerySet.all)
ok 222 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) clear 清空 builder
ok 223 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) as 表别名
ok 224 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) from + 原始字符串 (限定列名用 Model.token)
ok 225 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) get_table 拼接 (tablename + alias)
ok 226 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) prepend / append / return_all
ok 227 - 24. 工具方法 (copy / clear / prepend / append / as / from / get_table) exec_statement 直接执行 SQL
ok 228 - 25. JSON 字段查询 payload 顶层 key 等值
ok 229 - 25. JSON 字段查询 payload contains
ok 230 - 25. JSON 字段查询 payload contained_by
ok 231 - 25. JSON 字段查询 payload has_key
ok 232 - 25. JSON 字段查询 resume 数字下标 has_key 真正命中数组元素 (Django 对齐)
ok 233 - 25. JSON 字段查询 resume 数字下标 contains 真正命中数组元素
ok 234 - 25. JSON 字段查询 对象的字符串数字键不支持直查 (Django 同款取舍)
ok 235 - 25. JSON 字段查询 JSON path + gt: payload__score__gt 走 jsonb 比较
ok 236 - 25. JSON 字段查询 JSON path + lt / gte / lte / ne 走 jsonb 比较
ok 237 - 25. JSON 字段查询 JSON path + startswith / icontains 走 ->> 文本提取 + LIKE
ok 238 - 25. JSON 字段查询 JSON path 多段 + 普通 op 走 #> jsonb (语法可发送即可)
ok 239 - 26. 校验 (validate / validate_create / validate_update) validate_create 应用默认值
ok 240 - 26. 校验 (validate / validate_create / validate_update) validate_update 仅校验提供的字段
ok 241 - 26. 校验 (validate / validate_create / validate_update) validate 智能分流
ok 242 - 26. 校验 (validate / validate_create / validate_update) validate_create 抛错: 长度超限
ok 243 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update: 子模型缺少回指 FK 时报错
ok 244 - 26. 校验 (validate / validate_create / validate_update) validate_cascade_update happy path: 注入主键到子表外键
ok 245 - 27. 记录实例 (Records) Model:create 校验 + 插入 + 返回完整实例
ok 246 - 27. 记录实例 (Records) Model:save 智能 (无主键 → create)
ok 247 - 27. 记录实例 (Records) Model:save 智能 (有主键 → update)
ok 248 - 27. 记录实例 (Records) Model:save_create 强制创建
ok 249 - 27. 记录实例 (Records) Model:save_update 强制更新
ok 250 - 27. 记录实例 (Records) Model:load 返回带 fk 代理的实例
ok 251 - 27. 记录实例 (Records) Model:create_record 设置元表后获得 save/delete 等方法
ok 252 - 27. 记录实例 (Records) Record(data) 合并字段
ok 253 - 28. 事务 (transaction / atomic) transaction 正常提交
ok 254 - 28. 事务 (transaction / atomic) transaction 抛错回滚
ok 255 - 28. 事务 (transaction / atomic) atomic 包裹函数
ok 256 - 28. 事务 (transaction / atomic) REVIEW-B1: 回滚覆盖事务内经其它 model 的写入
ok 257 - 29. dates / datetimes (DATE_TRUNC 去重) dates by month
ok 258 - 29. dates / datetimes (DATE_TRUNC 去重) datetimes by hour
ok 259 - 29b. count 回归 (REVIEW B2) select 之后 count 不再拼出非法 SQL
ok 260 - 29b. count 回归 (REVIEW B2) order 之后 count 不再拼出非法 SQL
ok 261 - 29b. count 回归 (REVIEW B2) group 之后 count 返回分组数
ok 262 - 29b. count 回归 (REVIEW B2) limit 之后 count 返回截断后的行数
ok 263 - 30. 终态：reseed 后种子完整 最后一步：reseed 让数据回到初始状态
ok 264 - REVIEW T0: orm-review.md 已确认 bug 回归 B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）
ok 265 - REVIEW T0: orm-review.md 已确认 bug 回归 B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）
ok 266 - REVIEW T0: orm-review.md 已确认 bug 回归 B3 大整数与 nan/inf 字面量不能静默失真
ok 267 - REVIEW T0: orm-review.md 已确认 bug 回归 B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移
ok 268 - REVIEW T0: orm-review.md 已确认 bug 回归 B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）
ok 269 - REVIEW T0: orm-review.md 已确认 bug 回归 B6 validate_create 的 table 型 default 不能跨调用共享同一个表
ok 270 - REVIEW T0: orm-review.md 已确认 bug 回归 B7 get_or_create 必须走字段校验与 prepare_for_db
ok 271 - REVIEW T0: orm-review.md 已确认 bug 回归 B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL
ok 272 - REVIEW T0: orm-review.md 已确认 bug 回归 B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）
ok 273 - REVIEW T0: orm-review.md 已确认 bug 回归 B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx
ok 274 - REVIEW T0: orm-review.md 已确认 bug 回归 B12 in_bulk({}) 必须返回空表而不是全表
ok 275 - REVIEW T0: orm-review.md 已确认 bug 回归 B13 JSON 字段里的空数组往返后必须仍是数组
ok 276 - REVIEW T0: orm-review.md 已确认 bug 回归 B16 where('col', nil) 必须报错而不是退化成裸 SQL
ok 277 - REVIEW: 疑似问题与设计建议回归 S2/T13 新建连接必须强制 standard_conforming_strings = on
ok 278 - REVIEW: 疑似问题与设计建议回归 D8/T15 终结方法必须在副本上执行（复用 builder 不串条件）
ok 279 - REVIEW: 疑似问题与设计建议回归 S3/T14 非 cosocket 阶段发查询必须报含 phase 的明确错误
2026/09/21 11:52:30 [warn] 4164#0: *2 [lua] query.lua:100: log_warn(): [model.query] Query{POOL_NAME="review_pool_warn_1789962750308"} 已被构造过，query_timeout 以首次构造的值为准：沿用 8000，忽略本次传入的 600000。需要不同配置请换一个 POOL_NAME，详见 docs/orm-index.md「数据库连接与超时」, context: ngx.timer
2026/09/21 11:52:30 [warn] 4164#0: *2 [lua] query.lua:100: log_warn(): [model.query] Query{POOL_NAME="review_pool_warn_1789962750308"} 已被构造过，statement_timeout 以首次构造的值为准：沿用 6000，忽略本次传入的 598000。需要不同配置请换一个 POOL_NAME，详见 docs/orm-index.md「数据库连接与超时」, context: ngx.timer
ok 280 - REVIEW: 疑似问题与设计建议回归 S4/T14 Query() 缓存命中且配置不同时必须记 WARN
ok 281 - REVIEW: 疑似问题与设计建议回归 S4/T14 STATEMENT_TIMEOUT 默认比 QUERY_TIMEOUT 早 2 秒，且不会派生出非正值
ok 282 - REVIEW: 疑似问题与设计建议回归 D9/T14 Model.LAZY_FK = false 时外键属性访问必须报错而不是偷偷发查询
ok 283 - REVIEW: 执行中发现（F 系列）回归 F6 大浮点数不能被当成丢了精度的整数拒掉（float 列回归）
ok 284 - REVIEW: 执行中发现（F 系列）回归 F7 非整数的数字字面量必须能逐位往返（不能走 %.14g）
ok 285 - REVIEW: 执行中发现（F 系列）回归 F8 where 同族入口与转发方法的 nil 值都必须报错（含三参形式）
1..285
Done in 3.86s.
```

### F9 [中] `bigint = true` 建出来的仍是 `integer` 列

- 发现于：同上，实跑 T4 的 bigint 支持时。
- 现象：`{ "order_no", type = 'integer', bigint = true }` 在字段对象上确实拿到了 `db_type = 'bigint'`，但 `resty.migrate` 的建表语句按 `type`（而不是 `db_type`）映射——`migrate.lua` 里 `integer` 类的 `type_string` 硬编码成 `"integer"`：

```
CREATE TABLE probe4_t(
  id SERIAL PRIMARY KEY NOT NULL,
  name varchar(50) UNIQUE,
  big integer ,          -- ← 期望 bigint
  payload jsonb
)
```

  结果写入超过 int4 范围的值时 PG 报 `integer out of range`，T4 的 bigint 支持在「用本项目的迁移工具建表」这条路上够不着。

- 影响面：只影响「用 `resty.migrate` 建表」的场景。对着已有 schema（外部迁移 / 手写 DDL 建成 bigint）使用时，校验、字面量、读回三段都正常。
- 处置：`resty.migrate` 不在 `lib/` 下，按 CLAUDE.md「不要修改 pgmoon」的同类口径与「不要直接改」一并跳过，只记录。T16 已在字段文档里写明这条限制。
- 建议改法（需要动 `resty.migrate`）：`integer` 类的 `get_create_type` 改成读 `self.field.db_type`，回落到 `"integer"`。

### F10 [低] B15 的「修复」只改了类型注解，运行时错误信息仍然是 LuaJIT 的原始报错

- 发现于：同上。T11 的提交信息写「update 只接受 table（B15）」，实际改动是把 `---@field update` 的注解从 `Record|string|(fun(ctx):string)` 收窄成 `Record`，再加一行注释。运行时没有加任何检查：

```lua
Blog:update("tagline = 'x'")
-- ERR lib/model/sql.lua:2659: bad argument #1 to 'pairs' (table expected, got string)
```

- 后果：编辑器里能看到类型不对（这正是 B15 报告要的效果，B15 的建议就是「改注解」），但运行期报错仍然指向 `pairs`，看不出「这个方法不收字符串」。严重度低。
- 处置：同 F6，本次不改。
- 建议改法：`Sql:update` 开头加一句 `if type(row) ~= 'table' then error(...) end`，错误信息指明「裸 SQL 片段请用 `_base_update`，或者写成键值对」。

### F11 [中] `delete(cond)` 的 `cond` 为 `nil` 时等价于 `delete()`，即删全表

- 发现于：F8 修复。F8 让 `delete('ok', nil)` / `delete('n', '>', nil)` 报错，但**一参**的 `delete(nil)` 仍然走「不传条件 = 显式删全表」分支：

```lua
local cond = params.filter        -- 请求里没带 filter，cond 为 nil
Blog:delete(cond):exec()          -- DELETE FROM blog AS T —— 整张表没了，不报错
```

- 与 F8 的关系：同一类问题（条件变量为 nil 时语义被悄悄换掉），方向更危险（全表）。F8 的改动已经让 `delete` 以 `...` 接参，`select('#', ...) == 1 and cond == nil` 这个判据现成可用。
- 没有顺手改的原因：不在 F6–F10 的范围内；而且这是**有意的行为变化**——T16 已在 `docs/orm-query-basics.md` 的 `Sql:delete` 一节把它写成「要小心」的已知语义，改成报错需要使用方确认没有代码依赖「`delete(nil)` 删全表」。
- 处置：按 CLAUDE.md 只记录，本次不改。
- 建议改法：`Sql:delete` 里 `select('#', ...) >= 1 and cond == nil` 时报错，提示「删全表请写 `delete()`（不传参数）」。`Model:delete()` 本身（无参）的语义不变。
