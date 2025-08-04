# Lua Resty Model 使用手册

## 公共 API 使用手册

### 1. 查询操作 (Query Operations)

#### select(...) - 选择字段

指定要查询的字段。

```lua
-- 基本用法
local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { name = 'name', maxlength = 20 },
    { name = 'tagline', type = 'text' },
  }
}

-- 选择单个字段
local result = Blog:select('name'):exec()
-- SQL: SELECT T.name FROM blog T

-- 选择多个字段
local result = Blog:select('name', 'tagline'):exec()
-- SQL: SELECT T.name, T.tagline FROM blog T

-- 使用数组形式
local result = Blog:select({'name', 'tagline'}):exec()
-- SQL: SELECT T.name, T.tagline FROM blog T

-- 选择外键字段
local result = Entry:select('blog_id__name'):exec()
-- SQL: SELECT T1.name FROM entry T INNER JOIN blog T1 ON (T.blog_id = T1.id)
```

#### where(condition, operator?, value?) - 添加查询条件

添加 WHERE 条件。

```lua
-- 基本等值查询
local result = Blog:where({name = 'First Blog'}):exec()
-- SQL: SELECT * FROM blog T WHERE T.name = 'First Blog'

-- 使用操作符
local result = Blog:where({id__gt = 1}):exec()
-- SQL: SELECT * FROM blog T WHERE T.id > 1

-- 多个条件
local result = Blog:where({name = 'Blog', tagline__contains = 'test'}):exec()

-- 使用Q对象进行复杂查询
local Q = Model.Q
local result = Blog:where(Q{id = 1} / Q{name = 'test'}):exec()
-- SQL: SELECT * FROM blog T WHERE (T.id = 1) OR (T.name = 'test')

-- 外键条件
local result = Entry:where({blog_id__name = 'First Blog'}):exec()
-- SQL: SELECT * FROM entry T INNER JOIN blog T1 ON (T.blog_id = T1.id) WHERE T1.name = 'First Blog'
```

#### order(field, ...) - 排序

指定排序字段和方向。

```lua
-- 升序排序
local result = Blog:order('name'):exec()
-- SQL: SELECT * FROM blog T ORDER BY T.name ASC

-- 降序排序 (使用 - 前缀)
local result = Blog:order('-name'):exec()
-- SQL: SELECT * FROM blog T ORDER BY T.name DESC

-- 多字段排序
local result = Blog:order('name', '-id'):exec()
-- SQL: SELECT * FROM blog T ORDER BY T.name ASC, T.id DESC
```

#### limit(n) - 限制记录数

限制返回的记录数量。

```lua
-- 限制返回5条记录
local result = Blog:limit(5):exec()
-- SQL: SELECT * FROM blog T LIMIT 5

-- 配合排序使用
local result = Blog:order('-id'):limit(10):exec()
```

#### offset(n) - 跳过记录数

跳过指定数量的记录。

```lua
-- 跳过前10条记录
local result = Blog:offset(10):exec()
-- SQL: SELECT * FROM blog T OFFSET 10

-- 分页查询
local page = 2
local pageSize = 10
local result = Blog:limit(pageSize):offset((page-1) * pageSize):exec()
```

#### distinct(...) - 去重

对查询结果去重。

```lua
-- 所有字段去重
local result = Blog:distinct():exec()
-- SQL: SELECT DISTINCT * FROM blog T

-- 指定字段去重
local result = Blog:select('name'):distinct('name'):exec()
-- SQL: SELECT DISTINCT ON(T.name) T.name FROM blog T
```

#### group(field, ...) - 分组

按字段分组查询。

```lua
-- 按名称分组
local result = Blog:group('name'):exec()
-- SQL: SELECT T.name FROM blog T GROUP BY T.name

-- 分组统计
local Count = Model.Count
local result = Blog:group('name'):annotate({cnt = Count('id')}):exec()
```

#### having(condition) - 分组过滤

对分组结果进行过滤。

```lua
local Sum = Model.Sum
local result = Book:group('author')
  :annotate({total_price = Sum('price')})
  :having({total_price__gt = 100})
  :exec()
-- SQL: SELECT T.author, SUM(T.price) AS total_price FROM book T
--      GROUP BY T.author HAVING SUM(T.price) > 100
```

### 2. 数据操作 (Data Operations)

#### insert(data, columns?) - 插入数据

插入新记录。

