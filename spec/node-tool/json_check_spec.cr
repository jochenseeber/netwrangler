require "./spec_helper"

private def object?(text : String) : Bool
  valid = Netwrangler::PrivilegedRunner::JsonCheck.object?(text)

  valid
end

describe Netwrangler::PrivilegedRunner::JsonCheck do
  describe ".object?" do
    it "accepts one object with whitespace around it" do
      object?(%( \t\r\n{} \n)).should be_true
      object?(%({"a":[1,2.5,-0,1e3,1E-3,true,false,null,"x",{}]})).should be_true
    end

    it "accepts escapes jansson loads" do
      object?(%({"a":"\\"\\\\\\/\\b\\f\\n\\r\\t\\u00e9\\ud83d\\ude00"})).should be_true
    end

    it "refuses escapes jansson refuses" do
      object?(%({"a":"\\u0000"})).should be_false
      object?(%({"a":"\\ud800"})).should be_false
      object?(%({"a":"\\ud800\\u0041"})).should be_false
      object?(%({"a":"\\udc00"})).should be_false
      object?(%({"a":"\\x41"})).should be_false
      object?(%({"a":"\\u00g0"})).should be_false
    end

    it "accepts integers within 64 bits" do
      object?(%({"a":9223372036854775807})).should be_true
      object?(%({"a":-9223372036854775808})).should be_true
    end

    it "refuses integers beyond 64 bits" do
      object?(%({"a":9223372036854775808})).should be_false
      object?(%({"a":-9223372036854775809})).should be_false
    end

    it "accepts reals that underflow to zero, as jansson does" do
      object?(%({"a":1e-400})).should be_true
    end

    it "refuses reals beyond a double" do
      object?(%({"a":1e400})).should be_false
      object?(%({"a":-1e400})).should be_false
    end

    it "refuses numbers outside the grammar" do
      ["01", "+1", "1.", ".5", "1e", "1e+", "-", "0x10", "Infinity", "NaN"].each do |number|
        {number, object?(%({"a":#{number}}))}.should eq({number, false})
      end
    end

    it "refuses anything but one object" do
      object?("").should be_false
      object?("[]").should be_false
      object?(%("a")).should be_false
      object?("{} {}").should be_false
      object?("{},").should be_false
      object?(%({"a":1,})).should be_false
      object?(%({"a" 1})).should be_false
      object?("{1:2}").should be_false
      object?("{").should be_false
      object?(%({"a":tru})).should be_false
    end

    it "refuses control characters in strings" do
      object?(%({"a":"\t"})).should be_false
    end

    it "limits the nesting depth" do
      object?(%({"a":#{"[" * 64}#{"]" * 64}})).should be_true
      object?(%({"a":#{"[" * 65}#{"]" * 65}})).should be_false
    end
  end
end
