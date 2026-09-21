---@diagnostic disable: param-type-mismatch, undefined-global, redundant-parameter
--[[
  review_spec.lua —— docs/orm-review.md 第 2 节「已确认的 bug」的回归用例（任务 T0）

  每个 it 以 bug 编号开头，对应任务 T1–T12 的验收标准：修复前一律因**断言失败**而红
  （不是加载错误、也不是未捕获的运行时错误 —— 会抛错的路径统一用 pcall 包住后断言），
  修复后转绿。

  数据约定（CLAUDE.md）：
  - 全部使用 review_ 前缀的独立表 + 独立 POOL_NAME，不碰 model_spec 的表与连接池；
  - before_each 重建种子，任一用例写坏数据都不会传染下一个用例；
  - B1 必须用它自己的 POOL_NAME 与 QUERY_TIMEOUT：脏连接会留在那个池子里，
    也正因为这两个参数才能复现，禁止调整。
]]
local migrate = require "resty.migrate"
local Model = require("model")
local Query = require("model.query")
local NULL = Model.NULL

Model.auto_primary_key = true

---------------------------------------------------------------------
-- 独立连接池 + 独立表
---------------------------------------------------------------------
local db_config = {
  DATABASE = 'test',
  USER = 'postgres',
  PASSWORD = 'postgres',
  POOL_NAME = 'review',
}

---@class ReviewBlog
local ReviewBlog = Model:create_model {
  table_name = 'review_blog',
  db_config = db_config,
  fields = {
    { "name",    maxlength = 50, unique = true, compact = false },
    { "tagline", type = 'text',  default = 'default tagline' },
  }
}

---@class ReviewEntry
local ReviewEntry = Model:create_model {
  table_name = 'review_entry',
  db_config = db_config,
  fields = {
    { 'blog_id',  reference = ReviewBlog, related_query_name = 'review_entry' },
    { "headline", maxlength = 255,        compact = false },
    { "rating",   type = 'integer' },
  }
}

---@class ReviewViewLog
local ReviewViewLog = Model:create_model {
  table_name = 'review_view_log',
  db_config = db_config,
  fields = {
    { 'entry_id', reference = ReviewEntry, related_query_name = 'review_view_log' },
    { "ctime",    type = 'datetime' },
  }
}

---@class ReviewAuthor
local ReviewAuthor = Model:create_model {
  table_name = 'review_author',
  db_config = db_config,
  fields = {
    { "name",    maxlength = 100,  unique = true, compact = false },
    { "age",     type = 'integer' },
    { "payload", type = 'json' },
  }
}

local model_list = { ReviewBlog, ReviewEntry, ReviewViewLog, ReviewAuthor }

---------------------------------------------------------------------
-- 工具
---------------------------------------------------------------------

---安全取行内字段：结果不是表时返回 nil，让失败落在断言上而不是 index nil 上
local function field_of(row, key)
  if type(row) ~= 'table' then
    return nil
  end
  return row[key]
end

---安全取结果集第一行的某列
local function first_field(res, key)
  if type(res) ~= 'table' then
    return nil
  end
  return field_of(res[1], key)
end

local function count_keys(t)
  if type(t) ~= 'table' then
    return -1
  end
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

local function recreate_tables()
  for i = #model_list, 1, -1 do
    assert(ReviewBlog.query("DROP TABLE IF EXISTS " .. model_list[i].table_name .. " CASCADE"))
  end
  for _, m in ipairs(model_list) do
    assert(ReviewBlog.query(migrate.get_table_defination(m)))
  end
end

local SEED = {}

local function seed_data()
  for i = #model_list, 1, -1 do
    ReviewBlog.query("TRUNCATE TABLE " .. model_list[i].table_name .. " RESTART IDENTITY CASCADE")
  end
  ReviewBlog:insert {
    { name = 'review-blog-1', tagline = 'first review blog' },
    { name = 'review-blog-2', tagline = 'second review blog' },
  }:exec()
  SEED.blogs = ReviewBlog:order('id'):exec()
  -- 第一行 rating 故意为 NULL：B5（compact 占位）与 B8（IS NULL）都依赖它
  ReviewEntry:insert {
    { blog_id = SEED.blogs[1].id, headline = 'review entry 1', rating = NULL },
    { blog_id = SEED.blogs[1].id, headline = 'review entry 2', rating = 5 },
    { blog_id = SEED.blogs[2].id, headline = 'review entry 3', rating = 4 },
  }:exec()
  SEED.entries = ReviewEntry:order('id'):exec()
  ReviewAuthor:insert { { name = 'review-author-1', age = 30 } }:exec()
  SEED.authors = ReviewAuthor:order('id'):exec()
end

