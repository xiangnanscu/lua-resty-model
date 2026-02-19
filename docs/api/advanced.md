# gets

通过传入多组查找条件（复合键），批量获取匹配记录。内部用 CTE + RIGHT JOIN 实现。

## 函数签名

```lua
---@param keys Record[]
---@param columns? string[]
---@return self
function Sql:gets(keys, columns)
```

## 用法

```lua
-- 按多组键查找
Entry:gets{
  {id = 1},
  {id = 3},
  {id = 5}
}:exec()
```

生成类似：

```sql
WITH V(id) AS (VALUES (1::integer), (3), (5))
SELECT * FROM entry T RIGHT JOIN V ON (V.id = T.id)
```

```lua
-- 复合键
Entry:gets({
  {blog_id = 1, rating = 5},
  {blog_id = 2, rating = 3}
}, {'blog_id', 'rating'}):exec()
```

---

# merge_gets

与 `gets` 类似，但额外选择 CTE 虚拟表的所有列 (`V.*`)，用于将传入数据与数据库记录合并。

## 函数签名

```lua
---@param rows Record[]
---@param key Keys
---@param columns? string[]
---@return self|XodelInstance[]
function Sql:merge_gets(rows, key, columns)
```

## 用法

```lua
Blog:select("name"):merge_gets(
  {{id = 1, name = 'aa'}, {id = 2, name = 'bb'}},
  'id'
):exec()
```

生成：

```sql
WITH V(id, name) AS (VALUES (1::integer, 'aa'::varchar), (2, 'bb'))
SELECT T."name", V.* FROM blog T RIGHT JOIN V ON (V.id = T.id)
```

---

# get_or_create

获取或创建：尝试按条件查找记录，如不存在则插入。使用 CTE 保证原子性。

## 函数签名

```lua
---@param params table       必须匹配的查找条件
---@param defaults? table    创建时的额外默认值
---@param columns? string[]  返回的列
---@return XodelInstance, boolean  返回记录和是否新创建
function Sql:get_or_create(params, defaults, columns)
```

## 用法

```lua
local blog, created = Blog:get_or_create(
  {name = 'My Blog'},              -- 查找条件
  {tagline = 'Default tagline'}    -- 不存在时的默认值
)
-- created == true  → 新创建
-- created == false → 已存在

if created then
  print("Created new blog: " .. blog.name)
else
  print("Found existing blog: " .. blog.name)
end
```

---

# where_recursive

递归查询：用于树状数据（自引用外键）。自动构建 `WITH RECURSIVE` CTE。

## 函数签名

```lua
---@param name string        自引用外键字段名
---@param value any           根节点的外键值
---@param select_names? string[]  额外选择的列
---@return self
function Sql:where_recursive(name, value, select_names)
```

## 用法

假设 `Branch` 模型有 `pid` 自引用外键:

```lua
-- 查询 pid = 1 的所有子节点 (递归)
Branch:where_recursive('pid', 1):exec()
```

生成：

```sql
WITH RECURSIVE branch_recursive AS (
  SELECT T.id, T.pid FROM branch T WHERE T.pid = 1
  UNION ALL
  (SELECT T.id, T.pid FROM branch T
    INNER JOIN branch_recursive ON (T.pid = branch_recursive.id))
)
SELECT * FROM branch_recursive AS branch
```

```lua
-- 选择额外列
Branch:where_recursive('pid', 1, {'name', 'level'}):exec()
```

---

# select_related

显式预加载外键关联对象的字段，避免 N+1 查询。通过 JOIN 在单次查询中获取关联表数据。

## 函数签名

```lua
---@param fk_name string|ForeignkeyField  外键字段名
---@param select_names string[]|string     关联表要选择的列 ('*' 表示全部)
---@param more_name? string
---@param ... string
---@return self
function Sql:select_related(fk_name, select_names, more_name, ...)
```

## 用法

```lua
-- 预加载 blog_id 关联的 blog.name
Entry:select_related('blog_id', 'name'):exec()
-- 结果中 entry.blog_id 变为 Blog 实例，包含 name 属性

-- 加载关联表的所有字段
Entry:select_related('blog_id', '*'):exec()

-- 加载多个字段
Entry:select_related('blog_id', {'name', 'tagline'}):exec()

-- 或用可变参数形式
Entry:select_related('blog_id', 'name', 'tagline'):exec()
```

---

# select_related_labels

自动为所有外键字段加载其引用标签列 (reference_label_column)。使用 LEFT JOIN。

## 函数签名

```lua
---@param names? string[]
---@return self
function Sql:select_related_labels(names)
```

## 用法

```lua
Entry:select_related_labels():exec()
-- 自动为所有外键字段 (如 blog_id) 添加 LEFT JOIN 并选择其 label 列
```
