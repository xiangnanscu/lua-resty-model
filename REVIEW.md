# lua-resty-model 全库代码审查报告

- 日期：2026-07-15
- 范围：`lib/model/` 全部 9 个文件（约 8400 行）+ spec + docs
- 方法：逐文件逐方法通读 → 对可疑点编写探针脚本在真实 PostgreSQL 17 上复现 → 跑全量测试
- 结论先行：**架构与 Django 对齐度非常高，`_parse_column` 的多段遍历/自动 JOIN/JSON path 是全库最精华的部分；但存在 1 个严重事务 bug（跨 model 写入逃逸事务）和若干中低危问题。**

> **修复状态（2026-07-15 同日）**：B1–B10 已全部修复并补回归测试（bug_spec `REVIEW-*` 系列 + model_spec `REVIEW-B1`/`29b`），全量 247/247 通过。B1 采用方案 1（Query 按 pool_name memoize），B6 改查被引用方字段。
> 附带发现：基线并非 232 全过——「updates 抛错: 非法字段名」一条是**预先存在的失败**（首轮汇报时被输出截断漏看），根因是 `_validate_*_rows` 里 key 非空检查先于数据校验执行，非法字段名报不出来；已交换顺序修复。
>
> **第二轮处理（2026-07-16）**，全量 250/250 通过：
> - §2.9 **已修**：`Model.query` 改惰性代理，`model.query`（含 pgmoon）与 `.env`/ALIOSS 环境读取全部惰性化——`require model` + 建模 + `:statement()` 零隐式依赖，首次真实查询才加载（探针验证 `package.loaded` 均为 false）。
> - §3.3 **已修**：fields.lua 删除本地 `dict/list/map/split/utf8len/clone`，统一引 utils（`utf8len` 上移至 utils，`split_string` 增加空分隔符守卫）；validator.lua 的 `utf8len` 一并统一；`ngx.localtime`/`ngx.null` 加非 ngx 降级。
> - §2.3 **已修**：空 `__in`/`__notin` 报错带列名（回归 `REVIEW-D3`）。
> - §2.11 **已修**：`_resolve_Q` 递归透传 context，复合 Q 在 having 里保持 having 解析路径（回归 `REVIEW-D11`）。
> - §2.10 **已修**：TableField **显式声明** `max_rows` 时校验行数；类默认 1 保持仅前端提示，不破坏既有行为（回归 `REVIEW-D10`）。
> - §2.7 **文档化**：`standard_conforming_strings` PG 9.1+ 默认 on，逐连接 SET 不值一次往返——改为在 docs（where 原始字符串的安全警告旁）提示使用者勿改该服务器配置；`smart_quote` 转义标识符内部双引号保留。
> - §2.1 **已修**：`exec/get/first/last/values/filter/in_bulk/get_or_create/...` 的 `@return` 注解由 `ModelInstance` 改为 `Record`（`raw(false)` 分支的 cast 保留），docs 的 raw 小节补默认语义与实例方法获取方式，`get_or_create` 补并发处方。
> - §2.2/§2.6 docs 已有对应段落（copy 可变性、update_or_create 并发提醒），仅补 get_or_create 一处。
> - §2.6 **升级为原子实现（2026-07-16 追加）**：`get_or_create`/`update_or_create` 改为单条
>   `INSERT ... ON CONFLICT (params列) DO UPDATE ... RETURNING (xmax = 0) AS __is_inserted__`，
>   并发安全、无重复插入、不依赖外层事务（也因此不会撞本库「事务不可嵌套」的限制）。
>   语义收窄：params 列集合必须命中唯一约束（原实现允许任意条件），fail loud；
>   已存在时的 no-op 更新会产生一次行版本写入。docs 两段已重写，spec 15 节补 4 条用例。
> - §2.4（JSON 数组下标）、§2.5（get 的 0/2+ 行均返回 false）维持原设计，仅记录。
> - §5.5 的 `get_keys` 递归丢参在第一轮 B10.2 已修（去重种子版，回归 `REVIEW-B10b`）。
>
> **第三轮处理（2026-07-16 续）**，全量 258/258 通过：
> - §2.4 **已修（推翻原"仅记录"）**：单段整数样式 JSON 路径按 Django 语义走数组下标
>   （`payload__0` → `-> 0`）；多段 `#>` 的 text[] 本就自动支持数组下标无须改。
>   代价与 Django 相同：对象的 `"0"` 字符串数字键不再可直查（spec 用例已改写注明，回归 `REVIEW-D13`）。
> - §3.1+§3.2 **已修**：proxy 方法 wrapper 缓存（独立 cache 表 + `__newindex` 失效同步；
>   不能 rawset 进 proxy 自身，否则后续同名赋值绕开 `__newindex` 造成 proxy/ModelClass 分裂）。
> - §5.8 **已修**：`check_field_name` 显式对 Model/Sql 方法 + 内部机制属性黑名单检查
>   （探针证实原 `self[name]` 查的是 normalize 半成品表，`execr/group_by/count` 全放行；回归 `REVIEW-D12`）。
>   label/admin 等"软冲突"属性有意不拦（存量字段名常用）。
> - §3.8 **已修**：annotate/alias/aggregate 的 AS 别名统一 `smart_quote`（回归 `REVIEW-D14`）。
> - §3.5 **已修**：`group()` 自动 select 按 select 语境 token 去重（回归 `REVIEW-D15`）。
> - §5.5 **已修**：`extract_column_name` 推断失败即报错并提示显式传 columns（回归 `REVIEW-D16`）；
>   `as_literal` 三胞胎工厂化；`get_join_table_condition` 混用显式 from + join 表加防御断言。
> - §5.4 **已修**：`SSL/SSL_VERIFY/SSL_REQUIRED` 用 coalesce（`or` 吞 false 的问题）；
>   删 `ConnProxy.__call` 迷惑代码；`transaction` 截断 >3 返回值加注释。
> - §5.9 **已修**：`regex/iregex` 先 `tostring`；`meta_query` terminal 方法后 break。
> - §3.4 **已修**：`class()` 的 INHERIT_METHODS 死循环删除（元方法以直接键沿类链传递，pairs 拷贝已覆盖）。
> - §3.6/§3.7 **已修**：assemble_sql 的 UPDATE/DELETE 别名补 `AS`；`valid_date` 死分支删除（实际位于 validator.lua，§3.7 原归属 utils 有误）。
> - §5.2/§5.7 **已修**：`resolved_column`、`__eq` 死注解删除。
> - §5.3 **半修**：`Func` 的 `filter` 参数从静默丢弃改为显式报 not implemented；`COUNT(DISTINCT)` 仍未支持。
> - §5.7 docs 补 DatetimeField 时区依赖说明；§2.10 docs 补 max_rows"显式才校验"说明。
> - **决定不动**：§4 validate 三态协议（用户拍板）；§2.5（get 语义）；`_parse_column` 拆模块（未立项）。
> - **新发现（暂不动）**：`check_field_name` 里 `Sql.EXPR_OPERATORS[name:upper()]` 检查因大小写
>   永不命中（键是小写）——但真启用会禁掉 `date/year/month/time/contains` 等常用字段名，
>   且 `_parse_column` 对"字段 vs 操作符"本有确定的优先级规则（首段字段优先、JSON 路径内操作符优先，
>   与 Django 一致），风险大于收益，维持现状并记录。
> - **B8 勘误**：第三条（`date` 混搭分隔符 `2010-01/02`）当时有意未修——分隔符回引用会杀掉
>   `X年X月X日` 支持（年/月/日是两个不同分隔符），属知情取舍，非遗漏。

