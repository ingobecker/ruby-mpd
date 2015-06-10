require 'spec_helper'
require_relative '../../../lib/ruby-mpd/plugins/outputs'

RSpec.describe MPD::Plugins::Outputs do
  class MPD
    def send_command(command, *args); end
  end

  subject { MPD.new.extend described_class }

  context "#outputs" do
    it "should send correct params" do
      expect(subject).to receive(:send_command).with(:outputs)
      subject.outputs
    end
  end

  context "#enableoutput" do
    it "should send correct params" do
      expect(subject).to receive(:send_command).with(:enableoutput, 1)
      subject.enableoutput(1)
    end
  end

  context "#disableoutput" do
    it "should send correct params" do
      expect(subject).to receive(:send_command).with(:disableoutput, 1)
      subject.disableoutput(1)
    end
  end

  context "#toggleoutput" do
    it "should send correct params" do
      expect(subject).to receive(:send_command).with(:toggleoutput, 1)
      subject.toggleoutput(1)
    end
  end
end