```lua
-- 插入单条记录
local result = Blog:insert({
  name = 'New Blog',
  tagline = 'A new blog post'
}):exec()

-- 批量插入
local result = Blog:insert({
  {name = 'Blog 1', tagline = 'First blog'},
  {name = 'Blog 2', tagline = 'Second blog'}
}):exec()

-- 指定字段插入
local result = Blog:insert({
  name = 'Blog with columns',
  tagline = 'Will not insert',
  extra = 'ignored'
}, {'name', 'tagline'}):exec()

-- 插入并返回字段
local result = Blog:insert({name = 'Return Blog'})
  :returning('id', 'name')
  :exec()
```

#### update(data, columns?) - 更新数据

更新现有记录。

```lua
-- 基本更新
local result = Blog:where({id = 1})
  :update({tagline = 'Updated tagline'})
  :exec()

-- 使用函数表达式
local F = Model.F
local result = Entry:where({id = 1})
  :update({headline = F('headline') .. ' [Updated]'})
  :exec()

-- 更新并返回
local result = Blog:where({name = 'Test'})
  :update({tagline = 'New tagline'})
  :returning('*')
  :exec()
```

#### delete(condition?, operator?, value?) - 删除数据

删除记录。

```lua
-- 删除所有记录（危险操作）
local result = Blog:delete():exec()

-- 条件删除
local result = Blog:delete({name = 'Test Blog'}):exec()

-- 删除并返回
local result = Blog:delete({id__lt = 10})
  :returning('id', 'name')
  :exec()
```

#### upsert(data, key?, columns?) - 插入或更新

如果记录存在则更新，否则插入。

```lua
-- 基本 upsert（使用主键）
local result = Blog:upsert({
  {name = 'Blog 1', tagline = 'Updated or inserted'},
  {name = 'Blog 2', tagline = 'Another upsert'}
}):exec()

-- 指定唯一键
local result = Blog:upsert({
  {name = 'Unique Blog', tagline = 'Content'}
}, 'name'):exec()

-- upsert 并返回数据
local result = Blog:upsert({
  {name = 'Return Blog', tagline = 'With return'}
}):returning('*'):exec()
```

#### merge(data, key?, columns?) - 合并数据

智能合并数据，存在则更新，不存在则插入。

```lua
-- 基本合并
local result = Blog:merge({
  {name = 'Merge Blog 1', tagline = 'Merged content 1'},
  {name = 'Merge Blog 2', tagline = 'Merged content 2'}
}):exec()

-- 指定键字段
local result = Blog:merge({
  {name = 'Custom Key', tagline = 'Custom merge'}
}, 'name'):exec()
```

#### updates(data, key?, columns?) - 批量更新

批量更新多条记录。

```lua
-- 批量更新
local result = Blog:updates({
  {id = 1, tagline = 'Updated 1'},
  {id = 2, tagline = 'Updated 2'}
}):exec()

-- 使用自定义键
local result = Blog:updates({
  {name = 'Blog A', tagline = 'Updated A'},
  {name = 'Blog B', tagline = 'Updated B'}
}, 'name'):exec()
```

### 3. 聚合操作 (Aggregation Operations)

#### annotate(functions) - 添加聚合函数

添加聚合计算字段。

```lua
local Count = Model.Count
local Sum = Model.Sum
local Avg = Model.Avg
local Max = Model.Max
local Min = Model.Min

-- 计数
local result = Blog:annotate({post_count = Count('id')}):exec()

-- 求和
local result = Book:annotate({total_price = Sum('price')}):exec()

-- 平均值
local result = Book:annotate({avg_price = Avg('price')}):exec()

-- 最大值和最小值
local result = Book:annotate({
  max_price = Max('price'),
  min_price = Min('price')
}):exec()

-- 表达式计算
local F = Model.F
local result = Book:annotate({
  price_per_page = F('price') / F('pages')
}):exec()
```

#### count(condition?, operator?, value?) - 计数

统计记录数量。

```lua
-- 统计总数
local total = Blog:count()  -- 返回数字

-- 条件计数
local count = Blog:count({name__contains = 'test'})

-- 配合where使用
local count = Blog:where({tagline__isnull = false}):count()
```

#### exists() - 检查存在性

检查是否存在匹配的记录。

```lua
-- 检查记录是否存在
local exists = Blog:where({name = 'Test Blog'}):exists()  -- 返回 boolean

-- 检查任意记录
local hasData = Blog:exists()
```

### 4. 关系操作 (Relationship Operations)

#### join(table, condition, operator?, value?) - 连接查询

