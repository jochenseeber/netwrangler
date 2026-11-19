module Netwrangler
  # The version in shard.yml, which `rake release` writes
  VERSION = {{ read_file("#{__DIR__}/../shard.yml").lines.find(&.starts_with?("version:")).split(":")[1].strip }}
end
