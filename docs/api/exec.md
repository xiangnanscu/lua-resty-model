# exec

执行构建好的 SQL 语句，返回结果集。默认将每行转为 Model 实例 (XodelInstance)。

## 函数签名

```lua
---@return Array<XodelInstance>
---@return number num_queries
function Sql:exec()
```

## 基本用法

```lua
local blogs = Blog:where{id__lt = 5}:exec()
-- blogs: Array<XodelInstance>
-- 每个元素是 Blog 的实例，支持 :save(), :delete() 等方法

for _, blog in ipairs(blogs) do
  print(blog.name)
end
```

---

# execr

以 "raw" 模式执行，不将结果转为 Model 实例，直接返回原始 table。内部等价于 `self:raw():exec()`。

## 函数签名

```lua
---@return table|Array<Record>
---@return number num_queries
function Sql:execr()
```

## 用法

```lua
local rows = Blog:select('name'):where{id = 1}:execr()
-- rows: {{name = 'First Blog'}} (普通 table，非 XodelInstance)
```

---

# raw

设置是否以原始模式返回查询结果（不执行 `Model:load` 转换）。

## 函数签名

```lua
---@param is_raw? boolean  默认 true
---@return self
function Sql:raw(is_raw)
```

## 用法

```lua
-- 开启 raw 模式
local rows = Blog:raw():where{id = 1}:exec()

-- 关闭 raw 模式 (执行 Model 实例化)
local instances = Blog:raw(false):where{id = 1}:exec()
```

---

# compact

以紧凑模式执行查询，结果为二维数组 `{{v1, v2}, {v3, v4}}` 而非 `{{col1=v1, col2=v2}, ...}`。

## 函数签名

```lua
---@return self
function Sql:compact()
```

## 用法

```lua
local rows = Blog:select('id', 'name'):compact():execr()
-- rows: {{1, 'First Blog'}, {2, 'Second Blog'}}
```

---

# flat

将查询结果展平为一维数组。通常与 `compact()` 配合使用。

## 函数签名

```lua
---@param col? string|fun(ctx:table):string
---@return Array<Record>
function Sql:flat(col)
```

## 用法

```lua
-- 获取所有 blog 的 name 列表
local names = Blog:flat('name')
-- names: {'First Blog', 'Second Blog', ...}

-- SELECT 查询展平
local ids = Entry:flat('id')
-- ids: {1, 2, 3, ...}

-- 对 CUD 操作，自动使用 returning
local deleted_ids = Blog:where{id__gt = 10}:delete():flat('id')
-- deleted_ids: {11, 12, ...}
```

---

# as_set

将查询结果转为 Set 集合（查单列的去重集合）。

## 函数签名

```lua
---@return Set
function Sql:as_set()
```

## 用法

```lua
local name_set = Blog:select('name'):as_set()
-- Set: {'First Blog', 'Second Blog', ...}
-- 支持 name_set:has('First Blog')
```

---

# count

统计符合条件的记录数。直接返回数字。

## 函数签名

```lua
---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return integer
function Sql:count(cond, op, dval)
```

## 用法

```lua
-- 全表计数
local n = Blog:count()

-- 带条件计数
local n = Entry:count{rating__gt = 3}

-- 两/三参数形式
local n = Entry:count("rating", ">", 3)
```

---

# exists

检查是否存在符合条件的记录。返回 boolean。

## 函数签名

```lua
---@return boolean
function Sql:exists()
```

## 用法

```lua
local has = Blog:where{name = 'First Blog'}:exists()
-- true 或 false
```

---

# get

获取符合条件的**唯一一条**记录。若结果不唯一则返回 `false`。

## 函数签名

```lua
---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return XodelInstance|false
function Sql:get(cond, op, dval)
```

## 用法

```lua
local blog = Blog:get{name = 'First Blog'}
-- 有且仅有一条 → XodelInstance
-- 0 条或多条 → false

-- 先链式条件再 get
local entry = Entry:where{blog_id = 1}:get{rating = 5}
```

---

# try_get

`get` 的别名，行为完全相同。

---

# filter

`where` + `exec` 的快捷方式。

## 函数签名

```lua
---@param kwargs table
---@return Array<XodelInstance>
---@return number num_queries
function Sql:filter(kwargs)
```

## 用法

```lua
local entries = Entry:filter{rating__gte = 4}
-- 等同于 Entry:where{rating__gte = 4}:exec()
```

---

# return_all

当使用 `prepend` 或 `append` 执行多条语句时，默认只返回主语句结果。调用 `return_all()` 后返回所有语句的结果。

## 函数签名

```lua
---@return self
function Sql:return_all()
```

## 用法

```lua
local all_results = Blog:prepend(some_sql):return_all():exec()
-- all_results 包含所有语句的结果集
```