---

## 0. TL;DR（下表为审查时点快照，**均已修复**，状态详见顶部注记）

| 级别 | 问题 | 位置 | 状态 |
|------|------|------|------|
| 🔴 严重 | 跨 model 事务失效：`A:transaction` 内经 `B:xxx` 的写入不参与事务，回滚后仍落库 | query.lua + init.lua | ✅ 已修 |
| 🟠 高 | `count()` 不清除已有 `_select`/`_order`，`select(...):count()` 直接 SQL 报错 | sql.lua:3007 | ✅ 已修 |
| 🟠 高 | `__year` 查询用 `BETWEEN '01-01' AND '12-31'`，timestamp 列漏掉 12-31 当天非零点数据 | sql.lua:101 | ✅ 已修 |
| 🟠 高 | 自引用外键（`reference='self'`）validator 闭包捕获了 setup 前的 `reference_column=nil`，传表值校验必错 | fields.lua:1315 | ✅ 已修 |
| 🟠 高 | 同一 model 两个 FK 指向同一目标且都用默认 `related_query_name` 时静默覆盖，反向查询解析到错误的 FK | init.lua:678 | ✅ 已修 |
| 🟡 中 | SQL 出错时连接不 release（非事务路径），连接池被慢性掏空 | query.lua:244 | ✅ 已修 |
| 🟡 中 | `Validator.time/datetime` 允许 60 分/60 秒；datetime 不接受负时区偏移 | validator.lua | ✅ 已修 |
| 🟡 中 | `Sql:copy()` 会浅克隆 `self.model`，破坏 `fk.reference == self.model` 之类的身份比较 | sql.lua:2186 | ✅ 已修 |
| ⚪ 低 | 一批潜伏 bug 与设计取舍，详见 §2/§3 | | ✅ 已修/已记录 |

---

## 1. 确认的 Bug（全部已在真实 DB 上复现）

### B1 🔴 跨 model 事务失效（最严重）

`Model:_make_model_class` 里只要 `opts.db_config or self.db_config` 为真，**每个 model 都会 `Query(options)` 新建一个实例**：

```lua
-- init.lua:441
local options = opts.db_config or self.db_config
if options then
  ModelClass.query = Query(options)
end
```

而事务的 ambient 存储 `txn_conns` 是 `Query()` 闭包里的**局部变量**（query.lua:222）。于是 `Blog.query ~= BlogBin.query`，两者各有一份 `txn_conns`。

