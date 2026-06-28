#!/usr/bin/env ruby
# Render a template file, substituting ${VAR} placeholders from the environment.
template = File.read(ARGV.fetch(0))
output = template.gsub(/\$\{([A-Z0-9_]+)\}/) { ENV.fetch(Regexp.last_match(1), "") }
print output
