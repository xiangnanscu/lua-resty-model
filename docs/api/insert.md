# insert

向表中插入一行或多行数据。自动执行模型校验和 `_prepare_for_db` 处理。

## 函数签名

```lua
---@param rows Record|Record[]|Sql
---@param columns? string[]
---@return self
function Sql:insert(rows, columns)
```

## 基本用法

```lua
-- 插入单行
Blog:insert{name = 'My Blog', tagline = 'A great blog'}:returning('*'):exec()
-- INSERT INTO blog (name, tagline) VALUES ('My Blog', 'A great blog') RETURNING *

-- 插入多行
Blog:insert{
  {name = 'Blog A', tagline = 'desc A'},
  {name = 'Blog B', tagline = 'desc B'}
}:returning('id'):exec()
-- INSERT INTO blog (name, tagline) VALUES ('Blog A', 'desc A'), ('Blog B', 'desc B') RETURNING T.id
```

## 从子查询插入

```lua
-- 从 SELECT 子查询插入
Blog:insert(
  Blog:select('name', 'tagline'):where{id__lt = 5}
):returning('*'):exec()
-- INSERT INTO blog (SELECT T."name", T.tagline FROM blog T WHERE T.id < 5) RETURNING *
```

## 指定列

```lua
-- 仅插入指定列 (其余列使用数据库默认值)
Blog:insert({name = 'Blog C', tagline = 'desc'}, {'name'}):returning('*'):exec()
-- INSERT INTO blog (name) VALUES ('Blog C') RETURNING *
```

## 跳过校验

```lua
Blog:skip_validate():insert{name = 'Raw Blog'}:returning('*'):exec()
```