复现（真实 DB）：

```lua
Blog:transaction(function()
  BlogBin:insert{ name = 'x' }:exec()  -- 走 BlogBin.query，拿不到事务连接
  error("force rollback")
end)
-- 结果：Blog 的写入回滚了，BlogBin 的写入 **提交了**
-- 探针输出：BlogBin count before=0 after=1 => LEAKED!
```

危害评估：docs/orm-query-advanced.md 推荐的「方式一：classview `atomic = true` 覆盖整个请求」正是典型的多 model 场景，转账/级联写这类最需要原子性的代码恰恰最容易踩中。且 `select_for_update` 文档明确说"误用不会报错"——这个 bug 把误用变成了常态。

触发条件：设置了 `Model.db_config`（或 per-model db_config）。若完全依赖 `.env`（options 为 nil），所有 model 继承模块级共享的 `Model.query = Query{}`，事务反而是对的。**行为取决于配置方式，极难排查。**

修复建议（二选一）：
1. `Query(options)` 按连接配置 memoize：以 `pool_name`（host:port:db:user）为 key 缓存实例，同库返回同一实例，`txn_conns` 自然共享；
2. 把 `txn_conns` 提升为 query.lua 模块级，key 用 `(coroutine, pool_name)` 二元组。

方案 1 改动最小且顺带消除了每 model 一份连接配置的浪费。

### B2 🟠 `count()` / 聚合前不清空 select/order

```lua
Blog:select('name'):count()
-- SELECT T.name, count(*) FROM blog T
-- ERROR: column "t.name" must appear in the GROUP BY clause
Blog:order('name'):count()   -- 同样报错
```

`Sql:count` 用 `_base_select("count(*)")` 追加而非覆盖。Django 的 `count()` 会清掉 select/order。对比：`Sql:dates/datetimes` 就是直接覆盖 `self._select`，行为不一致。

修复：`count()` 里 `self._select = "count(*)"; self._order = nil`（如已有 `_group`，Django 语义应包一层子查询再 count，可以先只修无 group 的场景并对 group 情形报错）。

### B3 🟠 `__year` 对 timestamp 列漏数据

```lua
ViewLog:where { ctime__year = 2020 }:statement()
-- WHERE T.ctime BETWEEN '2020-01-01' AND '2020-12-31'
```

`'2020-12-31'` 转 timestamp 是 `2020-12-31 00:00:00`，当天 00:00 之后的所有记录都被排除。Django 生成的是 `>= '2020-01-01' AND < '2021-01-01'`。date 列不受影响，datetime/timestamp 列必错。

修复（sql.lua:101）：

```lua
year = function(key, value)
  local y = assert(tonumber(value), "year lookup requires a number")
  return format("%s >= '%d-01-01' AND %s < '%d-01-01'", key, y, key, y + 1)
end
```

（顺带消掉现在用字符串拼年份 + gsub 转义的别扭写法。）

### B4 🟠 自引用外键 validator 捕获 stale `reference_column`

`reference = 'self'` 时 `ForeignkeyField:init` 提前 return，不执行 `setup_with_fk_model`；但 `create_field` 紧接着就调 `get_validators`，闭包把 `local fk_name = self.reference_column`（此时是 **nil**）捕获死了。之后 `resolve_foreignkey_self` 再 setup 也不会重建 validators。

结果：给自引用 FK 传表值（`{ parent_id = { id = 1 } }`）时 `v[fk_name]` 变成 `v[nil]` → nil → 报"要求是数字"之类的假校验错误。普通 FK 同样写法正常（探针 P5/P5b 对照确认）。传标量 id 不受影响（`self.convert` 是动态查的）。

修复：闭包内改为动态读 `self.reference_column`；或在 `resolve_foreignkey_self` 里 setup 之后重建 `field.validators`。

### B5 🟠 默认 `related_query_name` 冲突静默覆盖

```lua
fields = {
  { 'a_id', reference = M2 },
  { 'b_id', reference = M2 },   -- 两个都默认 rqn = self.table_name
}
-- M2.reversed_fields['xxx'] 最终指向 b_id，a_id 的反向查询悄悄没了
```

探针确认 `reversed_fields` 被第二个 FK 覆盖。Django 对应场景是硬错误（fields.E304/E305）。spec 里 Entry 之所以没事，是因为显式指定了 `entry`/`reposted_entry`。

修复：`resolve_foreignkey_related` 写入前 `assert(not fk_model.reversed_fields[rqn], ...)`。

### B6 🟠 反向名冲突检查方向反了

init.lua:691：`assert(not self.fields[rqn], ...)` —— 检查的是**定义 FK 的一方**（Entry）有没有叫 `entry` 的字段。但 `related_query_name` 实际用在**被引用方**的查询里（`Blog:where{entry__rating=1}`），真正的冲突是 `fk_model.fields[rqn]`：若 Blog 有个叫 `entry` 的实体字段，`_parse_column` 会优先命中 branch 1（自身字段），反向查询被静默遮蔽。应改查（或两边都查）`fk_model.fields[rqn]`。

