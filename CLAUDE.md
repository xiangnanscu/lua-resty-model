# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is lua-resty-model, a powerful PostgreSQL ORM for OpenResty/Lua inspired by Django ORM. It provides comprehensive database operations including complex queries, joins, aggregations, and data manipulation with automatic SQL generation and field validation.

## Core Architecture

- **Main Model Class**: `lib/resty/model.lua` - The core ORM implementation with query builder, field validation, and database operations
- **Field System**: Uses `resty.fields` for field definitions, validation, and type conversion
- **Query Builder**: Advanced SQL query construction with support for joins, aggregations, and complex conditions
- **Database Backend**: PostgreSQL-specific with support for advanced features like JSON operations, arrays, and CTE queries

## Common Development Commands

### Testing
```bash
# Run all tests with TAP output
yarn test

# Run tests using resty directly  
yarn resty -I spec bin/ngx_busted.lua -o TAP

# Generate SQL documentation from tests
yarn sql.md
```

### Development
```bash
# Run OpenResty with proper library paths
yarn resty

# Release and upload to OPM
yarn rc

# Commit changes
yarn commit "commit message"
```

## Key Components

### Model Definition
Models are defined with table names and field specifications:
```lua
local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { "name", maxlength = 20, unique = true },
    { "tagline", type = 'text' },
  }
}
```

### Query System
- **Filtering**: `where()` with operators like `__gt`, `__contains`, `__in`
- **Joins**: Automatic foreign key joins, manual joins with `join()`
- **Aggregation**: `annotate()` with `Sum`, `Count`, `Avg`, `Max`, `Min`
- **Advanced**: `Q` objects for complex conditions, `F` expressions for field operations

### Data Operations
- **CRUD**: `insert()`, `update()`, `delete()`, `get()`, `create()`
- **Bulk Operations**: `upsert()`, `merge()`, `updates()` for batch processing
- **Transactions**: Built-in transaction support with rollback capabilities

## Testing Framework

Uses Busted testing framework with:
- Test specifications in `spec/model_spec.lua`  
- Custom test runner at `bin/ngx_busted.lua`
- Database fixtures and comprehensive API testing
- SQL statement validation and output formatting

## Field Validation

Comprehensive field validation system supporting:
- Type validation (integer, float, date, email, etc.)
- Length constraints (maxlength, minlength)
- Uniqueness and required field constraints
- Custom validation functions
- Default values and auto-generation

## PostgreSQL Features

Advanced PostgreSQL support including:
- JSON/JSONB field operations (`__has_key`, `__contains`)
- Array field handling
- Complex operators for ranges, arrays, and JSON
- CTE (Common Table Expressions) queries
- Full-text search capabilities