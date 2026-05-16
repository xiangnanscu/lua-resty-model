---@diagnostic disable: param-type-mismatch, undefined-global
--[[
  bug_spec.lua —— 锁定 lib/model/sql.lua 中 _parse_column / _parse_having_column
  路径下已修复 bug 的预期行为。每个 it 都只调用 :statement() 生成 SQL 字符串，
  不连接数据库，可单独运行。
]]
local Model = require("model")
local Count = Model.Count

Model.auto_primary_key = true

---@class Blog
local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { 'name',    maxlength = 20, compact = false },
    { 'tagline', type = 'text',  default = 'default tagline' },
  }
}

---@class Entry
local Entry = Model:create_model {
  table_name = 'entry',
  fields = {
    { 'blog_id',  reference = Blog, related_query_name = 'entry' },
    { 'headline', maxlength = 255 },
    { 'rating',   type = 'integer' },
  }
}

---@class Author
local Author = Model:create_model {
  table_name = 'author',
  fields = {
    { 'name',    maxlength = 200 },
    { 'age',     type = 'integer' },
    { 'payload', type = 'json' },
  }
}

---@class Book
local Book = Model:create_model {
  table_name = 'book',
  fields = {
    { 'name',   maxlength = 300 },
    { 'price',  type = 'float' },
    { 'author', reference = Author },
  }
}

local function is_running_with_busted()
  if arg then
    for i = 1, #arg do
      if arg[i] == '-o' or arg[i] == '--output' then
        return true
      end
    end
  end
  if arg and arg[0] and string.match(arg[0], 'ngx_busted%.lua$') then
    return true
  end
  return false
end

