module Netwrangler::Util
  module EnumerableExtensions(T)
    def empty_to_nil : self?
      empty? ? nil : self
    end
  end
end

module Enumerable(T)
  include Netwrangler::Util::EnumerableExtensions(T)
end
