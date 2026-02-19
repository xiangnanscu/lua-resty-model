# 09 — 执行与辅助

> exec / execr / get / try_get / count / exists / flat / as_set / compact / statement

## 执行方法对比

| 方法                         | 返回值                 | 是否 load | 说明                            |
| ---------------------------- | ---------------------- | --------- | ------------------------------- |
| `exec()`                     | `Array<XodelInstance>` | ✅        | 标准执行，返回 Record 实例数组  |
| `execr()`                    | `Array<Record>`        | ❌        | 原始执行，等价于 `raw():exec()` |
| `get(cond?, op?, dval?)`     | `XodelInstance\|false` | ✅        | 获取单条记录                    |
| `try_get(cond?, op?, dval?)` | `XodelInstance\|false` | ✅        | `get` 的别名                    |
| `count(cond?, op?, dval?)`   | `integer`              | ❌        | 返回计数                        |
| `exists()`                   | `boolean`              | ❌        | 检查是否存在                    |
| `flat(col?)`                 | `Array`                | ❌        | 返回扁平数组                    |
| `as_set()`                   | `Set`                  | ❌        | 返回集合                        |
| `statement()`                | `string`               | —         | 仅生成 SQL，不执行              |

---

## Sql:exec() — 标准执行

```lua
---@return Array<XodelInstance>  -- Record 实例数组
---@return number num_queries    -- 执行的查询数量
```

执行 SQL 并返回经过 `model:load()` 处理的 Record 实例数组:

```lua
-- 基本查询
local blogs = Blog:where{id__gt=0}:exec()
for _, blog in ipairs(blogs) do
  print(blog.id, blog.name)
end

-- 返回值是 Array，支持 Array 方法
local names = Blog:exec():map(function(b) return b.name end)

-- 第二个返回值是查询数量
local results, num_queries = Blog:exec()
print(num_queries)  -- 通常为 1

-- INSERT/UPDATE/DELETE + RETURNING
local deleted = Blog:delete{id=1}:returning('*'):exec()
```

---

## Sql:execr() — 原始执行

```lua
---@return table|Array<Record>
---@return number num_queries
```

等价于 `self:raw():exec()`，不经过 `model:load()` 处理:

```lua
local raw = Author:execr()
-- raw[1].resume 是原始 JSON 字符串，而非 Lua table

-- 常用于性能敏感场景
local raw = Blog:select('id'):execr()
```

---

## Sql:get(cond?, op?, dval?) — 获取单条

```lua
---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return XodelInstance|false   -- 找到返回记录，找不到或找到多条返回 false
```

内部逻辑: 执行 `where(cond):limit(2)`，仅当恰好 1 条记录时返回该记录。

### 调用形式

```lua
-- 形式1: 无参数 (需先设置 where)
local blog = Blog:where{id=1}:get()
-- 形式2: table 条件
local blog = Blog:get{id=1}
-- blog.name → 'First Blog'

-- 形式3: 两参数
local blog = Blog:get("name", "First Blog")

-- 形式4: 三参数
local entry = Entry:get("rating", ">=", 5)

-- 形式5: 回调函数
local blog = Blog:get(function(ctx) return 'T."id" = 1' end)

-- 找不到或多条
local result = Blog:get{name='Not Exist'}
-- result == false

-- 空条件表禁止
-- Blog:get{}  -- 会抛出 "empty condition table is not allowed" 错误
```

### 使用注意

- 找到 0 条或 2+ 条都返回 `false`（不抛错）
- 如果需要在找不到时抛错，应自行判断:

```lua
local blog = Blog:get{id=1}
if not blog then
  error("Blog not found")
end
```

---

## Sql:try_get(cond?, op?, dval?) — get 的别名

```lua
---@return XodelInstance|false
```

`try_get` 与 `get` 行为完全相同:

```lua
local blog = Blog:try_get{id=1}
```

---

## Sql:count(cond?, op?, dval?) — 计数

```lua
---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return integer
```

### 调用形式

```lua
-- 形式1: 无参数 (计算全部)
local n = Blog:count()
-- SELECT count(*) FROM blog T

-- 形式2: 带条件
local n = Blog:count{name__contains='Blog'}
-- SELECT count(*) FROM blog T WHERE T."name" LIKE '%Blog%' ESCAPE '\'

-- 形式3: 链式调用后 count
local n = Entry:where{blog_id=1}:count()
-- SELECT count(*) FROM entry T WHERE T."blog_id" = 1

-- 形式4: 两参数
local n = Entry:count("rating", 5)
-- SELECT count(*) FROM entry T WHERE T."rating" = 5

-- 形式5: 三参数
local n = Entry:count("rating", ">", 3)
-- SELECT count(*) FROM entry T WHERE T."rating" > 3

-- 返回值始终是整数，无结果返回 0
```

