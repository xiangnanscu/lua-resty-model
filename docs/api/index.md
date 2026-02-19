# API 文档索引

lua-resty-model ORM 完整 API 参考。

> 所有 Sql 方法均可通过 Model 代理直接调用（Model 内部自动创建 Sql 实例并转发）。

---

## Model 层

| 文件                 | 内容                                                                                                                                                          |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [model.md](model.md) | 模型定义、CRUD 快捷操作 (`create`, `save`, `save_create`, `save_update`)、数据校验 (`validate`, `validate_create`, `validate_update`)、事务、实例方法、类属性 |

---

## 查询构建

| 文件                       | 内容                                                                                     |
| -------------------------- | ---------------------------------------------------------------------------------------- |
| [select.md](select.md)     | `select`, `select_as`, `select_literal`, `select_literal_as`                             |
| [where.md](where.md)       | `where` (6 种调用形式、26 个操作符后缀、F 表达式、跨表查询、JSON 查询、Q 对象、变体方法) |
| [where_in.md](where_in.md) | `where_in`, `where_not_in`, `where_or`, `or_where`, `or_where_or`                        |
| [order.md](order.md)       | `order` / `order_by`, `nulls_first`, `nulls_last`                                        |
| [group.md](group.md)       | `group` / `group_by`, `having`, `annotate` (聚合函数 Count/Sum/Avg/Max/Min)              |
| [limit.md](limit.md)       | `limit`, `offset`                                                                        |
| [distinct.md](distinct.md) | `distinct`, `distinct_on`                                                                |

---

## 写操作

| 文件                         | 内容                                  |
| ---------------------------- | ------------------------------------- |
| [insert.md](insert.md)       | `insert` (单行 / 多行 / 子查询)       |
| [update.md](update.md)       | `update`, `increase`, `decrease`      |
| [delete.md](delete.md)       | `delete`                              |
| [upsert.md](upsert.md)       | `upsert`, `merge`, `updates`, `align` |
| [returning.md](returning.md) | `returning`, `returning_literal`      |

---

## 执行与结果

| 文件               | 内容                                                                                                              |
| ------------------ | ----------------------------------------------------------------------------------------------------------------- |
| [exec.md](exec.md) | `exec`, `execr`, `raw`, `compact`, `flat`, `as_set`, `count`, `exists`, `get` / `try_get`, `filter`, `return_all` |

---

## CTE 与集合操作

| 文件             | 内容                                                                                                                   |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------- |
| [cte.md](cte.md) | `with`, `with_recursive`, `with_values`, `union` / `union_all`, `except` / `except_all`, `intersect` / `intersect_all` |

---

## 高级功能

| 文件                       | 内容                                                                                                |
| -------------------------- | --------------------------------------------------------------------------------------------------- |
| [advanced.md](advanced.md) | `gets`, `merge_gets`, `get_or_create`, `where_recursive`, `select_related`, `select_related_labels` |

---

## 工具方法

| 文件                     | 内容                                                                                                                |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| [helpers.md](helpers.md) | `as`, `from`, `using`, `copy`, `clear`, `skip_validate`, `join_type`, `get_table`, `statement`, `prepend`, `append` |
