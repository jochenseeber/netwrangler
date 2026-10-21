# frozen_string_literal: true

require_relative "project"

# The only file Rake loads. Requiring a facet registers it; `load_facets` then runs
# every registered body in dependency order against a context of its own, so a facet
# reads what an earlier one contributed without knowing which file put it there.
Dir.glob("rakelib/facets/*.rb").each { |file| require_relative "facets/#{File.basename(file, ".rb")}" }

PROJECT.load_facets

# A language's manifest — shard.yml, package.json, pom.xml — needs its own copy of the
# version to be a valid manifest, so the copies cannot be removed. What they can be is
# derived: `version:update` writes them from the project file, and `version:lint`
# reports when one has drifted. Neither task does anything itself; each facet defines
# `version:update:<language>` and `version:lint:<language>` and joins them as a
# prerequisite, so adding a language never edits this file.
#
# Declared after the facets have run, so a facet's own
# `task "version:update" => "version:update:crystal"` is already in place: Rake merges
# the two declarations and takes the description from here.
desc "Write the project version into every manifest that repeats it"
task "version:update"

desc "Report every manifest whose version has drifted from the project's"
task "version:lint"
