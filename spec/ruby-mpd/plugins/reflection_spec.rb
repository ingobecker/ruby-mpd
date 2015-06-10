require 'spec_helper'
require_relative '../../../lib/ruby-mpd/plugins/reflection'

RSpec.describe MPD::Plugins::Reflection do
  class MPD
    def send_command(command, *args); end
  end

  subject { MPD.new.extend described_class }

  context "#config" do
    it "should send correct params" do
      expect(subject).to receive(:send_command).with(:config)
      subject.config
    end
  end

  context "#commands" do
    it "should send correct params" do
      expect(subject).to receive(:send_command).with(:commands)
      subject.commands
    end
  end

  context "#notcommands" do
    it "should send correct params" do
      expect(subject).to receive(:send_command).with(:notcommands)
      subject.notcommands
    end
  end

  context "#url_handlers" do
    it "should send correct params" do
      expect(subject).to receive(:send_command).with(:urlhandlers)
      subject.url_handlers
    end
  end

  context "#decoders" do
    it "should send correct params" do
      expect(subject).to receive(:send_command).with(:decoders)
      subject.decoders
    end
  end

  context "#tags" do
    let(:tagtypes) { ['TAG1', 'TAG2'] }
    it "should send correct params" do
      expect(subject).to receive(:send_command).with(:tagtypes).and_return(tagtypes)
      expect(subject).not_to receive(:send_command)
      expect(subject.tags).to eql(['tag1','tag2'])
      expect(subject.tags).to eql(['tag1','tag2'])
    end
  end
end