### B7 🟡 SQL 出错时连接不释放

query.lua `send_query`：

```lua
local conn, is_transaction = get_conn()
local result, ... = conn:query(statement, compact)  -- 失败时 ConnProxy:query 直接 error()
if not is_transaction then
  conn:release()   -- 抛错时永远走不到
end
```

任何一条 SQL 报错（语法错、约束冲突……），非事务连接既不 keepalive 也不 disconnect。OpenResty 下请求结束时 cosocket 被关闭，等价于连接池慢性流失、错误高发时频繁重建连接；luasocket 下则纯泄漏到 GC。事务路径没这个问题（xpcall 里兜了）。

修复：`local ok, a,b,c,d = pcall(conn.query, conn, statement, compact)`，release 后再按需重抛。

### B8 🟡 时间校验边界

- `Validator.time`：`minute > 60`/`second > 60` —— `13:60:00` 通过校验，落库时 PG 报错（探针 P4 确认）。应为 `>= 60`。`hour > 24` 允许 `24:xx` 有意为之的话建议只放行 `24:00:00`。`datetime` 同样问题。
- `Validator.datetime` 时区尾巴正则 `(\+\d\d?(:\d\d)?)?` 只认 `+`，`2023-09-24T13:41:52-08:00` 被拒（探针 P4b 确认）。改 `([+-]\d\d?(:\d\d)?)?`。
- `Validator.date` 两个分隔符没用回引用（datetime 用了 `(\2)`），`2010-01/02` 这种混搭能过。

### B9 🟡 `Sql:copy()` 克隆 `model`

`copy()` 对所有 table 值一律 `clone`，包括 `self.model`。克隆出来的 model 表内容一样但**身份不同且丢失 metatable**：`where_recursive` 里的 `fk.reference ~= self.model` 判断、以及任何依赖 model 身份/元表的逻辑在 copy 出的 builder 上都会出错。修复：`copy` 跳过 `model`（共享引用即可），顺带跳过 `_join_proxy_models` 这类含闭包上下文的字段。

### B10 ⚪ 潜伏类（当前调用路径踩不到，但属于地雷）

1. **utils.split_string**：`start = pos + 2` 硬编码分隔符长度为 2，只对 `", "` 正确。探针：`split_string("a,b,c", ",")` → `{"a","","..."}`。应为 `pos + #pattern`。
2. **utils.get_keys**：数组分支递归 `get_keys(res)` 时把第二参数 `columns` 种子丢了；`_clean_bulk_params` 传的 `{auto_now_name}` 因此从未生效（幸而 `_get_update_token_with_prefix` 总是无条件追加 `utime = CURRENT_TIMESTAMP`，结果无恙）。要么修 get_keys，要么删掉那个假参数。
3. **fields.split**：`sep` 默认 `""` 时 `s:find("", i, true)` 返回 `(i, i-1)`，`i = b + 1 = i` —— 死循环。当前所有调用都显式传了 sep，但默认值就是个陷阱。
4. **validator.lua 非 nginx 环境**：`match/gsub` 只在 `ngx` 存在时赋值，else 分支是空的；fields.lua 顶部还直接 `ngx.localtime`。utils.lua 却精心做了非 ngx 降级——三个文件口径不一。要么统一声明"仅限 OpenResty"，要么补齐降级。
5. **StringField 数字 choices**：`get_max_choice_length` 对 number 值调 `utf8len`（`s:gsub`）直接崩。入口处应 `tostring`。
6. **F() 用在 json 字段上**：`JsonField:prepare_for_db` 对 token 函数执行 `cjson.encode` → 报错（探针 P10）。`prepare_for_db` 系列应先放行 `type(value)=='function'`。

---

## 2. 设计取舍类（不算 bug，但值得记录在案）

