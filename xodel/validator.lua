local cjson_encode = require "cjson.safe".encode
local cjson_decode = require "cjson.safe".decode
local NULL = require "cjson".null
local ENCODE_AS_ARRAY = require "cjson".empty_array_mt

local match, gsub
if ngx then
  match = ngx.re.match
  gsub = ngx.re.gsub
else
end
local math_floor = math.floor
local tonumber = tonumber
local tostring = tostring
local type = type
local string_format = string.format

local function utf8len(s)
  local _, cnt = s:gsub("[^\128-\193]", "")
  return cnt
end

local function required(message)
  message = message or "此项必填"
  local function required_validator(v)
    if v == nil or v == "" then
      return nil, message
    else
      return v
    end
  end

  return required_validator
end

local function not_required(v)
  if v == nil or v == "" or v == NULL then
    return
  else
    return v
  end
end

-- 包装一下, 保证只接收一个参数, 因为cjson_encode({}, nil)会报错
local function decode(v)
  return cjson_decode(v)
end

local function encode(v)
  return cjson_encode(v)
end

local function number(v)
  local n = tonumber(v)
  if n == nil then
    return nil, "要求是数字"
  end
  return n
end

local bool_map = {
  [true] = true,
  [false] = false,
  t = true,
  f = false,
  on = true,
  off = false,
  [1] = true,
  [0] = false,
  ["1"] = true,
  ["0"] = false,
  ["true"] = true,
  ["false"] = false,
  ["TRUE"] = true,
  ["FALSE"] = false,
  ["是"] = true,
  ["否"] = false
}
local function boolean(v)
  local bv = bool_map[v]
  if bv == nil then
    return nil, string_format("invalid boolean value: %s(%s)", v, type(v))
  else
    return bv
  end
end

local function boolean_cn(v)
  local bv = bool_map[v]
  if bv == nil then
    return nil, "请填“是”或“否”"
  elseif bv == true then
    return "是"
  else
    return "否"
  end
end

local function as_is(v)
  return v
end

local function string(v)
  if type(v) == "string" then
    return v
  else
    return nil, "string type required, not " .. type(v)
  end
end

local function trim(v)
  local err
  v, err = match(v, [[^\s*(.*?)\s*$]], "josui")
  if v then
    return v[1]
  elseif err then
    return nil, err
  else
    return nil, "unkonwn error when performing ngx.re.match"
  end
end

local function year_month(v)
  local err
  v, err = match(v, [[^\d{4}[-.][01]\d$]], "josui")
  if v then
    return v[0]
  elseif err then
    return nil, err
  else
    return nil, "格式不正确，正确举例：2010.01"
  end
end

local function year(v)
  local err
  v, err = match(v, [[^\d{4}$]], "josi")
  if v then
    return v[0]
  elseif err then
    return nil, err
  else
    return nil, "只能填写4位表示年份的数字"
  end
end

local function delete_spaces(v)
  local err
  v, err = gsub(v, "\\s", "", "josui")
  if v then
    return v
  elseif err then
    return nil, err
  else
    return nil, "unkonwn error when performing ngx.re.gsub"
  end
end

local function maxlength(len, message)
  message = message or "字数不能多于%s个"
  message = message:gsub('%%s', tostring(len))
  local function maxlength_validator(v)
    if utf8len(v) > len then
      return nil, message
    else
      return v
    end
  end

  return maxlength_validator
end

local function length(len, message)
  message = message or "字数需等于%s个"
  message = message:gsub('%%s', tostring(len))
  local function length_validator(v)
    if utf8len(v) ~= len then
      return nil, message
    else
      return v
    end
  end

  return length_validator
end

local function minlength(len, message)
  message = message or "字数不能少于%s个"
  message = message:gsub('%%s', tostring(len))
  local function minlength_validator(v)
    if utf8len(v) < len then
      return nil, message
    else
      return v
    end
  end

  return minlength_validator
end

local function pattern(regex, message)
  message = message or "格式错误"
  local function pattern_validator(v)
    if not match(v, regex, "josui") then
      return nil, message
    else
      return v
    end
  end

  return pattern_validator
end

local function max(n, message)
  message = message or "值不能大于%s"
  message = message:gsub('%%s', tostring(n))
  local function max_validator(v)
    if v > n then
      return nil, message
    else
      return v
    end
  end

  return max_validator
end

local function min(n, message)
  message = message or "值不能小于%s"
  message = message:gsub('%%s', tostring(n))
  local function min_validator(v)
    if v < n then
      return nil, message
    else
      return v
    end
  end

  return min_validator
end

local function valid_date(year, month, day)
  if month > 12 or month < 1 then
    return nil, "月份数字" .. month .. "错误"
  end
  if day > 31 or day < 1 then
    return nil, "日期数字" .. day .. "错误"
  end
  if (month == 4 or month == 6 or month == 9 or month == 11) and day > 30 then
    -- Apr, Jun, Sep, Nov can have at most 30 days
    return nil, string_format("%s月只有30天", month)
  elseif month == 2 then
    -- Feb
    if (year % 400 == 0 or (year % 100 ~= 0 and year % 4 == 0)) then
      -- if leap year, days can be at most 29
      if day > 29 then
        return nil, "闰年2月最多29天"
      end
    elseif day > 28 then
      -- else 28 days is the max
      return nil, "普通年份2月最多28天"
    end
  elseif day > 31 then
    -- all other months can have at most 31 days
    return nil, string_format("%s月只有31天", month)
  end
  return year, month, day