手动添加表连接。

```lua
-- 内连接
local result = Blog:join('entry', 'T.id = T1.blog_id'):exec()

-- 指定连接类型
local result = Blog:left_join('entry', 'T.id = T1.blog_id'):exec()
local result = Blog:right_join('entry', 'T.id = T1.blog_id'):exec()
local result = Blog:full_join('entry', 'T.id = T1.blog_id'):exec()

-- 使用模型连接
local result = Blog:join(Entry, function(ctx)
  return ctx.Blog.id .. ' = ' .. ctx.Entry.blog_id
end):exec()
```

#### select_related(foreign_key, fields?) - 预加载外键

预加载外键关联数据。

```lua
-- 预加载所有外键字段
local result = Entry:select_related('blog_id', '*'):exec()

-- 预加载指定字段
local result = Entry:select_related('blog_id', 'name'):exec()
local result = Entry:select_related('blog_id', {'name', 'tagline'}):exec()

-- 多个字段
local result = Entry:select_related('blog_id', 'name', 'tagline'):exec()
```

### 5. 高级操作 (Advanced Operations)

#### where_in(columns, values) - IN 查询

使用 IN 操作符查询。

```lua
-- 单字段 IN
local result = Blog:where_in('id', {1, 2, 3}):exec()
-- SQL: SELECT * FROM blog T WHERE T.id IN (1, 2, 3)

-- 多字段 IN (需要数组格式)
local result = Blog:where_in({'name', 'tagline'}, {
  {'Blog1', 'Tag1'},
  {'Blog2', 'Tag2'}
}):exec()

-- 子查询 IN
local subquery = Entry:where({rating__gt = 4}):select('blog_id')
local result = Blog:where_in('id', subquery):exec()
```

#### where_not_in(columns, values) - NOT IN 查询

使用 NOT IN 操作符查询。

```lua
-- NOT IN 查询
local result = Blog:where_not_in('id', {1, 2}):exec()
-- SQL: SELECT * FROM blog T WHERE T.id NOT IN (1, 2)

-- 排除子查询结果
local subquery = Entry:select('blog_id')
local result = Blog:where_not_in('id', subquery):exec()
```

#### union(other_sql) - 联合查询

合并两个查询结果。

```lua
-- UNION
local query1 = Blog:where({name = 'Blog1'})
local query2 = Blog:where({name = 'Blog2'})
local result = query1:union(query2):exec()

-- UNION ALL (包含重复)
local result = query1:union_all(query2):exec()

-- EXCEPT (差集)
local result = query1:except(query2):exec()

-- INTERSECT (交集)
local result = query1:intersect(query2):exec()
```

#### with(name, subquery) - CTE (公共表表达式)

使用 WITH 子句。

```lua
-- 基本 CTE
local subquery = Entry:where({rating__gt = 4}):select('blog_id')
local result = Blog:with('high_rated_blogs', subquery)
  :where_in('id', Model:new{table_name = 'high_rated_blogs'}:select('blog_id'))
  :exec()

-- 递归 CTE
local result = Blog:with_recursive('blog_tree', recursive_query):exec()
```

### 6. 实用方法 (Utility Methods)

#### get(condition?, operator?, value?) - 获取单条记录

获取单条记录，如果不存在或有多条则抛出异常。

```lua
-- 获取单条记录
local blog = Blog:get({name = 'First Blog'})

-- 按ID获取
local blog = Blog:get({id = 1})

-- 配合where使用
local blog = Blog:where({tagline__contains = 'test'}):get()
```

#### try_get(condition?, operator?, value?) - 尝试获取单条记录

尝试获取单条记录，如果不存在返回 false。

```lua
-- 尝试获取记录
local blog = Blog:try_get({name = 'Maybe Blog'})
if blog then
  print('Found:', blog.name)
else
  print('Not found')
end
```

#### flat(column?) - 扁平化结果

将查询结果扁平化为一维数组。

```lua
-- 获取所有名称
local names = Blog:flat('name')  -- {'Blog1', 'Blog2', 'Blog3'}

-- 获取所有ID
local ids = Blog:flat('id')  -- {1, 2, 3}

-- 扁平化所有结果
local all_values = Blog:select('name'):flat()
```

#### raw(is_raw?) - 原始结果

返回原始数据而不是模型实例。

```lua
-- 返回原始数据
local raw_data = Blog:raw():exec()  -- 返回普通table数组

-- 返回模型实例（默认）
local instances = Blog:raw(false):exec()  -- 返回模型实例数组
```