1. **`exec()` 默认 raw**。`exec_statement` 的条件 `(self._raw == nil or self._raw) or ...` 意味着默认不做 `field:load`、不挂 RecordClass 元表——`get()` 返回的是裸 table（探针 P7：无 `save` 方法、无 metatable）。docs 有一行提到 `raw(false)`，但 sql.lua 里所有 `---@return ModelInstance` 注解都言过其实；`exec_statement` 里整段 `_select_related` 合并 + `model:load` 分支实际只有显式 `raw(false)` 才可达（spec 里 select_related 断言的是平铺的 `blog_id__name`）。建议：注解改成 `Record`，并在 docs 里把「什么时候是实例、什么时候是裸行」写成显著章节。
2. **builder 是可变的**，`where` 直接改 `self`，与 Django 的 clone-on-write 相反；`all()/copy()` 提供显式分叉。用惯 Django 的人会踩（`local base = Blog:where{...}` 之后每次复用都在累积条件）——spec 194/195 有覆盖，docs 建议再强调。
3. **空 `__in={}` 抛 "empty table is not allowed"**。Django 返回空集。抛错更安全（fail loud），但错误信息完全看不出是哪个字段，建议至少带上列名。
4. **JSON path 的数字段**：`payload__0` 生成 `-> '0'`（文本键）而非 `-> 0`（数组下标），数组按下标查询不可用。spec 206-208 已注明"语义限制"，是知情取舍，记录在此。
5. **`get()` 0 行和 ≥2 行都返回 `false`**，`try_get` 就是 `get` 的别名。Django 区分 DoesNotExist / MultipleObjectsReturned。当前用 `limit(2)` 探测多行是聪明的，但两种失败不可区分。
6. **`get_or_create` 有竞态**（INSERT ... WHERE NOT EXISTS 非原子），`update_or_create` 是 2-3 条独立语句。docs「常见陷阱」第 2 条已经承认，建议在这两个方法的文档里直接给出「配 unique 约束 + 事务」的处方。
7. **字符串拼接式 SQL（非参数化）**。注入面控制得不错：列名走 `_parse_column` 白名单（模型字段/operators），值走 `as_literal`（`'`→`''`），LIKE 值有专门转义，order/for-update-of 有格式校验。两个残留点：a) `as_literal` 不处理反斜杠，依赖 `standard_conforming_strings=on`（9.1 后默认，但这是个服务器配置），建议连接后显式 `SET standard_conforming_strings = on` 或在文档声明；b) `smart_quote` 不转义标识符内部的 `"`（当前标识符全部来自模型定义，风险为零，防御性可加）。
8. **每 model 一个 `Query` 实例**（B1 的根因）即便修了事务问题，也建议 memoize——现在同库 N 个 model 就有 N 份连接配置闭包。
9. **`Model.query = Query{}` 在 require 时就执行**，dotenv 读 `.env` 是模块加载副作用。无 DB 环境只要不真正查询无害，但让「纯粹生成 SQL」的用法背了个隐式依赖。
10. **TableField 默认 `max_rows = 1`** 且 max_rows 在后端根本不校验（只进前端 json）。默认值奇怪 + 校验缺失，二选一改掉。
11. **`_resolve_Q` 递归不传 context**：`having(Q{...} * Q{...})` 的复合分支会掉进 where 解析。目前被 `_parse_column` 也认识 annotate 别名这一点兜住了（spec 808 因此能过），但两条解析路径的差异（如 FK 遍历会造 JOIN）迟早裂开。一行修复：`self:_resolve_Q(q.left, context)`。

---

## 3. 优化空间

1. **model proxy 的 `__index` 每次访问都新建闭包**（init.lua:188）。`Blog:where`、`Blog:get`——每一次方法访问都分配一个 wrapper function。这是全库最热的路径。方法集是静态的，完全可以在首次访问后 `rawset(proxy, k, wrapper)` 缓存（`__newindex` 已经 rawset 到 ModelClass，不冲突）。
2. **`create_model_proxy` 先查 `Sql[k]` 再查 `ModelClass[k]`**，而 `_make_model_class` 已经把 Model 的全部方法 dict 复制进 ModelClass——两套分发并存。若把 Sql 方法也按需缓存到 proxy，语义不变、查找链短一半。
3. **fields.lua 重复实现** `dict/list/map/split/utf8len`（utils.lua 全有），且 fields 版 `split` 还带死循环陷阱。统一 require utils 版本。
4. **`class()` 的 INHERIT_METHODS 循环基本是死代码**：第一段 `pairs(parent)` 拷贝已经把所有直接键（含元方法）复制了，之后 `cls[method] == nil` 在 setmetatable 后几乎不可能为真。删掉或注释说明意图。
5. **`Sql:group` 自动 `select` 分组列**在用户已 select 同列时产生重复列（`SELECT T.blog_id, T.blog_id`，探针 P11）。追加前查一下 `_select` 是否已含。
6. **`assemble_sql` 的 UPDATE 分支** `table_name .. ' ' .. opts.as`（无 AS），INSERT 分支用 `' AS '`——都合法，统一风格即可。
7. **`utils.valid_date`** 末尾 `elseif day > 31` 分支永不可达（开头已检查）。
8. **注解别名不做 smart_quote**：`annotate{ order = Count('id') }` 生成 `AS order`，PG 恰好允许 `AS` 后跟任意关键字所以能跑，但 `group_by` 直接引用该别名时就不行了。alias 统一过 `smart_quote`。
9. **错误信息里的字段上下文**：`as_literal("empty table ...")`、`_check_upsert_key_error` 的中文提示都很好，但 utils 层报错普遍不带列名/表名，排查全靠栈。

---

## 4. 设计理念评述

**值得肯定的：**