---------------------------------------------------------------------
-- main()
---------------------------------------------------------------------
local function main()
  recreate_tables()
  seed_data()

  describe("REVIEW T0: orm-review.md 已确认 bug 回归", function()
    before_each(function()
      seed_data()
    end)

    -------------------------------------------------------------------
    it("B1 传输层错误后的连接不能放回连接池（否则读到上一条的结果集）", function()
      -- 独立池 + 1500ms 读超时：pg_sleep(2) 必然读超时，且回包滞留在 socket 里
      local q = Query {
        DATABASE = 'test',
        USER = 'postgres',
        PASSWORD = 'postgres',
        QUERY_TIMEOUT = 1500,
        POOL_NAME = 'review_stale',
      }

      -- 非事务路径
      local pid_before = first_field(q("SELECT pg_backend_pid() AS pid"), 'pid')
      assert.is_truthy(pid_before, 'B1: 取 backend pid 失败')
      local timed_out = pcall(q, "SELECT pg_sleep(2), 'FROM_TIMED_OUT_QUERY' AS marker")
      assert.is_false(timed_out, 'B1: pg_sleep(2) 在 1500ms 读超时下应报错')
      local ok2, res2 = pcall(q, "SELECT pg_backend_pid() AS pid, 'SECOND' AS marker")
      assert.is_true(ok2, 'B1: 超时后的下一条查询不应报错; err=' .. tostring(res2))
      assert.are.same(first_field(res2, 'marker'), 'SECOND',
        'B1: 第二条查询必须拿到自己的结果集，而不是上一条超时查询滞留的回包')
      assert.is_true(first_field(res2, 'pid') ~= pid_before,
        'B1: 传输层错误后的脏连接必须被关闭，不能复用同一个 backend')

      -- 事务路径：错误分支同样不能把脏连接放回池子
      local pid_tx = first_field(q("SELECT pg_backend_pid() AS pid"), 'pid')
      local tx_ok = pcall(q.transaction, function()
        q("SELECT pg_sleep(2), 'FROM_TIMED_OUT_TX' AS marker")
      end)
      assert.is_false(tx_ok, 'B1: 事务内读超时应上抛')
      local ok3, res3 = pcall(q, "SELECT pg_backend_pid() AS pid, 'AFTER_TX' AS marker")
      assert.is_true(ok3, 'B1: 事务超时后的下一条查询不应报错; err=' .. tostring(res3))
      assert.are.same(first_field(res3, 'marker'), 'AFTER_TX',
        'B1: 事务路径的脏连接同样会让后续查询错位一格')
      assert.is_true(first_field(res3, 'pid') ~= pid_tx,
        'B1: 事务路径的脏连接也必须被关闭')
    end)

    -------------------------------------------------------------------
    it("B2 事务内被吞掉的错误必须阻止 COMMIT（不能静默变成 ROLLBACK）", function()
      local before = ReviewBlog:count()
      local ok, err = pcall(function()
        return ReviewBlog:transaction(function()
          ReviewBlog:insert { name = 'b2-swallow' }:exec()
          -- 唯一冲突被调用方吞掉：此后 PG 会话进入 aborted，COMMIT 会被当作 ROLLBACK
          pcall(function()
            ReviewBlog:insert { name = 'b2-swallow' }:exec()
          end)
          return 'callback returned normally'
        end)
      end)
      assert.is_false(ok,
        'B2: 事务已 aborted 时 transaction() 必须抛错，而不是返回 callback 的返回值')
      assert.is_truthy(tostring(err):find('aborted', 1, true),
        'B2: 错误信息应说明事务已被先前的错误中止; err=' .. tostring(err))
      assert.are.same(ReviewBlog:count(), before, 'B2: aborted 事务不应落库')
      assert.is_falsy(ReviewBlog:where { name = 'b2-swallow' }:exists(),
        'B2: 被静默回滚的行不应存在')
    end)

    -------------------------------------------------------------------
    it("B3 大整数与 nan/inf 字面量不能静默失真", function()
      -- 15 位整数：double 能精确表示，必须原样渲染而不是 1e+14
      assert.are.same(Model.as_literal(100000000000000), '100000000000000',
        'B3: 1e14 级整数被渲染成科学计数法会匹配错行')
      -- 2^53 起 double 已不精确：要么精确渲染，要么报错，不能静默给出错误的字面量
      local ok_53, lit_53 = pcall(Model.as_literal, 2 ^ 53)
      assert.is_true(not ok_53 or lit_53 == '9007199254740992',
        'B3: 2^53 应精确渲染或直接报错; got=' .. tostring(lit_53))
      local ok_big, lit_big = pcall(Model.as_literal, 123456789012345678)
      assert.is_true(not ok_big or lit_big == '123456789012345680',
        'B3: 超过 2^53 的 number 不能静默渲染成 1.2345678901235e+17; got=' .. tostring(lit_big))
      -- 19 位雪花 ID 只能以 int64 cdata 精确传递，as_literal 必须支持
      local ok_ll, lit_ll = pcall(Model.as_literal, 123456789012345678LL)
      assert.is_true(ok_ll and lit_ll == '123456789012345678',
        'B3: int64 cdata 应渲染成精确整数（去掉 LL 后缀）; got=' .. tostring(lit_ll))
      -- nan/inf 是 PG 语法错误，应在拼 SQL 前就报错
      assert.is_false((pcall(Model.as_literal, 0 / 0)), 'B3: nan 应报错')
      assert.is_false((pcall(Model.as_literal, math.huge)), 'B3: inf 应报错')
    end)

    -------------------------------------------------------------------
    it("B4 带时区偏移的 datetime 经 CTE 路径不能丢失偏移", function()
      local eid = SEED.entries[1].id
      local ins_ok, ins = pcall(function()
        return ReviewViewLog:insert { entry_id = eid, ctime = '2024-01-01T00:00:00Z' }
          :returning('id', 'ctime'):exec()[1]
      end)
      assert.is_true(ins_ok, 'B4: insert 应成功; err=' .. tostring(ins))
      local up_ok, up = pcall(function()
        return ReviewViewLog:updates({ { id = field_of(ins, 'id'), ctime = '2024-01-01T00:00:00Z' } }, 'id')
          :returning('ctime'):exec()[1]
      end)
      assert.is_true(up_ok, 'B4: updates 应成功; err=' .. tostring(up))
      assert.are.same(field_of(up, 'ctime'), field_of(ins, 'ctime'),
        'B4: 同一个带时区的值走 insert(VALUES) 与走 updates(CTE) 必须落成同一时刻')
      -- 根因：CTE 首行用 db_type(timestamp) 做 cast，PG 会忽略偏移
      local stmt = ReviewViewLog:merge(
        { { id = field_of(ins, 'id'), entry_id = eid, ctime = '2024-01-01T00:00:00Z' } }, 'id'):statement()
      assert.is_truthy(stmt:find('::timestamptz', 1, true),
        'B4: CTE 首行的 cast 应与列类型（timestamptz）一致; sql=' .. stmt)
    end)

    -------------------------------------------------------------------
    it("B5 NULL 列在 compact 结果里必须占位（否则 values_list/flat 列错位）", function()
      local vl = ReviewEntry:order('id'):values_list { 'id', 'rating' }
      assert.are.same(#vl, 3, 'B5: 应返回 3 行')
      assert.are.same(#vl[1], 2,
        'B5: rating 为 NULL 的行长度必须仍是 2，否则 compact 数组的位置语义崩了')
      assert.are.same(vl[1][2], NULL, 'B5: NULL 位应是 ngx.null 占位')
      local flat = ReviewEntry:order('id'):values_list('rating', { flat = true })
      assert.are.same(#flat, ReviewEntry:count(),
        'B5: flat 的元素数必须等于行数，否则与同序的 id 列表对不上')
    end)

    -------------------------------------------------------------------
    it("B6 validate_create 的 table 型 default 不能跨调用共享同一个表", function()
      local Tmp = Model:create_model {
        table_name = 'review_tmp_default',
        db_config = db_config,
        fields = {
          { 'name', maxlength = 20 },
          { 'tags', type = 'array', default = { 'a' } },
        }
      }
      local d1 = Tmp:validate_create { name = 'b6' }
      local d2 = Tmp:validate_create { name = 'b6' }
      assert.is_true(type(d1) == 'table' and type(d1.tags) == 'table', 'B6: 应回填 default')
      assert.is_false(d1.tags == d2.tags,
        'B6: 两次 validate_create 拿到的 default 表不能是同一个对象（跨请求状态泄漏）')
      d1.tags[#d1.tags + 1] = 'LEAK'
      local d3 = Tmp:validate_create { name = 'b6' }
      assert.are.same(table.concat(d3.tags, ','), 'a',
        'B6: 修改上一次返回的 default 不应污染字段定义上的 default')
    end)

    -------------------------------------------------------------------
    it("B7 get_or_create 必须走字段校验与 prepare_for_db", function()
      local ok1, rec1 = pcall(ReviewAuthor.get_or_create, ReviewAuthor,
        { name = 'b7-json' }, { payload = { a = 1 } })
      assert.is_true(ok1, 'B7: json 型 defaults 应能写入（create 路径能过就不该 500）; err=' .. tostring(rec1))
      assert.are.same(field_of(field_of(rec1, 'payload'), 'a'), 1, 'B7: payload 应按 json 编码写入')

      local ok2, rec2 = pcall(ReviewAuthor.get_or_create, ReviewAuthor,
        { name = 'b7-empty-int' }, { age = '' })
      assert.is_true(ok2, 'B7: 整数字段传空串应经 prepare_for_db 落成 NULL; err=' .. tostring(rec2))
      local age = field_of(rec2, 'age')
      assert.is_true(age == nil or age == NULL, 'B7: 空串应写成 NULL; got=' .. tostring(age))
    end)

    -------------------------------------------------------------------
    it("B8 where{col = NULL} 必须生成 IS NULL 而不是恒假的 = NULL", function()
      local stmt = ReviewEntry:where { rating = NULL }:statement()
      assert.is_truthy(stmt:find('IS NULL', 1, true),
        'B8: NULL 相等条件应转成 IS NULL; sql=' .. stmt)
      assert.are.same(ReviewEntry:where { rating = NULL }:count(),
        ReviewEntry:where { rating__isnull = true }:count(),
        'B8: where{col=NULL} 应与 col__isnull=true 命中同样的行')
      local ne_stmt = ReviewEntry:where { rating__ne = NULL }:statement()
      assert.is_truthy(ne_stmt:find('IS NOT NULL', 1, true),
        'B8: NULL 不等条件应转成 IS NOT NULL; sql=' .. ne_stmt)
    end)

    -------------------------------------------------------------------
    it("B9 meta_query 只接受数据，字符串条件必须拒绝（注入面）", function()
      assert.is_false((pcall(ReviewBlog.meta_query, ReviewBlog, { where = "1=1", select = { 'id' } })),
        'B9: where 收到字符串应报错，否则请求参数可原样拼进 SQL')
      assert.is_false((pcall(ReviewBlog.meta_query, ReviewBlog, { get = "1=1" })),
        'B9: get 收到字符串应报错')
      assert.is_false((pcall(ReviewBlog.meta_query, ReviewBlog, { try_get = "1=1" })),
        'B9: try_get 收到字符串应报错')
      -- 正常的 table 用法不受影响
      local ok, rows = pcall(ReviewBlog.meta_query, ReviewBlog,
        { where = { name = 'review-blog-1' }, select = { 'name' } })
      assert.is_true(ok, 'B9: table 形式的条件应照常工作; err=' .. tostring(rows))
      assert.are.same(first_field(rows, 'name'), 'review-blog-1')
    end)

    -------------------------------------------------------------------
    it("B11 回调形式的 where/select 在无 JOIN 时也要拿到 ctx", function()
      local ok, rec = pcall(function()
        return ReviewBlog:where(function(ctx)
          return ctx[1].name .. " = 'review-blog-1'"
        end):get()
      end)
      assert.is_true(ok, 'B11: 文档给的无 JOIN 回调示例不应抛错; err=' .. tostring(rec))
      assert.are.same(field_of(rec, 'name'), 'review-blog-1')
      local ok2, rows = pcall(function()
        return ReviewBlog:select(function(ctx)
          return ctx[1].name
        end):order('id'):exec()
      end)
      assert.is_true(ok2, 'B11: select 回调同样不应抛错; err=' .. tostring(rows))
      assert.are.same(first_field(rows, 'name'), 'review-blog-1')
    end)

    -------------------------------------------------------------------
    it("B12 in_bulk({}) 必须返回空表而不是全表", function()
      -- 不传参仍是「取全集」的文档行为
      assert.are.same(count_keys(ReviewBlog:in_bulk()), 2, 'B12: 不传参应返回全集')
      assert.are.same(count_keys(ReviewBlog:in_bulk {}), 0,
        'B12: 空 id 列表应返回空表（Django 语义），否则一次请求拉整张表')
    end)

    -------------------------------------------------------------------
    it("B13 JSON 字段里的空数组往返后必须仍是数组", function()
      local ok, rec = pcall(function()
        return ReviewAuthor:insert { name = 'b13-json', payload = { tags = {} } }
          :returning('id'):exec()[1]
      end)
      assert.is_true(ok, 'B13: 插入带空数组的 json 应成功; err=' .. tostring(rec))
      local id = field_of(rec, 'id')
      assert.is_truthy(id, 'B13: 应返回主键')
      local raw = ReviewAuthor.query(
        string.format("SELECT payload::text AS t FROM review_author WHERE id = %s", tostring(id)))
      local text = tostring(first_field(raw, 't'))
      assert.is_truthy(text:gsub('%s+', ''):find('"tags":[]', 1, true),
        'B13: 空数组被编码成空对象，前端按数组处理会崩; payload=' .. text)
    end)

    -------------------------------------------------------------------
    it("B16 where('col', nil) 必须报错而不是退化成裸 SQL", function()
      local ok, res = pcall(function()
        return ReviewBlog:where('name', nil):statement()
      end)
      assert.is_false(ok,
        'B16: 两参形式的值为 nil 时应报错，否则生成 `WHERE name` 改变筛选语义; sql=' .. tostring(res))
      -- 正常的两参形式不受影响
      local ok2, stmt2 = pcall(function()
        return ReviewBlog:where('name', 'review-blog-1'):statement()
      end)
      assert.is_true(ok2, 'B16: 两参形式正常值应照常工作; err=' .. tostring(stmt2))
      assert.is_truthy(tostring(stmt2):find("name = 'review-blog-1'", 1, true), 'sql=' .. tostring(stmt2))
    end)
  end)

  describe("REVIEW: 疑似问题与设计建议回归", function()
    before_each(function()
      seed_data()
    end)

    -------------------------------------------------------------------
    it("S2/T13 新建连接必须强制 standard_conforming_strings = on", function()
      -- 用一条管理连接把**库级默认**改成 off，模拟「服务端/角色级配置被改掉」的部署。
      -- 转义安全不能建立在「PG 默认值没人动过」这个假设上，这里就是把假设打掉。
      local admin = Query {
        DATABASE = 'test',
        USER = 'postgres',
        PASSWORD = 'postgres',
        POOL_NAME = 'review_scs_admin',
      }
      admin("ALTER DATABASE test SET standard_conforming_strings = off")

      -- 独立池名保证下面这条走的是新建连接（getreusedtimes() == 0），即会话初始化路径
      local q = Query {
        DATABASE = 'test',
        USER = 'postgres',
        PASSWORD = 'postgres',
        POOL_NAME = 'review_scs',
      }
      local probe = { pcall(q, "SHOW standard_conforming_strings") }
      -- `a\'b`：as_literal 只转义单引号，渲染成 'a\''b'。
      -- scs=on 时它是一个字面量 a\'b；scs=off 时 \' 变成转义引号，字面量提前闭合，
      -- 后面的内容漏到 SQL 正文里 —— 这正是 S2 描述的注入面。
      local payload = [[a\'b]]
      local round = { pcall(q, "SELECT " .. Model.as_literal(payload) .. " AS v") }

      -- 断言之前先恢复库级默认：用例中途失败也不能把本机环境留在 off 上
      admin("ALTER DATABASE test RESET standard_conforming_strings")

      assert.is_true(probe[1], 'T13: SHOW 查询不应报错; err=' .. tostring(probe[2]))
      assert.are.same(first_field(probe[2], 'standard_conforming_strings'), 'on',
        'T13: 库级默认被改成 off 时，ORM 必须在建连时把它强制回 on')
      assert.is_true(round[1],
        'T13: scs=off 下含反斜杠的值会拼出越界的 SQL; err=' .. tostring(round[2]))
      assert.are.same(first_field(round[2], 'v'), payload,
        'T13: 反斜杠 + 单引号的值必须原样往返')
    end)

    -------------------------------------------------------------------
    it("D8/T15 终结方法必须在副本上执行（复用 builder 不串条件）", function()
      local blog1 = SEED.blogs[1].id
      local q = ReviewEntry:where { blog_id = blog1 }

      -- count() 会把 _select 改成 count(*)、_order 清掉。修复前这之后再 exec()
      -- 拿回的是 count 行而不是记录
      assert.are.same(q:count(), 2, 'T15: blog1 下应有 2 条 entry')
      local rows = q:exec()
      assert.are.same(#rows, 2, 'T15: count() 之后同一个 builder 必须还能取回记录; got=' .. tostring(#rows))
      assert.is_truthy(field_of(rows[1], 'headline'),
        'T15: count() 之后 builder 的 _select 不能留着 count(*)')

      -- count(cond) 的条件同样只能作用于副本，不能累积回原 builder
      assert.are.same(q:count { rating = 5 }, 1, 'T15: count(cond) 应按条件计数')
      assert.are.same(q:count(), 2, 'T15: count(cond) 的条件不能留在 builder 上')

      -- exists() 会 select(1):limit(1):compact()
      assert.is_true(q:exists(), 'T15: blog1 下有记录')
      assert.are.same(#q:exec(), 2, 'T15: exists() 的 select 1 / limit 1 不能留在 builder 上')

      -- first()/last() 会写 _order 与 _limit
      local f = q:first()
      local l = q:last()
      assert.is_truthy(field_of(f, 'headline'), 'T15: first() 应返回记录')
      assert.is_truthy(field_of(l, 'headline'), 'T15: last() 应返回记录')
      assert.is_true(field_of(f, 'id') ~= field_of(l, 'id'), 'T15: first/last 应是不同的行')
      assert.are.same(#q:exec(), 2, 'T15: first()/last() 的 limit 1 不能留在 builder 上')

      -- get() 会写 where + limit 2
      local got = q:get { rating = 5 }
      assert.are.same(field_of(got, 'rating'), 5, 'T15: get(cond) 应返回那一行')
      assert.are.same(q:count(), 2, 'T15: get(cond) 的条件与 limit 不能留在 builder 上')

      -- values_list/flat 会改写 _select 并打开 compact/raw
      local ids = q:values_list('id', { flat = true })
      assert.are.same(#ids, 2, 'T15: values_list 应返回 2 个 id')
      local rows2 = q:exec()
      assert.are.same(#rows2, 2, 'T15: values_list 之后 builder 仍应取回完整记录')
      assert.is_truthy(field_of(rows2[1], 'headline'),
        'T15: values_list 之后 builder 的 _select 不能只剩 id')

      -- latest/earliest 会重写 _order
      assert.is_truthy(field_of(q:latest('id'), 'headline'), 'T15: latest 应返回记录')
      assert.are.same(#q:exec(), 2, 'T15: latest() 的 order/limit 不能留在 builder 上')

      -- 原 builder 从头到尾没有被任何终结方法改写：最后一次 exec 与第一次完全一致
      local rows3 = q:order('id'):exec()
      assert.are.same(#rows3, 2, 'T15: builder 复用一整轮之后结果不变')
      assert.are.same(field_of(rows3[1], 'id'), field_of(rows[1], 'id'), 'T15: 行的身份也不变')
    end)

    -------------------------------------------------------------------
    it("S3/T14 非 cosocket 阶段发查询必须报含 phase 的明确错误", function()
      -- 真正的触发场景在 log_by_lua / header_filter 阶段（惰性外键在那里第一次被访问），
      -- 起 nginx 跑多阶段不现实，所以直接把 ngx.get_phase 换掉：
      -- 守卫读的就是它，换掉之后走的是与真实场景完全相同的那条分支。
      local q = Query {
        DATABASE = 'test',
        USER = 'postgres',
        PASSWORD = 'postgres',
        POOL_NAME = 'review_phase',
      }
      -- 先确认守卫不挡正常阶段（测试自身跑在 timer 里）
      assert.are.same(first_field(q("SELECT 'PHASE_OK' AS marker"), 'marker'), 'PHASE_OK',
        'T14: 允许的阶段不能被守卫误伤')

      local real_get_phase = ngx.get_phase
      local function with_phase(phase, fn)
        ngx.get_phase = function() return phase end
        local packed = { pcall(fn) }
        ngx.get_phase = real_get_phase
        return packed[1], packed[2]
      end

      for _, phase in ipairs { 'log', 'header_filter', 'body_filter', 'init_worker', 'set' } do
        local ok, err = with_phase(phase, function()
          return q("SELECT 1 AS one")
        end)
        assert.is_false(ok, 'T14: ' .. phase .. ' 阶段发查询必须报错，而不是让 pgmoon 深处抛 API disabled')
        assert.is_truthy(tostring(err):find('phase', 1, true),
          'T14: 错误信息必须点出 phase；err=' .. tostring(err))
        assert.is_truthy(tostring(err):find(phase, 1, true),
          'T14: 错误信息必须点出是哪个阶段；err=' .. tostring(err))
      end

      -- 事务入口同样要挡，否则 BEGIN 先发出去，错误还是从 pgmoon 里抛
      local tx_ok, tx_err = with_phase('log', function()
        return q.transaction(function() return true end)
      end)
      assert.is_false(tx_ok, 'T14: transaction() 在非法阶段也必须报错')
      assert.is_truthy(tostring(tx_err):find('phase', 1, true),
        'T14: transaction() 的错误信息同样要点出 phase；err=' .. tostring(tx_err))

      -- 守卫恢复之后一切照旧（确认上面的 pcall 没把 ngx.get_phase 留在被改写的状态）
      assert.are.same(first_field(q("SELECT 'PHASE_RESTORED' AS marker"), 'marker'), 'PHASE_RESTORED',
        'T14: 阶段恢复后查询应正常')
    end)

    -------------------------------------------------------------------
    it("S4/T14 Query() 缓存命中且配置不同时必须记 WARN", function()
      local pool = 'review_pool_warn_' .. tostring(ngx.now()):gsub('%.', '')
      local captured = {}
      local real_log = ngx.log
      ngx.log = function(level, ...)
        local parts = {}
        for i = 1, select('#', ...) do
          parts[#parts + 1] = tostring((select(i, ...)))
        end
        captured[#captured + 1] = { level = level, msg = table.concat(parts) }
        return real_log(level, ...)
      end
      local ok, err = pcall(function()
        Query {
          DATABASE = 'test',
          USER = 'postgres',
          PASSWORD = 'postgres',
          POOL_NAME = pool,
          QUERY_TIMEOUT = 8000,
        }
        -- 同名池、不同超时：行为上仍以首个为准（事务共享连接依赖这点），但不能静默
        Query {
          DATABASE = 'test',
          USER = 'postgres',
          PASSWORD = 'postgres',
          POOL_NAME = pool,
          QUERY_TIMEOUT = 600000,
        }
      end)
      ngx.log = real_log
      assert.is_true(ok, 'T14: 重复构造同名池不应报错; err=' .. tostring(err))

      local warned = false
      for _, entry in ipairs(captured) do
        if entry.level == ngx.WARN
            and entry.msg:find('query_timeout', 1, true)
            and entry.msg:find(pool, 1, true) then
          warned = true
        end
      end
      assert.is_true(warned,
        'T14: 同名池传入不同 QUERY_TIMEOUT 时必须打 WARN，否则「脚本里调大超时没生效」无从发现')

      -- 同一个键只提醒一次，热路径不能刷屏
      local captured2 = {}
      ngx.log = function(level, ...)
        local parts = {}
        for i = 1, select('#', ...) do
          parts[#parts + 1] = tostring((select(i, ...)))
        end
        captured2[#captured2 + 1] = { level = level, msg = table.concat(parts) }
        return real_log(level, ...)
      end
      pcall(Query, {
        DATABASE = 'test',
        USER = 'postgres',
        PASSWORD = 'postgres',
        POOL_NAME = pool,
        QUERY_TIMEOUT = 600000,
      })
      ngx.log = real_log
      for _, entry in ipairs(captured2) do
        assert.is_falsy(entry.level == ngx.WARN and entry.msg:find('query_timeout', 1, true),
          'T14: 同一个 (pool, key) 的 WARN 只应出现一次')
      end
    end)

    -------------------------------------------------------------------
    it("S4/T14 STATEMENT_TIMEOUT 默认比 QUERY_TIMEOUT 早 2 秒，且不会派生出非正值", function()
      -- 默认：10000 - 2000 = 8000，真的下发到了会话上
      local q = Query {
        DATABASE = 'test',
        USER = 'postgres',
        PASSWORD = 'postgres',
        POOL_NAME = 'review_stmt_default',
      }
      assert.are.same(first_field(q("SHOW statement_timeout"), 'statement_timeout'), '8s',
        'T14: 未显式配置时服务端护栏应取 QUERY_TIMEOUT - 2000')

      -- QUERY_TIMEOUT 本身小于 2s 时派生值为负，必须退回「不下发」，
      -- 否则每条 SQL 都会被服务端立刻 cancel（B1 用例用的就是 1500ms 的池子）
      local q_short = Query {
        DATABASE = 'test',
        USER = 'postgres',
        PASSWORD = 'postgres',
        POOL_NAME = 'review_stmt_short',
        QUERY_TIMEOUT = 1500,
      }
      assert.are.same(first_field(q_short("SHOW statement_timeout"), 'statement_timeout'), '0',
        'T14: QUERY_TIMEOUT 不足 2s 时不能派生出非正的 statement_timeout')

      -- 显式值优先，0 表示服务端不限
      local q_zero = Query {
        DATABASE = 'test',
        USER = 'postgres',
        PASSWORD = 'postgres',
        POOL_NAME = 'review_stmt_zero',
        STATEMENT_TIMEOUT = 0,
      }
      assert.are.same(first_field(q_zero("SHOW statement_timeout"), 'statement_timeout'), '0',
        'T14: STATEMENT_TIMEOUT = 0 应下发「不限」')

      local q_explicit = Query {
        DATABASE = 'test',
        USER = 'postgres',
        PASSWORD = 'postgres',
        POOL_NAME = 'review_stmt_explicit',
        STATEMENT_TIMEOUT = 3000,
      }
      assert.are.same(first_field(q_explicit("SHOW statement_timeout"), 'statement_timeout'), '3s',
        'T14: 显式 STATEMENT_TIMEOUT 应原样下发')
    end)

    -------------------------------------------------------------------
    it("D9/T14 Model.LAZY_FK = false 时外键属性访问必须报错而不是偷偷发查询", function()
      local entry = ReviewEntry:where { headline = 'review entry 2' }:raw(false):exec()[1]
      assert.is_truthy(entry, 'T14: 取种子记录失败')

      -- 默认（LAZY_FK = true）：沿用现状，属性访问触发一次 SELECT
      assert.are.same(entry.blog_id.name, 'review-blog-1',
        'T14: 默认仍是惰性加载，行为不变')

      local entry2 = ReviewEntry:where { headline = 'review entry 3' }:raw(false):exec()[1]
      Model.LAZY_FK = false
      local ok, err = pcall(function() return entry2.blog_id.name end)
      Model.LAZY_FK = true
      assert.is_false(ok, 'T14: 关掉开关后惰性加载必须报错')
      assert.is_truthy(tostring(err):find('select_related', 1, true),
        'T14: 错误信息应指出正确写法是 select_related；err=' .. tostring(err))

      -- 恢复后行为照旧，且 select_related 这条路不受开关影响
      assert.are.same(entry2.blog_id.name, 'review-blog-2', 'T14: 开关恢复后惰性加载应可用')
      local joined = ReviewEntry:where { headline = 'review entry 3' }
          :select_related('blog_id', 'name'):raw(false):exec()[1]
      Model.LAZY_FK = false
      local ok2, name2 = pcall(function() return joined.blog_id.name end)
      Model.LAZY_FK = true
      assert.is_true(ok2, 'T14: select_related 取回的外键对象不该再发查询; err=' .. tostring(name2))
      assert.are.same(name2, 'review-blog-2', 'T14: select_related 的值应正确')
    end)
  end)

  describe("REVIEW: 执行中发现（F 系列）回归", function()
    before_each(function()
      seed_data()
    end)

    -------------------------------------------------------------------
    it("F6 大浮点数不能被当成丢了精度的整数拒掉（float 列回归）", function()
      -- 超出 int8 的量级只可能是浮点：按浮点渲染，PG 照常解析（修复 B3 前就是这样）
      assert.are.same(Model.as_literal(1e20), '1e+20', 'F6: 1e20 应渲染成浮点字面量')
      assert.are.same(Model.as_literal(-1e300), '-1e+300', 'F6: -1e300 应渲染成浮点字面量')
      assert.are.same(Model.as_literal(2 ^ 63), '9.223372036854776e+18',
        'F6: 2^63 已超出 int8，应按浮点最短往返渲染')
      -- (2^53, 2^63) 是 bigint 的量级：不知道列类型时仍然报错，B3 的保证不能丢
      local ok_band, err_band = pcall(Model.as_literal, 1.5e17)
      assert.is_false(ok_band, 'F6: 不知道列类型时 (2^53, 2^63) 的整数值仍应报错')
      assert.is_truthy(tostring(err_band):find("'1.5e+17'", 1, true),
        'F6: 报错信息应给出浮点的字符串写法; err=' .. tostring(err_band))

      -- 模型上声明的 float 列：写入与条件都按浮点处理（独立表，用例结束时删掉）
      local ReviewFloat = Model:create_model {
        table_name = 'review_float',
        db_config = db_config,
        fields = {
          { 'name',  maxlength = 20, unique = true },
          { 'score', type = 'float' },
          { 'n',     type = 'integer' },
        }
      }
      assert(ReviewFloat.query("DROP TABLE IF EXISTS review_float"))
      assert(ReviewFloat.query(migrate.get_table_defination(ReviewFloat)))

      local ok_c, rec = pcall(ReviewFloat.create, ReviewFloat, { name = 'f6-a', score = 1.5e17 })
      assert.is_true(ok_c, 'F6: float 列写入 1.5e17 不应报错; err=' .. tostring(rec))
      assert.are.same(field_of(rec, 'score'), 1.5e17, 'F6: 读回值应与写入值逐位相同')
      local ok_i, err_i = pcall(function()
        return ReviewFloat:insert { { name = 'f6-b', score = 1e20 }, { name = 'f6-c', score = -2e17 } }:exec()
      end)
      assert.is_true(ok_i, 'F6: insert 路径同样不应报错; err=' .. tostring(err_i))
      local ok_u, err_u = pcall(function()
        return ReviewFloat:update { score = 3e17 }:where { name = 'f6-c' }:exec()
      end)
      assert.is_true(ok_u, 'F6: update 路径同样不应报错; err=' .. tostring(err_u))

      local ok_w, cnt = pcall(function()
        return {
          eq = ReviewFloat:where { score = 1.5e17 }:count(),
          gt = ReviewFloat:where { score__gt = 2e17 }:count(),
          ['in'] = ReviewFloat:where { score__in = { 1.5e17, 3e17 } }:count(),
          range = ReviewFloat:where { score__range = { 1e17, 1e18 } }:count(),
          two = ReviewFloat:where('score', 1e20):count(),
          three = ReviewFloat:where('score', '<', 2e17):count(),
        }
      end)
      assert.is_true(ok_w, 'F6: float 列上的条件不应报错; err=' .. tostring(cnt))
      assert.are.same({ eq = 1, gt = 2, ['in'] = 2, range = 2, two = 1, three = 1 }, cnt,
        'F6: 各种条件写法都应按浮点比较')

      -- 整数列上的同一个值仍然报错：这正是 B3 要拦的雪花 ID 场景
      local ok_n = pcall(function() return ReviewFloat:where { n = 1.5e17 }:statement() end)
      assert.is_false(ok_n, 'F6: integer 列上的 1.5e17 仍应报错（B3）')

      assert(ReviewFloat.query("DROP TABLE review_float"))
    end)
  end)
end

---------------------------------------------------------------------
-- 与 model_spec.lua / bug_spec.lua 相同的 busted 检测
---------------------------------------------------------------------
local function is_running_with_busted()
  if arg then
    for i = 1, #arg do
      if arg[i] == "-o" or arg[i] == "--output" then
        return true
      end
    end
  end
  if arg and arg[0] and string.match(arg[0], "ngx_busted%.lua$") then
    return true
  end
  return false
end

if is_running_with_busted() then
  main()
else
  return {
    ReviewBlog = ReviewBlog,
    ReviewEntry = ReviewEntry,
    ReviewViewLog = ReviewViewLog,
    ReviewAuthor = ReviewAuthor,
  }
end