---

## Sql:exists() — 存在性检查

```lua
---@return boolean
```

```lua
-- 检查是否存在
local has_blogs = Blog:where{name='First Blog'}:exists()
-- SELECT EXISTS (SELECT 1 FROM blog T WHERE T."name" = 'First Blog' LIMIT 1)
-- 返回 true 或 false

-- 典型用法
if Blog:where{name='New Blog'}:exists() then
  print("Blog already exists")
end
```

---

## Sql:flat(col?) — 扁平数组

```lua
---@param col? string|fun(ctx:table):string  -- 要提取的列名
---@return Array<Record>
```

将结果扁平化为一维数组:

### 调用形式

```lua
-- 形式1: 指定列名
local ids = Blog:flat('id')
-- ids = {1, 2}

local names = Blog:flat('name')
-- names = {'First Blog', 'Second Blog'}

-- 形式2: 无参数 (对 compact 结果扁平化)
local ids = Blog:select('id'):flat()
-- ids = {1, 2}

-- 形式3: update/delete + flat
local deleted_ids = Blog:where{id__gt=100}:delete():flat('id')
-- DELETE FROM blog T WHERE T."id" > 100 RETURNING T."id"
-- deleted_ids = {101, 102, ...}

-- 形式4: 跨表列 flat
local blog_names = Entry:flat('blog_id__name')
-- blog_names = {'First Blog', 'Second Blog', 'First Blog'}  (自动 JOIN)
```

---

## Sql:as_set() — 转为集合

```lua
---@return Set
```

返回值的扁平结果转为 Set（用于高效的成员检查）:

```lua
local id_set = Blog:select('id'):as_set()
-- id_set = Set{1, 2}

-- 检查成员
if id_set[1] then
  print("Blog 1 exists")
end
```

---

## Sql:statement() — 生成 SQL 字符串

```lua
---@return string     -- 完整 SQL 字符串
```

不执行查询，仅返回生成的 SQL:

```lua
local sql = Blog:where{id=1}:order('-name'):limit(10):statement()
print(sql)
-- SELECT * FROM blog T WHERE T."id" = 1 ORDER BY T."name" DESC LIMIT 10

-- 用于调试
print(Entry:where{blog_id__name='First Blog'}:statement())
-- SELECT * FROM entry T INNER JOIN blog T1 ON (T."blog_id" = T1."id") WHERE T1."name" = 'First Blog'

-- 用于子查询
local sub = Blog:select('id'):where{name__contains='Blog'}
Entry:where_in('blog_id', sub):exec()
```

---

## 链式调用完整示例

```lua
-- 复杂查询: 每个博客的高评分文章数（评分>3），按数量降序，取前10
Blog:annotate{ high_entries = Count('entry') }
  :where{ entry__rating__gt = 3 }
  :group_by('name')
  :having{ high_entries__gt = 0 }
  :order('-high_entries')
  :limit(10)
  :exec()

-- 分页查询
local page = 2
local page_size = 20
Entry:where{blog_id=1}
  :order('-pub_date')
  :limit(page_size)
  :offset((page - 1) * page_size)
  :exec()

-- 条件组合
Entry:select('headline', 'rating', 'blog_id__name')
  :where(Q{rating__gte=4} / Q{number_of_comments__gt=10})
  :where{pub_date__year=2023}
  :order('-rating', '-pub_date')
  :limit(50)
  :exec()

-- 子查询 + CTE
local active_blogs = Blog:where{entry__rating__gt=3}:select('id')
Entry:where_in('blog_id', active_blogs)
  :select('headline', 'rating')
  :order('-rating')
  :exec()

-- 事务中的复合操作
Blog:transaction(function()
  local blog = Blog:create { name = 'Transaction Blog' }
  Entry:insert{
    { blog_id = blog.id, headline = 'Entry 1', rating = 4 },
    { blog_id = blog.id, headline = 'Entry 2', rating = 5 },
  }:exec()
  local count = Entry:count{ blog_id = blog.id }
  assert(count == 2)
  return blog
end)
```

---

## 错误处理

```lua
-- 数据库错误
local ok, err = pcall(function()
  Blog:insert{name='duplicate'}:exec()  -- 如果 name unique 且已存在
end)

-- 校验错误
local ok, err = pcall(function()
  Blog:create { name = '' }  -- minlength 校验失败
end)
if not ok and type(err) == 'table' and err.type == 'field_error' then
  print(err.name, err.message)
end

-- get 不会抛错，只返回 false
local blog = Blog:get{id=999}
assert(blog == false)
```