- **Django 语义对齐是认真做过功课的**：`Q`（`*`/`/`/`-` 映射 AND/OR/NOT，比 Python 的 `&`/`|` 在 Lua 运算符约束下选得聪明）、`F` 表达式树、`annotate/alias/aggregate` 三件套、反向 FK 遍历 + aggregate 上下文自动 LEFT JOIN、`__year/__month/...` lookup 家族、JSON path 的 `->`/`->>`/`#>` 智能选择——这些在一个 Lua ORM 里做到这个完成度是罕见的。
- **`merge`/`upsert`/`updates`/`align` 的 CTE 生成**（`WITH V(..) AS (VALUES ...)` + UPDATE/INSERT 组合拳）超出了 Django 的能力范围，`align`（对齐即"upsert + 删除不在集合内的行"）是很实用的独创。
- **`_parse_column` 是全库的心脏**，多段遍历状态机 + join 去重（`_join_keys`）+ 注释里逐分支编号（1.1/1.4.2/…）+ bug_spec.lua 用 13 个用例钉死历史 bug（B1/B2/B4/B5/B7）——这种"修 bug 必留档"的工程习惯非常好。
- **错误通道统一为 throw**（`field_error` table 上抛，交给 app 层分类为 422/500），query.lua 里那段中文注释把「为什么绝不 return nil,err」讲得清清楚楚。事务实现对 BEGIN 失败、COMMIT 失败、回滚二次失败的处理都考虑到了（除了 B1 的 ambient 隔离域选错）。
- **`txn_conns` 用弱键协程表**而不是 `ngx.ctx`，让纯 LuaJIT/resty-cli 也能跑事务，且天然隔离 `ngx.thread.spawn` 轻线程——思路是对的，只是实例化粒度（每 Query 一份）毁了它。

**需要警惕的结构性风险：**

- **validate 管道的私有协议太魔法**：validator 返回 `(value, err, index)`，而 `value == err` 表示"保留值并跳过后续校验"（`skip_validate_when_string` 用 `return v, v` 触发）。这是一个靠约定维系的三态协议，新增 validator 的人不读 `BaseField:validate` 源码必踩坑。建议用显式哨兵（如返回 `value, STOP`）替代值相等判断。
- **一处三套列名解析**（`_parse_column`、`_get_having_column`、`extract_column_name` 正则抽取），加上 `_base_*` 与公开方法的双层 API，sql.lua 3589 行里私有方法占了 6 成。功能密度高但可读性开始吃紧，建议把 `_parse_column` 拆成独立模块并配注释文档（它已经有最好的注释了，值得升格）。
- **docs 与实现的漂移**：`exec` 返回类型注解、`try_get`、TableField.max_rows 等处，文档承诺 > 实现。类型注解是给 LSP 用的，错的注解比没有更糟。

---

## 5. 逐文件审查纪要

### 5.1 q.lua（23 行）✅ 干净

- `__mul/__div/__unm` → AND/OR/NOT。`__unm` 只设 `left`，`_resolve_Q` 的 NOT 分支单独处理，正确。
- 无参数校验：`Q{...} * 5` 会在 resolve 时才炸。可接受。

### 5.2 f.lua（47 行）✅ 干净

- 运算符树构造正确；`__tostring` 递归依赖 LuaJIT `%s` 自动 tostring，成立。
- `^` 在 Lua 右结合、PG 左结合——因为渲染时全程带括号，语义按书写形状保留，无歧义。
- `resolved_column` 字段在注解里声明但全库无人写入，删注解。

### 5.3 func.lua（37 行）✅ 干净

- 七个聚合，`filter` 字段解析了但 `annotate` 生成 SQL 时没用上（`FILTER (WHERE ...)` 未实现，文件头 TODO 也承认）。要么实现要么先从 `__call` 里删掉。
- 无 `COUNT(DISTINCT col)` 支持。

### 5.4 query.lua（307 行）

- `get_connect_table`：`options.SSL or ENV_CONFIG.PG_SSL == "true"` —— `SSL = false` 无法覆盖 env 里的 true（`or` 吞 false）。同理 `ssl_verify` 等布尔项。建议 `if options.SSL ~= nil then ... end`。
- `process_statement_table` ✅。
- `ConnProxy`：`__call` 定义了但 ConnProxy 自身没有元表，唯一效果是"调用实例返回新实例"——迷惑性大于用处，删。
- `ConnProxy:query`：错误转 throw，`error(num_queries)` 拿的是 pgmoon 的 err 字符串，✅。
- `send_query`：**B7 连接泄漏**（见上）。
- `transaction`：BEGIN 失败释放、xpcall 保栈、回滚二次错误不掩盖根因、COMMIT 前后 release 的 finally 语义——写得好。唯 `txn_conns` 的实例化粒度导致 **B1**。另：不支持嵌套（savepoint），直接抛"transaction already started"，是文档化的设计决定。
- `transaction` 只透传 callback 前 3 个返回值，>3 会被截断，注释一下。

### 5.5 utils.lua（772 行）

