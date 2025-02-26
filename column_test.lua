local insert = table.insert
---@param s string
---@return string[]
local function split_string(s, pattern)
  local parts = {}
  local start = 1

  while true do
    local pos = s:find(pattern, start, true)
    if not pos then
      insert(parts, s:sub(start))
      break
    end
    insert(parts, s:sub(start, pos - 1))
    start = pos + 2
  end

  return parts
end

---@param sql_part string
---@return string?
local function extract_column_name(sql_part)
  -- 1. T.col, user.name
  local _, col = sql_part:match("^([%w_]+)%.([%w_]+)$")
  if col then
    return col
  end

  -- 2.  T.col AS alias, col AS alias
  local alias = sql_part:match("[Aa][Ss]%s+([%w_]+)%s*$")
  if alias then
    return alias
  end

  -- 3. ignore function call
  if sql_part:match("%b()") then
    return nil
  end

  return sql_part:match("^([%w_]+)$")
end

---@param sql_text string
---@return string[]
local function extract_column_names(sql_text)
  local columns = {}
  local parts = split_string(sql_text, ", ")
  for _, part in ipairs(parts) do
    local col = extract_column_name(part)
    if col then
      insert(columns, col)
    end
  end
  return columns
end

-- 测试用例
local function test_extract_column_names()
  local test_cases = {
    {
      sql = "count(id) as total_count, sum(price * quantity) as total_amount",
      expected = { "total_count", "total_amount" }
    },
    {
      sql = "user.name as user_name, dept.name as dept_name",
      expected = { "user_name", "dept_name" }
    },
    {
      sql = "id, name, age",
      expected = { "id", "name", "age" }
    },
    {
      sql = "COALESCE(nickname, username) as display_name, DATE_FORMAT(created_at, '%Y-%m-%d') as date",
      expected = { "display_name", "date" }
    },
    {
      sql = "T.id, T.name AS username, count(O.id) as order_count",
      expected = { "id", "username", "order_count" }
    },
    {
      sql = "MAX(CASE WHEN type = 1 THEN score END) as max_score, AVG(score) as avg_score",
      expected = { "max_score", "avg_score" }
    }
  }

  local function arrays_equal(a1, a2)
    if #a1 ~= #a2 then return false end
    for i = 1, #a1 do
      if a1[i] ~= a2[i] then return false end
    end
    return true
  end

  for i, test_case in ipairs(test_cases) do
    local result = extract_column_names(test_case.sql)
    local success = arrays_equal(result, test_case.expected)
    if not success then
      print(string.format("Test case %d failed!", i))
      print("SQL:", test_case.sql)
      print("Expected:", table.concat(test_case.expected, ", "))
      print("Got:", table.concat(result, ", "))
      return false
    end
  end

  print("All test cases passed!")
  return true
end

-- 运行测试
test_extract_column_names()

print(extract_column_name("Count(x) as b1"))
