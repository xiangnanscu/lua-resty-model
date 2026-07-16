-- 列名解析器：Django 风格 `a__b__op` 多段遍历（FK 自动 JOIN / 反向 FK /
-- jsonb 路径 / annotate 别名 / 操作符检测）。全库的心脏，从 sql.lua 拆出。
-- 本模块不持有状态：所有 builder 状态（_as/_annotate/_join_keys/_join_type）
-- 经 `sql` 参数读取，JOIN 物化回调 sql:_handle_manual_join。
local Utils = require "model.utils"
local Expr = require "model.expr"

local error = error
local format = string.format
local smart_quote = Utils.smart_quote
local as_literal = Utils.as_literal
local as_literal_without_brackets = Utils.as_literal_without_brackets
local json_operators = Utils.json_operators
local NON_OPERATOR_CONTEXTS = Utils.NON_OPERATOR_CONTEXTS
local EXPR_OPERATORS = Expr.EXPR_OPERATORS
local JSON_OP_MAP = Expr.JSON_OP_MAP
local JSON_TEXT_OPS = Expr.JSON_TEXT_OPS

local M = {}

---@param sql Sql
---@param key string column name
---@param context? ColumnContext
---@return string resolved_column
---@return string operator
function M.parse_column(sql, key, context)
  local model = sql.model
  local fast_field = model.fields[key]
  if fast_field then
    local prefix = sql._as or model._table_name_token
    return prefix .. '.' .. (fast_field._column_token or smart_quote(key)), 'eq'
  end
  local i = 1
  local op = 'eq'
  local a, b, token, join_key, prefix, column, final_column, last_field, last_token, last_model, json_keys
  while true do
    a, b = key:find("__", i, true)
    if not a then
      token = key:sub(i)
    else
      token = key:sub(i, a - 1)
    end
    -- column might be changed in the loop
    local field = model.fields[token]
    if field then
      -- 1. fields from model itself, highest priority
      if not last_field then
        -- 1.1 first column, the most case
        column = token
        prefix = sql._as or model._table_name_token
      elseif json_keys then
        -- 1.2 json field search: token happens to be a model field name but we
        -- are already inside a jsonb path, so treat it as a json path segment.
        -- https://docs.djangoproject.com/en/4.2/topics/db/queries/#querying-jsonfield
        if json_operators[token] or EXPR_OPERATORS[token] then
          -- terminal op: stop traversing, post-loop will build the json path
          op = token
          break
        else
          json_keys[#json_keys + 1] = token
        end
      elseif last_model.reversed_fields[last_token] then
        -- 1.3 field on the reversed-model side: Blog:where{entry__rating}
        -- The reverse join was created by branch 4 in the previous iter; here
        -- we just point `column` at the current segment (prefix already alias).
        column = token
      elseif last_field.reference then
        -- 1.4 foreignkey model's field, may need a join
        if token == last_field.reference_column then
          -- 1.4.1 blog_id__id => redundant FK suffix, rollback to the FK column.
          -- Preserve `field = last_field` so the loop bottom's
          -- `last_field = field` keeps the FK context — otherwise a trailing
          -- segment like blog_id__id__notop would report errors against the
          -- PK field and lose the originating FK chain (BUG B4).
          column = last_token
          token = last_token -- in case of blog_id__id__gt
          field = last_field
        else
          -- 1.4.2 blog_id__name => need a join
          column = token
          local parent_join_key -- left side of the new join (nil = main table)
          if not join_key then
            -- prefix with foreignkey name because a model can be referenced multiple times by the same model
            -- such as: Entry:where{blog_id__name='Tom', reposted_blog_id__name='Kate'}
            join_key = last_token
          else
            parent_join_key = join_key
            join_key = join_key .. "__" .. last_token
          end
          if not sql._join_keys then
            sql._join_keys = {}
          end
          prefix = sql._join_keys[join_key]
          if not prefix then
            local function join_cond_cb(ctx)
              local left_proxy = ctx[parent_join_key or 1]
              local left_column = left_proxy[last_token]
              if not left_column then
                error(last_token .. " is a invalid column for " .. left_proxy[1])
              end
              local right_column = ctx[join_key][last_field.reference_column]
              return format("%s = %s", left_column, right_column)
            end
            local join_type
            if context == 'aggregate' then
              join_type = "LEFT"
            else
              join_type = sql._join_type or "INNER"
            end
            prefix = sql:_handle_manual_join(join_type, model, join_cond_cb, join_key)
          end
        end
      else
        -- 1.5: token IS a valid field on `model`, but the previous segment
        -- (`last_token`) is not a foreignkey / jsonb / reverse-fk, so the
        -- traversal is malformed.
        error(format(
          "cannot traverse to '%s' through '%s' on model '%s' (previous segment is not a foreignkey, jsonb, or reverse-fk)",
          token, last_token, last_model.class_name))
      end
      last_model = model
      if field.reference then
        model = field.reference
      end
      if not json_keys and (field.model or field.db_type == 'jsonb') then
        json_keys = {}
      end
    elseif sql._annotate and sql._annotate[token] then
      -- 2. name that's registered in annotate:
      -- Blog:annotate{cnt=Count('entry')}:where{cnt__lt=2}:group_by{'name'}
      -- The annotation expands to a full SQL expression (Count(...), F('price')
      -- * 10), not a column — so the only valid continuation is a single
      -- trailing operator (cnt__gte=1). Traversal *into* the annotation makes
      -- no sense and used to be silently dropped (BUG B2), reject it here.
      final_column = sql._annotate[token]
      if a then
        local rest = key:sub(b + 1)
        if EXPR_OPERATORS[rest] then
          op = rest
        else
          error(format(
            "cannot traverse into annotation '%s' on model '%s': "
            .. "only a single trailing operator is allowed, got '%s' (full key: '%s')",
            token, model.class_name, rest, key))
        end
      end
      break
    elseif json_keys then
      -- 3. attributes from a json field
      -- Blog.where{data__a='x'}         => WHERE (... "data" -> 'a')        = '"x"'
      -- Blog.where{data__a__contains=...} => WHERE (... "data" -> 'a')      @> '...'
      -- Blog.where{data__a__gt=5}       => WHERE (... "data" -> 'a')        > '5'
      -- Blog.where{data__a__startswith='x'} => WHERE (... "data" ->> 'a') LIKE 'x%'
      if json_operators[token] or EXPR_OPERATORS[token] then
        -- terminal op: stop traversing, post-loop builds the json LHS
        op = token
        break
      else
        json_keys[#json_keys + 1] = token
      end
    else
      -- Blog:where{entry__rating=1}
      local reversed_field = model.reversed_fields[token] -- Entry.blog_id, Blog:where{entry=1}
      if reversed_field then
        -- 4. reversed foreignkey, join from current loop
        -- token = entry, reversed_name = blog_id
        -- Fix: if the previous segment was a forward FK whose target wasn't
        -- materialized yet (1.3 path skipped the join because at that point we
        -- only needed the FK column itself), we MUST add the forward join now,
        -- otherwise the reverse join below would anchor on the wrong table.
        -- Example: Blog:where{entry__blog_id__entry__rating=5} requires a
        -- Blog T2 join between entry T1 and the second entry T3 (Django parity:
        -- 3 joins total).
        if last_field and last_field.reference == model then
          local fk_join_key = (join_key and (join_key .. "__" .. last_token)) or last_token
          if not sql._join_keys or not sql._join_keys[fk_join_key] then
            local left_anchor = join_key
            local function fk_join_cb(ctx)
              return format("%s = %s",
                ctx[left_anchor or 1][last_token],
                ctx[fk_join_key][last_field.reference_column])
            end
            local fix_join_type
            if context == 'aggregate' then
              fix_join_type = "LEFT"
            else
              fix_join_type = sql._join_type or "INNER"
            end
            sql:_handle_manual_join(fix_join_type, model, fk_join_cb, fk_join_key)
          end
          join_key = fk_join_key
        end
        local reversed_model = reversed_field:get_model() -- Entry
        if not join_key then
          join_key = token
        else
          join_key = join_key .. "__" .. token
        end
        if not sql._join_keys then
          sql._join_keys = {}
        end
        prefix = sql._join_keys[join_key]
        if not prefix then
          local function join_cond_cb(ctx)
            local left_model_index
            if token == join_key then
              left_model_index = 1
            else
              left_model_index = #ctx - 1
            end
            return format("%s = %s",
              ctx[left_model_index][reversed_field.reference_column],
              ctx[#ctx][reversed_field.name])
          end
          local join_type
          if context == 'aggregate' then
            join_type = "LEFT"
          else
            join_type = sql._join_type or "INNER"
          end
          prefix = sql:_handle_manual_join(join_type, reversed_model, join_cond_cb, join_key)
        end
        column = reversed_model.primary_key
        field = reversed_field
        last_model = model
        model = reversed_model
      elseif last_token then
        -- 5. operator, write back
        if context == nil or not NON_OPERATOR_CONTEXTS[context] then -- where or having or Q
          -- 5.1 should be operator, check it
          if not EXPR_OPERATORS[token] then
            error(format(
              "invalid operator '%s' after column '%s' on model '%s' (full key: '%s')",
              token, last_token, model.class_name, key))
          end
        else
          -- 5.2 select/returning etc context, shouldn't reach here
          error(format(
            "invalid column segment '%s' after '%s' on model '%s' (full key: '%s') in %s context",
            token, last_token, model.class_name, key, context))
        end
        op = token
        column = last_token
        break
      else
        error(format("invalid column name '%s' for model '%s'", token, model.class_name))
      end
    end
    if not a then
      break
    end
    last_token = token
    last_field = field
    i = b + 1
  end
  if json_keys then
    -- Text ops (LIKE, regex, date extraction) need text extraction (->> / #>>)
    -- so PG operators that require text can apply directly. Other ops keep the
    -- jsonb extract (-> / #>) and route through json_* variants that encode the
    -- RHS as JSON literal, so PG can do jsonb-vs-jsonb comparison.
    local arrow_one, arrow_many
    if JSON_TEXT_OPS[op] then
      arrow_one, arrow_many = "->>", "#>>"
    else
      arrow_one, arrow_many = "->", "#>"
    end
    local quoted_col = prefix .. '.' .. smart_quote(column)
    if #json_keys == 1 then
      local k = json_keys[1]
      -- Django 对齐：单段整数样式按数组下标（-> 0 / ->> 0），字符串键才用
      -- 文本（-> 'k'）；对象的 "0" 这类数字字符串键与 Django 一样不支持直查。
      -- 多段路径无须处理：#> 的 text[] 在数组语境自动把数字串当下标。
      if k:match("^%-?%d+$") then
        final_column = format("%s %s %s", quoted_col, arrow_one, k)
      else
        final_column = format("%s %s %s", quoted_col, arrow_one, as_literal(k))
      end
    elseif #json_keys > 1 then
      final_column = format("%s %s ARRAY[%s]", quoted_col, arrow_many,
        as_literal_without_brackets(json_keys))
    end
    if JSON_OP_MAP[op] then
      op = JSON_OP_MAP[op]
    end
  end
  return final_column or (prefix .. '.' .. smart_quote(column)), op
end

---@param sql Sql
---@param key string
---@return string
function M.get_having_column(sql, key)
  if sql._annotate then
    local res = sql._annotate[key]
    if res ~= nil then
      return res
    end
  end
  -- fall back to a regular model column reference, so usages like
  --   :group_by{'name'}:having{name__startswith='a'}
  -- or HAVING expressions over plain columns (Postgres allows this when
  -- the column appears in GROUP BY) work without going through annotate.
  local field = sql.model.fields[key]
  if field then
    local prefix = sql._as or sql.model._table_name_token
    return prefix .. '.' .. (field._column_token or smart_quote(key))
  end
  error(format("invalid alias or column for having: '%s'", key))
end

---@param sql Sql
---@param key string column
---@return string, string
function M.parse_having_column(sql, key)
  local a, b = key:find("__", 1, true)
  if not a then
    return M.get_having_column(sql, key), "eq"
  end
  local token = key:sub(1, a - 1)
  local op = key:sub(b + 1)
  -- HAVING references a group-by column or an aggregate alias; nested traversal
  -- (cnt__nope__gte) makes no sense here and used to slip through as op =
  -- "nope__gte" → "invalid sql op" downstream (BUG B1). Reject it up front.
  if op:find("__", 1, true) then
    error(format(
      "invalid having key '%s': nested traversal is not supported, "
      .. "use 'alias__op' (e.g. 'cnt__gte') only", key))
  end
  if not EXPR_OPERATORS[op] then
    error(format("invalid having operator '%s' in key '%s'", op, key))
  end
  return M.get_having_column(sql, token), op
end

return M