- `clone/isempty/NULL/table_new` 的 ngx 降级 ✅（对比 fields/validator 的不降级，见 B10.4）。
- `get_keys`：**B10.2 递归丢参**。
- `split_string`：**B10.1 硬编码 +2**。
- `smart_quote`：只处理保留字，不转义内部引号（§2.7b）。
- `as_literal / as_token / as_literal_without_brackets`：三胞胎函数 90% 重复，可以工厂化（注释里 `_escape_factory` 的尸体说明曾经就是）；转义正确（`''`），空表抛错。
- `escape_like_value` ✅（`\`、`%`、`_`、`'` 全覆盖，配合 `ESCAPE '\'`）。
- `extract_column_name/extract_column_names`：靠正则从 SQL 文本反推列名，天然脆（列里有函数调用即放弃）。仅用于子查询 insert 的列推断，可接受，但建议在失败时报错而不是静默丢列。
- `get_join_table_condition`：froms 用空格 concat，若 `opts.from` 已有内容且 join_args[1] 存在，会生成 `FROM a b` 缺逗号——当前调用序列（update/delete 路径 from 只经 `_base_from` 逗号拼接，join_args 首项走 wheres）恰好避开，属于结构性脆弱点。
- `assemble_sql`：单函数装配全部语句形态，直白有效 ✅；`valid_date` 死分支（§3.7）。

### 5.6 validator.lua（455 行）

- 管道式 validator（值进值出 or nil+err）✅ 简洁。
- `time/datetime/date`：**B8 边界**。
- `utf8len` 计数法 ✅；`id_card` GB11643 校验位算法核对无误（权重表 17 项、校验码表 11 项）✓，但报错信息用 `#v`（字节长）与校验用 `utf8len` 口径不一。
- `max/min` 直接 `v > n`：依赖字段先跑过 number/integer 校验（各字段 get_validators 的插入顺序保证了这一点 ✓），但 validator 单独复用时会对字符串比较抛 Lua 错。
- `encode_as_array` 会覆盖入参已有 metatable（如 Array），当前无害，注释一下。
- `pattern/maxlength/...` 的 message `gsub('%%s', ...)` 只支持一个占位符且写法晦涩，够用。

### 5.7 fields.lua（1828 行）

- `class()` 继承器：可用；INHERIT_METHODS 段冗余（§3.4）。
- `normalize_field_shortcuts` 位置参数 `{name, label, type, required}` ✅。
- `BaseField:validate` 的三态协议（§4 警惕点）。
- `BaseField.__add/__sub` 返回字符串（供 DDL/迁移比较表达式），`__eq` 只在注解里承诺、未实现——LSP 谎言。
- StringField：choices 自动推 maxlength ✅；数字 choices 崩（B10.5）；`compact` 默认 true（删除所有空白）是激进默认，文档已提示。
- IntegerField/FloatField/BooleanField/Date*/Time*：`prepare_for_db` 空值→NULL 的统一约定 ✅。
- DatetimeField：`auto_now_add → default = ngx.localtime`（本地时区无偏移量字符串）+ `timezone = true`（DDL 大概率是 timestamptz）——依赖 DB 时区与 nginx 时区一致，建议文档明示。
- ForeignkeyField：`load()` 惰性代理（首次访问属性触发一次 `fk_model:get`）——经典 N+1，配 `select_related` 才可控 ✅ 设计成立；**B4 stale 闭包**；`json()` 里剥掉 `key_secret/key_id` 有安全意识 ✅（Alioss 同）。
- TableField：`max_rows` 不校验（§2.10）；`validate_by_each_field` 用 pcall 捕获子 model 校验错误并带行号 index 上抛 ✅。
- Alioss 家族：env 默认值 + `byte_size_parser` ✅；`get_options` 里 size/size_arg 的换名还原逻辑对称 ✅。

### 5.8 init.lua（1353 行）

- `create_model_proxy`：闭包分配问题（§3.1）；`cls == proxy` 的自检错误信息友好 ✅。
- `check_field_name`：调用方式是 `self.check_field_name(model, name)`，此时 `model` 还是普通 opts 表——`self[name] ~= nil` 实际只查到了 normalize 过程中已设置的键，**并未如注释所愿检查 Model 类属性**；好在 PG 关键字表拦住了大部分（`select/where/order` 都是关键字），残余风险是 `group_by/query/fields` 这类非关键字方法名。低危，但检查该对准 `Model` 类本身。
- `_make_model_class`：主键唯一性断言、names/detail_names 分桶、auto_now 提名 ✅；**B1 的 Query 实例化**；`unique_together` 校验字段存在 ✅。
- `normalize`：extends 字段合并（含 attrs 深并、嵌套 TableField model 递归 extends）逻辑密集但正确；`mixins` 走 merge_models ✅。
- `resolve_foreignkey_related`：**B5/B6**。
- `materialize_with_table_name`：延迟命名（TableField 场景）设计合理；自动补 id 主键 ✅。
- `validate_update` 的「空值→unique 存 NULL、非 unique 存 ''」注释讲清了 why ✅。
- `save_update`：`#updated` 三分支防御（0 行报不存在、>1 行报异常）✅。
- `_check_upsert_key_error`：批量场景带 `batch_index` 上抛 ✅ 贴心。
- 文件尾的 Model/Sql 方法名冲突静态断言 ✅ 好习惯。

### 5.9 sql.lua（3589 行）

