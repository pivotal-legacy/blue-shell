require 'spec_helper'
require 'tempfile'

module BlueShell
  describe Runner do
    let(:timeout) { 1 }

    describe "running a command" do
      let(:file) do
        file = Tempfile.new('blue-shell-runner')
        sleep 1 # wait one second to make sure touching the file does something measurable
        file
      end

      after { file.unlink }

      it "runs a command" do
        BlueShell::Runner.run("touch -a #{file.path}")
        file.stat.atime.should > file.stat.mtime
      end
    end

    describe "killing a command" do
      it "stops its process" do
        BlueShell::Runner.run("sleep 10") do |runner|
          runner.kill
          expect {
            runner.exited?
          }.to raise_exception Errno::ESRCH # /* no such process error */
        end
      end
    end

    describe "#success? and #successful?" do
      context "when the command has a non-zero exit code" do
        it "returns false" do
          runner = BlueShell::Runner.run("false") { |runner|
            runner.wait_for_exit
          }
          runner.should_not be_success
          runner.should_not be_successful

          runner = BlueShell::Runner.run("false")
          runner.should_not be_success
          runner.should_not be_successful
        end
      end

      context "when the command has a zero exit code" do
        it "returns true" do
          runner = BlueShell::Runner.run("true")
          runner.should be_success
          runner.should be_successful
        end
      end
    end

    describe "#expect" do
      context "when the expected output shows up" do
        it "returns a truthy value" do
          BlueShell::Runner.run("echo -n foo") do |runner|
            expect(runner.expect('foo')).to be_true
          end
        end
      end

      context "when the expected output never shows up" do
        it "returns nil" do
          BlueShell::Runner.run("echo the spanish inquisition") do |runner|
            expect(runner.expect("something else", 0.5)).to be_nil
          end
        end
      end

      context "when the output eventually shows up" do
        it "returns a truthy value" do
          BlueShell::Runner.run("ruby #{asset("pause.rb")}") do |runner|
            expect(runner.expect("finished")).to be_true
          end
        end
      end

      context "backspace" do
        it "respects the backspace character" do
          BlueShell::Runner.run("ruby -e 'puts \"foo a\\bbar\"'") do |runner|
            expect(runner.expect("foo bar")).to be_true
          end
        end

        it "does not go beyond the beginning of the line" do
          BlueShell::Runner.run("ruby -e 'print \"foo abc\nx\\b\\bd\"'") do |runner|
            expect(runner.expect("foo abc\nd")).to be_true
          end
        end

        it "does not go beyond the beginning of the string" do
          BlueShell::Runner.run("ruby -e 'print \"f\\b\\bbar\"'") do |runner|
            expect(runner.expect("bar")).to be_true
          end
        end

        it "leaves backspaced characters in the buffer until they're overwritten" do
          BlueShell::Runner.run("ruby -e 'print \"foo abc\\b\\bd\"'") do |runner|
            expect(runner.expect("foo adc")).to be_true
          end
        end
      end

      context "ansi escape sequences" do
        it "filters ansi color sequences" do
          BlueShell::Runner.run("ruby -e 'puts \"\\e[36mblue\\e[0m thing\"'") do |runner|
            expect(runner.expect("blue thing")).to be_true
          end
        end
      end

      context "expecting multiple branches" do
        context "and one of them matches" do
          it "can be passed a hash of values with callbacks, and returns the matched key" do
            BlueShell::Runner.run("echo 1 3") do |runner|
              branches = {
                "1" => proc { 1 },
                "2" => proc { 2 },
                "3" => proc { 3 }
              }

              expect(runner.expect(branches)).to eq "1"
              expect(runner.expect(branches)).to eq "3"
            end
          end

          it "calls the matched callback" do
            callback = double(:callback)
            BlueShell::Runner.run("echo 1 3") do |runner|
              branches = {
                "1" => proc { callback }
              }
              runner.expect(branches)
            end
          end
        end

        context "and none of them match" do
          it "returns nil when none of the branches match" do
            BlueShell::Runner.run("echo not_a_number") do |runner|
              expect(runner.expect({"1" => proc { 1 }}, timeout)).to be_nil
            end
          end
        end
      end
    end

    describe "#output" do
      it "makes the entire command output (so far) available" do
        BlueShell::Runner.run("echo 0 1 2 3") do |runner|
          runner.expect("1")
          runner.expect("3")
          expect(runner.output).to eq "0 1 2 3"
        end

      end
    end

    describe "#send_keys" do
      it "sends input and expects more output afterward" do
        BlueShell::Runner.run("ruby #{asset("input.rb")}") do |runner|
          expect(runner.expect("started")).to be_true
          runner.send_keys("foo")
          expect(runner.expect("received foo")).to be_true
        end
      end
    end

    describe "#send_return" do
      it "sends a return and expects more output af`terwards" do
        BlueShell::Runner.run("ruby #{asset("input.rb")}") do |runner|
          expect(runner.expect("started")).to be_true
          runner.send_return
          expect(runner.expect("received ")).to be_true
        end
      end
    end

    describe "#send_up_arrow" do
      it "sends an up arrow key press and expects more output afterwards" do
        BlueShell::Runner.run("ruby #{asset("unbuffered_input.rb")} #{EscapedKeys::KEY_UP}") do |runner|
          expect(runner.expect("started")).to be_true
          runner.send_up_arrow
          expect(runner.expect('received: "\e[A"')).to be_true
        end
      end
    end

    describe "#send_right_arrow" do
      it "sends a right arrow key press and expects more output afterwards" do
        BlueShell::Runner.run("ruby #{asset("unbuffered_input.rb")} #{EscapedKeys::KEY_RIGHT}") do |runner|
          expect(runner.expect("started")).to be_true
          runner.send_right_arrow
          expect(runner.expect('received: "\e[C"')).to be_true
        end
      end
    end

    describe "#send_backspace" do
      it "sends a backspace key press and expects a character to be deleted" do
        BlueShell::Runner.run("ruby #{asset("input.rb")}") do |runner|
          expect(runner.expect("started")).to be_true
          runner.send_keys "foo"
          runner.send_backspace
          runner.send_return
          expect(runner.expect('received fo')).to be_true
        end
      end
    end

    context "#exit_code" do
      it "returns the exit code" do
        BlueShell::Runner.run("ruby -e 'exit 42'") do |runner|
          runner.wait_for_exit
          expect(runner.exit_code).to eq(42)
        end
      end

      context "when the command is still running" do
        it "waits for the command to exit" do
          BlueShell::Runner.run("sleep 0.5") do |runner|
            expect(runner.exit_code).to eq(0)
          end
        end
      end

      context "when the command doesn't finish within the timeout" do
        it "raises a timeout error" do
          BlueShell::Runner.run("sleep 10") do |runner|
            expect { runner.exit_code }.to raise_error(Timeout::Error)
          end
        end

        it "prints the output so far" do
          BlueShell::Runner.run("echo 'everything is coming up wankershim' && sleep 10") do |runner|
            expect { runner.exit_code }.to raise_error(Timeout::Error, /everything is coming up wankershim/)
          end
        end
      end

      it "uses the given timeout" do
        BlueShell::Runner.run("sleep 2") do |runner|
          expect { runner.exit_code(1) }.to raise_error(Timeout::Error)
        end
      end
    end

    context "#exited?" do
      it "returns false if the command is still running" do
        BlueShell::Runner.run("sleep 10") do |runner|
          expect(runner.exited?).to eq false
        end
      end
    end
  end
end