local function main()
  describe('sql.lua _parse_column / _parse_having_column 已修复 bug', function()
    -------------------------------------------------------------------
    it('BUG-B1: _parse_having_column 必须拒绝嵌套 traversal', function()
      -- key = "cnt__nope__gte"
      -- 修复后: HAVING 只支持 'alias__op' 形态，多于一段 __ 直接报错；
      --        即便最后一段恰好是合法 op, 中间段也无意义。
      local ok, err = pcall(function()
        Entry:annotate { cnt = Count('id') }
            :group_by { 'blog_id' }
            :having { cnt__nope__gte = 1 }
            :statement()
      end)
      assert.is_false(ok)
      err = tostring(err)
      assert.is_truthy(err:find('cnt__nope__gte', 1, true),
        'B1: 错误应回显完整 key; err=' .. err)
      assert.is_truthy(err:find('nested traversal', 1, true)
        or err:find('alias__op', 1, true),
        'B1: 错误应说明 having 不支持嵌套; err=' .. err)
    end)

    it('BUG-B1b: _parse_having_column 拒绝未知 op', function()
      local ok, err = pcall(function()
        Entry:annotate { cnt = Count('id') }
            :group_by { 'blog_id' }
            :having { cnt__bogus = 1 }
            :statement()
      end)
      assert.is_false(ok)
      err = tostring(err)
      assert.is_truthy(err:find('bogus', 1, true),
        'B1b: 错误应指出非法 op; err=' .. err)
      assert.is_truthy(err:find('cnt__bogus', 1, true),
        'B1b: 错误应回显完整 key; err=' .. err)
    end)

    -------------------------------------------------------------------
    it('BUG-B2: annotate 后再 traversal 应当显式报错', function()
      -- 修复前: where { x__name__contains = 'a' } 会静默返回
      --        Count(...) LIKE '%a%'，name 段完全丢失。
      -- 修复后: annotate 是 leaf，只允许后跟单个 op；继续 traversal 报错。
      local ok, err = pcall(function()
        Blog:annotate { x = Count('entry') }
            :where { x__name__contains = 'a' }
            :statement()
      end)
      assert.is_false(ok, 'B2: annotate 后再 traversal 应报错')
      err = tostring(err)
      assert.is_truthy(err:find("annotation 'x'", 1, true)
        or err:find("annotation \"x\"", 1, true)
        or err:find('annotation', 1, true),
        'B2: 错误应指明问题出在 annotation; err=' .. err)
      assert.is_truthy(err:find('x__name__contains', 1, true)
        or err:find('name__contains', 1, true),
        'B2: 错误应回显被拒绝的链路; err=' .. err)
    end)

    it('BUG-B2b: annotate + 单个 op 仍然合法', function()
      -- annotate 别名 + 单个 op (cnt__gte=2) 是 Django 等价支持的写法。
      local sql = Blog:annotate { cnt = Count('entry') }
          :where { cnt__gte = 2 }
          :statement()
      assert.is_truthy(sql:find('COUNT', 1, true),
        'B2b: WHERE 应使用 COUNT 表达式; sql=' .. sql)
      assert.is_truthy(sql:find('>= 2', 1, true),
        'B2b: WHERE 应展开为 >= 2; sql=' .. sql)
    end)

    -------------------------------------------------------------------
    it('BUG-B5: where_in 对带 __op 的列名应当报错而非静默退化', function()
      -- 设计：where_in 是 where{col__in = range} 的薄糖衣，col 不允许带比较 op。
      -- IN 谓词本身和 gt/contains 等二元 op 互斥，拼在一起没有合法语义。
      -- traversal (如 'blog__name') 仍合法，被拒绝的只是 op 后缀。
      local ok, err = pcall(function()
        Entry:where_in('blog_id__gt', { 1, 2 }):statement()
      end)
      assert.is_false(ok, '当前 bug 已修：where_in 不应静默接受 __gt')
      err = tostring(err)
      assert.is_truthy(err:find('where_in', 1, true),
        'err 应指明是 where_in 拒绝; err=' .. err)
      assert.is_truthy(err:find('blog_id__gt', 1, true),
        'err 应回显原始列名 blog_id__gt; err=' .. err)
      assert.is_truthy(err:find('gt', 1, true),
        'err 应指出非法 op 是 gt; err=' .. err)
    end)

    -------------------------------------------------------------------
    it('BUG-B5b: where_in 对数组形式同样拒绝带 __op 的元素', function()
      local ok, err = pcall(function()
        Entry:where_in({ 'blog_id', 'rating__lt' }, { { 1, 5 }, { 2, 3 } }):statement()
      end)
      assert.is_false(ok)
      err = tostring(err)
      assert.is_truthy(err:find('rating__lt', 1, true),
        'err 应回显非法元素 rating__lt; err=' .. err)
      assert.is_truthy(err:find('lt', 1, true),
        'err 应指出非法 op 是 lt; err=' .. err)
    end)

    -------------------------------------------------------------------
    it('BUG-B5c: where_in 对纯列名 / traversal 列名仍正常工作', function()
      -- 普通列
      local sql1 = Entry:where_in('blog_id', { 1, 2 }):statement()
      assert.is_truthy(sql1:find(' IN ', 1, true),
        'where_in("blog_id", ...) 应生成 IN; sql=' .. sql1)

      -- 数组形式 (复合 IN)
      local sql2 = Entry:where_in({ 'blog_id', 'rating' }, { { 1, 5 }, { 2, 3 } }):statement()
      assert.is_truthy(sql2:find(' IN ', 1, true),
        'where_in({...}, ...) 应生成 IN; sql=' .. sql2)
    end)

    -------------------------------------------------------------------
    it('BUG-B7: 聚合上下文中正向 FK 应改用 LEFT JOIN (Django 对齐)', function()
      -- annotate(Count('author__name')) 触发 _parse_column(.., 'aggregate')
      -- 修复前: 正向 FK (1.4.2) 写死 INNER JOIN，导致没作者的 Book 被 drop。
      -- 修复后: 正向 FK 与 reversed-fk 分支一样，aggregate 上下文走 LEFT JOIN，
      --         与 Django 行为一致 (Book.objects.annotate(c=Count('author__name'))
      --         => LEFT OUTER JOIN author ON book.author_id = author.id)。
      local sql = Book:annotate { c = Count('author__name') }:statement()

      assert.is_truthy(sql:find('LEFT JOIN', 1, true),
        'BUG B7: 聚合上下文里正向 FK 应使用 LEFT JOIN; sql=' .. sql)
      assert.is_falsy(sql:find('INNER JOIN', 1, true),
        'BUG B7: 聚合上下文里不应再出现 INNER JOIN; sql=' .. sql)
    end)

    -------------------------------------------------------------------
    it('BUG-B4: blog_id__id 冗余后缀后非法 op 错误信息应保留 FK 上下文', function()
      -- 修复前: 1.4.1 把 last_field 改成主键 field，链路上下文丢失，
      --        错误只说 "invalid operator: notop"。
      -- 修复后: 1.4.1 保留 last_field, branch 5 错误信息带上 column / model / 原 key。
      local ok, err = pcall(function()
        Entry:where { blog_id__id__notop = 1 }:statement()
      end)
      assert.is_false(ok)
      err = tostring(err)

      assert.is_truthy(err:find('notop', 1, true),
        'B4: err 应至少提到 notop; err=' .. err)
      assert.is_truthy(err:find('blog_id', 1, true),
        'B4: err 应保留 blog_id 链上下文; err=' .. err)
      assert.is_truthy(err:find('blog_id__id__notop', 1, true),
        'B4: err 应回显完整 key 帮助调试; err=' .. err)
    end)

    -------------------------------------------------------------------
    it('JSON path: 普通比较 op (gt/lt/ne/...) 走 jsonb 比较', function()
      -- 修复前: payload__age__gt=18 会把 'gt' 当 json key,
      --        生成 (payload #> ARRAY['age','gt']) = 18 静默错误。
      -- 修复后: gt 视为终止 op, 走 json_gt: (payload -> 'age') > '18'
      local sql = Author:where { payload__age__gt = 18 }:statement()
      assert.is_truthy(sql:find("->", 1, true),
        "JSON gt: 应使用 -> 提取 jsonb; sql=" .. sql)
      assert.is_falsy(sql:find("'gt'", 1, true),
        "JSON gt: 'gt' 不应作为 json key 出现; sql=" .. sql)
      assert.is_truthy(sql:find("> '18'", 1, true),
        "JSON gt: 应展开为 > '18' (jsonb compare); sql=" .. sql)
    end)

    it('JSON path: text 类 op (startswith) 走 ->> 文本提取', function()
      local sql = Author:where { payload__name__startswith = 'Al' }:statement()
      assert.is_truthy(sql:find("->>", 1, true),
        "JSON startswith: 应使用 ->> 提取 text; sql=" .. sql)
      assert.is_truthy(sql:find("LIKE", 1, true),
        "JSON startswith: 应展开为 LIKE; sql=" .. sql)
    end)

    it('JSON path: 多段 + 普通 op 走 #> jsonb', function()
      local sql = Author:where { payload__a__b__gt = 1 }:statement()
      assert.is_truthy(sql:find("#>", 1, true),
        "JSON multi gt: 应使用 #> 提取 jsonb; sql=" .. sql)
      assert.is_falsy(sql:find("'gt'", 1, true),
        "JSON multi gt: 'gt' 不应进入路径; sql=" .. sql)
      assert.is_truthy(sql:find("> '1'", 1, true),
        "JSON multi gt: 应展开为 > '1'; sql=" .. sql)
    end)

    it('JSON path: 现有 has_key / contains / eq 行为不变', function()
      local sql1 = Author:where { payload__has_key = 'status' }:statement()
      assert.is_truthy(sql1:find("?", 1, true),
        "has_key 仍走 ? 算子; sql=" .. sql1)

      local sql2 = Author:where { payload__contains = { x = 1 } }:statement()
      assert.is_truthy(sql2:find("@>", 1, true),
        "contains 仍走 @> 算子; sql=" .. sql2)

      local sql3 = Author:where { payload__status = 'active' }:statement()
      assert.is_truthy(sql3:find("->", 1, true) and sql3:find("=", 1, true),
        "eq 仍走 -> + =; sql=" .. sql3)
    end)
  end)
end

if is_running_with_busted() then
  main()
else
  return { Blog = Blog, Entry = Entry, Author = Author, Book = Book }
end