- EXPR_OPERATORS：**B3 year**；`regex/iregex` 对非字符串值会崩（先 `tostring`）；`in` 空表见 §2.3；`week_day` 的 dow+1 与 Django 对齐核对无误 ✓。
- `_base_merge/_base_upsert/_base_updates/align`：CTE 结构核对（与注释里的 SQL 样例一致）✓；`key[1] or key` 取首键判 NULL 的前提（key 全非空）由 `_check_upsert_key_error` 保证，注释已写明 ✓。
- `_rows_to_array`：insert 空值回填 default、update 保留空值不回填——注释讲明了 why ✓。
- `_get_update_token_with_prefix`：key 列剔除 + auto_now 统一 CURRENT_TIMESTAMP ✓。
- `_parse_column`：分支编号 + bug 存档注释是全库最佳实践 ✅；aggregate 上下文 LEFT JOIN 对齐 Django ✓；join 去重 `_join_keys` ✓；`_handle_manual_join` 的同步回调契约注释（防止 lazy 化踩闭包）✅ 极好。
- `_resolve_Q`：递归丢 context（§2.11）。
- `statement()`：union_all 括号/with 的两难有注释坦白 ✓。
- `copy`：**B9**。
- `count/exists`：**B2**；`exists` 包 `SELECT EXISTS(...)` + compact 取 `[1][1]` ✓。
- `get`：`limit(2)` 探测法 ✓；语义见 §2.5。
- `first/last/latest/earliest/reverse`：`_reverse_order_token` 对 NULLS FIRST/LAST 的翻转处理 ✓ 细心。
- `select_related/select_related_labels`：平铺键设计（§2.1）；`'*'` 展开 fk_model.field_names ✓。
- `where_recursive`：自引用校验、`_from` 重写为递归 CTE 别名、与外层 select 的别名协同——巧妙且有 spec 覆盖 ✓；「只能调用一次/必须在 from 前」的防御 ✓。
- `get_or_create/update_or_create`：竞态（§2.6）；`__is_inserted__` 哨兵列进出干净 ✓。
- `meta_query`：`select_args` 的顺序即执行顺序，terminal 方法（flat/get/exists）返回非 builder 后靠"恰好排在最后"不崩——加个 break 更稳。`limit` 有 MAX_LIMIT=10000 兜底 ✓（HTTP 透传场景重要）。
- `exec_statement`：prepend/append 的多结果取位 ✓；`affected_rows` 清理 ✓；raw 默认值语义（§2.1）。

### 5.10 spec 与 docs

- model_spec.lua 2029 行、232 用例、真实 DB 断言执行结果而非 SQL 字符串——测试策略正确（SQL 字符串断言最脆）。种子数据自清理约定 ✅。
- bug_spec.lua 把历史 bug 钉成回归测试 ✅。
- 缺口：事务跨 model 场景（B1 正好漏网）、`count()` 与已有 select 组合、`__year` 对 timestamp 的边界日、自引用 FK 传表值、双 FK 默认反向名——本次发现的每个 bug 都值得补一条 spec。
- docs 六篇结构完整，中文质量高；与实现的漂移点集中在返回类型与 raw 语义（§2.1）。

---

## 6. 建议的修复优先级（已全部执行完毕，仅存档）

1. ~~**B1 事务**（数据正确性，修法见 §1.B1）→ 补跨 model 事务 spec~~ ✅
2. ~~**B3 `__year`** + **B8 time/datetime 边界**（静默错误数据）~~ ✅
3. ~~**B2 count**、**B7 连接释放**（稳定性）~~ ✅
4. ~~**B4/B5/B6 外键反向体系**（模型定义期就能 fail loud 的都改成断言）~~ ✅
5. ~~**B9 copy、B10 潜伏组**（顺手修）~~ ✅
6. ~~§3 优化项按需，proxy 闭包缓存收益最大~~ ✅

仍开放的事项（截至 2026-07-16 第四轮后）：
- validate 三态协议（用户拍板不动）
- `check_field_name` 的 EXPR_OPERATORS 大小写失效检查（见顶部注记「新发现」，权衡后维持现状）

第四轮已完成（2026-07-16，全量 263/263）：
- **`Count{'col', distinct=true}`** → `COUNT(DISTINCT ...)`；**`filter = Q{...}/kwargs表`** →
  `FILTER (WHERE ...)`（PG 9.4+），annotate/alias/aggregate 三入口统一走 `Sql:_get_func_token`；
  filter 条件按 where 语义解析，docs 已注明「跨表遍历会改变聚合前行集，请只用本表列」。
- **`_parse_column` 拆模块**：解析簇（`parse_column`/`parse_having_column`/`get_having_column`）
  迁至 `lib/model/parser.lua`，`EXPR_OPERATORS`/`JSON_OP_MAP`/`JSON_TEXT_OPS` 迁至
  `lib/model/expr.lua`（纯函数、零 builder 状态）；sql.lua 留 `@private` 薄壳，
  全部调用点与 `Sql.EXPR_OPERATORS` 导出保持不变，bug_spec 全部解析回归零改动通过。
