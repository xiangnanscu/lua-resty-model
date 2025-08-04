local Blog = require 'spec.model_spec'.Blog

print(Blog:where { name__endswith = 'Blog%_\\' }:select { 'name' }:statement())