#### compact() - 紧凑模式

使用紧凑模式查询（返回数组而非哈希）。

```lua
-- 紧凑模式查询
local compact_result = Blog:compact():exec()
-- 返回: {{1, 'Blog1', 'Tag1'}, {2, 'Blog2', 'Tag2'}}

-- 普通模式查询
local normal_result = Blog:exec()
-- 返回: {{id=1, name='Blog1', tagline='Tag1'}, ...}
```

### 7. 查询构建辅助 (Query Building Helpers)

#### statement() - 获取 SQL 语句

获取构建的 SQL 语句字符串。

```lua
-- 获取SQL语句
local sql = Blog:where({name = 'Test'}):statement()
print(sql)  -- SELECT * FROM blog T WHERE T.name = 'Test'
```

#### copy() - 复制查询对象

复制当前查询对象。

```lua
-- 复制查询
local base_query = Blog:where({tagline__isnull = false})
local query1 = base_query:copy():where({name = 'Blog1'})
local query2 = base_query:copy():where({name = 'Blog2'})
```

#### clear() - 清除查询条件

清除当前查询的所有条件。

```lua
-- 清除条件
local query = Blog:where({name = 'Test'}):select('name')
query:clear()  -- 回到初始状态
local result = query:exec()  -- SELECT * FROM blog T
```

### 8. 执行方法 (Execution Methods)

#### exec() - 执行查询

执行查询并返回结果。

```lua
-- 基本执行
local result = Blog:where({id = 1}):exec()

-- 返回结果和查询数量
local result, num_queries = Blog:exec()
```

#### execr() - 执行并返回原始数据

执行查询并返回原始数据。

```lua
-- 等价于 :raw():exec()
local raw_result = Blog:execr()
```

### 9. 模型操作 (Model Operations)

#### create(data) - 创建记录

创建新记录的便捷方法。

```lua
-- 创建记录
local blog = Blog:create({
  name = 'New Blog',
  tagline = 'Created with create method'
})
```

#### save(data, fields?, key?) - 保存记录

根据主键存在性决定插入或更新。

```lua
-- 新记录（没有ID）- 插入
local blog = Blog:save({
  name = 'New Blog',
  tagline = 'Will be inserted'
})

-- 现有记录（有ID）- 更新
local blog = Blog:save({
  id = 1,
  name = 'Updated Blog',
  tagline = 'Will be updated'
})
```

### 10. 验证方法 (Validation Methods)

#### validate(data, fields?, key?) - 验证数据

验证输入数据。

```lua
-- 验证数据
local cleaned_data = Blog:validate({
  name = 'Test Blog',
  tagline = 'Test tagline'
})

-- 验证失败会抛出异常
local ok, err = pcall(function()
  return Blog:validate({
    name = 'Too long name that exceeds limit',  -- 会验证失败
    tagline = 'Valid tagline'
  })
end)
```

---

## 最佳实践

### 1. 安全使用建议

```lua
-- ✅ 安全：使用参数化条件
local result = Blog:where({name = user_input}):exec()

-- ❌ 危险：直接使用字符串条件
local result = Blog:where("name = '" .. user_input .. "'"):exec()

-- ✅ 安全：使用 LIKE 操作符
local result = Blog:where({name__contains = user_input}):exec()

-- ❌ 需要注意：用户输入包含 % 或 _ 时的行为
```

### 2. 性能优化建议

```lua
-- ✅ 使用索引字段进行查询
local result = Blog:where({id = 1}):exec()

-- ✅ 限制返回字段
local result = Blog:select('name', 'tagline'):exec()

-- ✅ 使用分页
local result = Blog:limit(20):offset(page * 20):exec()

-- ✅ 预加载关联数据
local result = Entry:select_related('blog_id', 'name'):exec()
```

### 3. 错误处理

```lua
-- 安全的记录获取
local blog = Blog:try_get({name = input_name})
if not blog then
  return {error = 'Blog not found'}
end

-- 批量操作错误处理
local ok, err = pcall(function()
  return Blog:insert(bulk_data):exec()
end)
if not ok then
  -- 处理验证错误
  if type(err) == 'table' and err.type == 'field_error' then
    return {error = err.message, field = err.name}
  end
  error(err)  -- 重新抛出其他错误
end
```

这个手册涵盖了所有主要的公共 API 使用方法，包括安全分析和最佳实践建议。