end

local function date(v)
  -- 为了能够识别X年X月X日
  local err
  v, err = match(v, [[^(\d{4})([^\d])(\d\d?)([^\d])(\d\d?)([^\d])?$]], "josui")
  if v then
    local valid, msg = valid_date(tonumber(v[1]), tonumber(v[3]), tonumber(v[5]))
    if not valid then
      return nil, msg
    else
      return v[1] .. "-" .. v[3] .. "-" .. v[5]
    end
  elseif err == nil then
    return nil, "日期格式错误, 正确格式举例: 2010-01-01"
  else
    return nil, err
  end
end

local function time(v)
  local m, err = match(v, [[^(\d\d?):(\d\d?):(\d\d?)$]], "josui")
  if m then
    local hour = tonumber(m[1])
    if hour > 24 or hour < 0 then
      return nil, "小时数字" .. m[1] .. "错误"
    end
    local minute = tonumber(m[2])
    if minute > 60 or minute < 0 then
      return nil, "分钟数字" .. m[2] .. "错误"
    end
    local second = tonumber(m[3])
    if second > 60 or second < 0 then
      return nil, "秒数字" .. m[3] .. "错误"
    end
    return v
  elseif err == nil then
    return nil, "时间格式错误, 正确格式举例: 01:30:00"
  else
    return nil, err
  end
end

local function datetime(v)
  local err
  -- 为了兼容"2023-09-24T13:41:52+08:00"
  v, err = match(tostring(v), [[^(\d{4})([^\d])(\d\d?)(\2)(\d\d?)[ T](\d\d?):(\d\d?):(\d\d?)(\+\d\d?(:\d\d)?)?$]],
    "josui")
  if v then
    local valid, msg = valid_date(tonumber(v[1]), tonumber(v[3]), tonumber(v[5]))
    if not valid then
      return nil, msg
    end
    local hour = tonumber(v[6])
    if hour > 24 or hour < 0 then
      return nil, "小时数字" .. v[6] .. "错误"
    end
    local minute = tonumber(v[7])
    if minute > 60 or minute < 0 then
      return nil, "分钟数字" .. v[7] .. "错误"
    end
    local second = tonumber(v[8])
    if second > 60 or second < 0 then
      return nil, "秒数字" .. v[8] .. "错误"
    end
    return string_format("%s-%s-%s %s:%s:%s", v[1], v[3], v[5], v[6], v[7], v[8])
  elseif err == nil then
    return nil, "日期格式错误, 正确格式举例: 2010-01-01 01:30:00"
  else
    return nil, err
  end
end

local function non_empty_array_required(message)
  message = message or "此项必填"
  local function array_validator(v)
    if #v == 0 then
      return nil, message
    else
      return v
    end
  end

  return array_validator
end

local function integer(v)
  local n = tonumber(v)
  if not n or n ~= math_floor(n) then
    return nil, "要求整数"
  else
    return n
  end
end

local URL_REGEX = "^(https?:)?//.*$" -- yeah baby, just so simple
local function url(v)
  if not match(v, URL_REGEX, "josui") then
    return nil, "错误链接格式"
  else
    return v
  end
end

-- local url = pattern('^(https?:)?//.*$')

local function encode_as_array(v)
  if v == nil then
    v = {}
  end
  if type(v) ~= "table" then
    return nil, "value must be a table"
  else
    return setmetatable(v, ENCODE_AS_ARRAY)
  end
end

local a = { 7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2 }
local b = { "1", "0", "X", "9", "8", "7", "6", "5", "4", "3", "2" }
local function validate_id_card(s)
  local n = 0
  for i = 1, 17 do
    n = n + tonumber(s:sub(i, i)) * a[i]
  end
  if b[n % 11 + 1] == s:sub(18, 18) then
    return s
  else
    return nil, "身份证号错误"
  end
end

local function id_card(v)
  if utf8len(v) ~= 18 then
    return nil, string_format("身份证号必须为18位，当前%s位", #v)
  end
  if not match(v, [[^\d{17}[\dX]$]], "josui") then
    return nil, "身份证号前17位必须为数字，第18位必须为数字或大写字母X"
  end
  local res, err = valid_date(tonumber(v:sub(7, 10)), tonumber(v:sub(11, 12)), tonumber(v:sub(13, 14)))
  if res == nil then
    return nil, "身份证号日期部分错误:" .. err
  end
  return validate_id_card(v)
end

local function email(v)
  -- https://developer.mozilla.org/en-US/docs/Learn/Common_questions/Web_mechanics/What_is_a_domain_name#structure_of_domain_names
  local regex = [=[^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$]=]
  local ok = match(v, regex, "josui")
  if ok then
    return v
  else
    return nil, "电子邮件格式不正确"
  end
end

return {
  required = required,
  not_required = not_required,
  string = string,
  maxlength = maxlength,
  minlength = minlength,
  length = length,
  max = max,
  min = min,
  pattern = pattern,
  forbid_empty_array = non_empty_array_required,
  integer = integer,
  url = url,
  encode = encode,
  decode = decode,
  number = number,
  as_is = as_is,
  encode_as_array = encode_as_array,
  year_month = year_month,
  year = year,
  date = date,
  datetime = datetime,
  time = time,
  trim = trim,
  delete_spaces = delete_spaces,
  boolean = boolean,
  boolean_cn = boolean_cn,
  id_card = id_card,
  email = email,
  validate_id_card = validate_id_card,
  bool_map = bool_map
}
