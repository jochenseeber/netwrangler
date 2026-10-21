require "json"

module Netwrangler::Model
  # Kubernetes Condition for resource status
  class Condition
    include JSON::Serializable

    @[JSON::Field(key: "type")]
    property type : String

    @[JSON::Field(key: "status")]
    property status : String

    @[JSON::Field(key: "reason")]
    property reason : String?

    @[JSON::Field(key: "message")]
    property message : String?

    @[JSON::Field(key: "lastTransitionTime")]
    property last_transition_time : Time?

    @[JSON::Field(key: "observedGeneration")]
    property observed_generation : Int64?

    def initialize(
      @type : String,
      *,
      @status : String,
      @reason : String? = nil,
      @message : String? = nil,
      @last_transition_time : Time? = nil,
      @observed_generation : Int64? = nil,
    )
    end

    def message! : String
      @message || raise NilAssertionError.new("Condition#message is nil")
    end

    def_clone
  end
end
