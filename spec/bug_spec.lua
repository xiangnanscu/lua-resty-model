---@diagnostic disable: param-type-mismatch, undefined-global
--[[
  bug_spec.lua —— 演示 lib/model/sql.lua 中 _parse_column / _parse_having_column
  路径下已发现的 bug。每个 it 都只调用 :statement() 生成 SQL 字符串，
  不连接数据库，可单独运行。

  断言锁定的是「当前 (buggy) 行为」，便于 reviewer 直接看到 bug 输出；
  修复后这些断言会失败，提示需要更新预期。
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
    { 'name', maxlength = 200 },
    { 'age',  type = 'integer' },
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
  describe('sql.lua _parse_column / _parse_having_column 已知 bug', function()
    -------------------------------------------------------------------
    it('BUG-B1: _parse_having_column 把首个 __ 之后的全部当 op', function()
      -- key = "cnt__nope__gte"
      -- 当前: _parse_having_column 只 find 第一个 "__"，op = key:sub(b+1) = "nope__gte"
      -- 期望: op 应只取最后一段 ("gte") 或显式报 "invalid chain"，
      --       并对中间段 "nope" 给出明确解析错误
      local ok, err = pcall(function()
        Entry:annotate { cnt = Count('id') }
            :group_by { 'blog_id' }
            :having { cnt__nope__gte = 1 }
            :statement()
      end)
      assert.is_false(ok)
      err = tostring(err)
      -- 直接证据: 错误信息里出现了「带 __ 的 op」
      assert.is_truthy(err:find('nope__gte', 1, true),
        'BUG B1: op 被错误地截取为 "nope__gte"; err=' .. err)
      assert.is_truthy(err:find('invalid sql op', 1, true),
        'BUG B1: 错误信息走的是 _get_expr_token 的 op 未知分支，'
        .. '说明 having 没把 "nope" 当作非法路径段拒绝; err=' .. err)
    end)

    -------------------------------------------------------------------
    it('BUG-B2: annotate 命中后续 traversal 段被静默吞掉', function()
      -- 用户写: where { x__name__contains = 'a' }
      -- x 是 annotate 别名 -> branch 2 设置 final_column = annotate[x]
      -- 之后 iter 在 1.1 把 column/prefix 改成 blog.name，
      -- 但 post-loop `return final_column or ...` 仍返回 annotate 表达式，
      -- 导致 blog.name 段被完全丢弃。
      local sql = Blog:annotate { x = Count('entry') }
          :where { x__name__contains = 'a' }
          :statement()

      -- 提取 WHERE 子句
      local where_pos = sql:find('WHERE', 1, true)
      assert.is_truthy(where_pos, 'expected WHERE in sql: ' .. sql)
      local where_clause = sql:sub(where_pos)

      -- 直接证据 1: WHERE 用了 annotate 的 COUNT 表达式做 LIKE 左操作数
      assert.is_truthy(where_clause:find('COUNT', 1, true),
        'BUG B2: WHERE 使用了 annotate 的 COUNT 表达式; sql=' .. sql)
      assert.is_truthy(where_clause:find('LIKE', 1, true),
        'BUG B2: contains 应展开为 LIKE; sql=' .. sql)

      -- 直接证据 2: 用户真正想匹配的 name 字段在 WHERE 里完全不出现
      assert.is_falsy(where_clause:find('name', 1, true),
        'BUG B2: name 段被静默丢弃，未出现在 WHERE 中; sql=' .. sql)
    end)

    -------------------------------------------------------------------
    it('BUG-B5: where_in 静默丢弃 __op 后缀', function()
      -- 用户写: where_in('blog_id__gt', {1, 2})
      -- _parse_column 返回 (column, 'gt'), 但 where_in 在
      --   Sql._base_where_in(self, self:_parse_column(cols), range)
      -- 把多返回值压成 1 个 -> op 'gt' 被丢弃
      -- 最终 SQL 仍然是 IN，等价于用户写 'blog_id'，"__gt" 当成不存在
      local sql = Entry:where_in('blog_id__gt', { 1, 2 }):statement()

      assert.is_truthy(sql:find(' IN ', 1, true),
        'BUG B5: where_in 仍生成 IN 子句; sql=' .. sql)
      -- 没有任何比较运算符出现 (没有 >)
      assert.is_falsy(sql:find(' > ', 1, true),
        'BUG B5: __gt 完全消失，没有生成任何 > 比较; sql=' .. sql)
      -- 期望: where_in 看到带 __op 的 col 应 assert/error，
      --       而非静默退化为相等列上的 IN
    end)

    -------------------------------------------------------------------
    it('BUG-B7: 聚合上下文中正向 FK 仍使用 INNER JOIN', function()
      -- annotate(Count('author__name')) 触发 _parse_column(.., 'aggregate')
      -- _parse_column 仅在 reversed-fk 分支 (line 1719-1722) 根据 context
      -- 切到 LEFT JOIN，正向 FK (1.4.2, line 1634) 仍写死 INNER。
      -- Django 行为是整条聚合链都走 LEFT，否则没作者的 Book 会被 drop。
      local sql = Book:annotate { c = Count('author__name') }:statement()

      assert.is_truthy(sql:find('INNER JOIN', 1, true),
        'BUG B7: 正向 FK 仍走 INNER JOIN; sql=' .. sql)
      assert.is_falsy(sql:find('LEFT JOIN', 1, true),
        'BUG B7: 聚合上下文里正向 FK 应改 LEFT JOIN，但当前没有; sql=' .. sql)
    end)

    -------------------------------------------------------------------
    it('BUG-B4: blog_id__id 冗余后缀后再加段，错误信息不指向 blog_id', function()
      -- "blog_id__id__notop":
      --   iter1 blog_id  -> 1.1, column=blog_id, model 跳到 Blog
      --   iter2 id       -> 1.4.1 (redundant FK suffix), 回滚 column=token=blog_id,
      --                     但 last_field 被设为 Blog.fields.id (主键 field)，
      --                     已脱离原 FK 上下文
      --   iter3 notop    -> branch 5, EXPR_OPERATORS[notop]==nil -> assert fail
      -- 当前错误信息只说 "invalid operator: notop"，完全不提 blog_id 链
      local ok, err = pcall(function()
        Entry:where { blog_id__id__notop = 1 }:statement()
      end)
      assert.is_false(ok)
      err = tostring(err)

      assert.is_truthy(err:find('notop', 1, true),
        'BUG B4: err 应至少提到 notop; err=' .. err)
      -- 直接证据: 错误信息丢失了 blog_id 上下文，
      -- reviewer 看到 err 完全猜不出问题源头是 FK 链
      assert.is_falsy(err:find('blog_id', 1, true),
        'BUG B4: 错误信息未提及 blog_id 链上下文，调试不友好; err=' .. err)
    end)
  end)
end

if is_running_with_busted() then
  main()
else
  return { Blog = Blog, Entry = Entry, Author = Author, Book = Book }
end
