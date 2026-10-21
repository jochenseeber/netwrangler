# frozen_string_literal: true

require_relative "rakelib/project"

# Everything this project builds, tests, packages and deploys is defined by the
# facets in `rakelib/facets/`, each discovering what it acts on and configured by
# its own section of `.project.yaml`. All that is left here is what belongs to
# this project alone.

# The integration tests run against the kind cluster, so every image has to be
# rebuilt and rolled out first — not just the one under test, since the agent and
# controller are tested as a pair, which is exactly what `kind:restart` does.
# Registered here and run once every facet has contributed, so it does not depend
# on the components being known while this file loads.
PROJECT.define do
  PROJECT.components.each_value do |component|
    next if component[:crystal].nil? || component[:crystal].virtual

    task "#{component.name}:test" => "kind:restart"
  end
end
