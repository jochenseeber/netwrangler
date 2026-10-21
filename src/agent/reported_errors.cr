require "json"
require "log"

module Netwrangler::Agent
  # Remembers the conflict errors the agent logged in its previous run, so a
  # conflict that persists is logged as an error once and then at debug
  # level. The agent runs as a new process on every event, so the record
  # lives in a file.
  class ReportedErrors
    Log = ::Log.for(self)

    STATE_FILE = "/tmp/shell-operator/reported-errors.json"

    @previous : Set(String)
    @current = Set(String).new

    def initialize(@path : String = STATE_FILE)
      @previous = load
    end

    # Whether neither the previous run nor this one reported the message yet.
    # Records the message for the next run either way.
    def fresh?(message : String) : Bool
      fresh = !@previous.includes?(message) && !@current.includes?(message)
      @current << message
      fresh
    end

    # Keeps this run's messages for the next run; a conflict that went away
    # is forgotten, so it is logged as an error again if it comes back
    def save : Nil
      File.write(@path, @current.to_a.to_json)
    rescue ex
      Log.warn { "Failed to save the reported errors: #{ex.message}" }
    end

    private def load : Set(String)
      return Set(String).new unless File.exists?(@path)

      Array(String).from_json(File.read(@path)).to_set
    rescue ex
      Log.warn { "Failed to load the reported errors: #{ex.message}" }
      Set(String).new
    end
  end
end
