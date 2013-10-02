require 'pty'
require 'timeout'

module BlueShell
  class Runner
    def initialize(*args)
      @stdout, slave = PTY.open
      system('stty raw', :in => slave)
      read, @stdin = IO.pipe

      @pid = spawn(*(args.push(:in => read, :out => slave, :err => slave)))

      @expector = BufferedReaderExpector.new(@stdout, ENV['DEBUG_BACON'])

      if block_given?
        yield self
      else
        wait_for_exit()
      end
    end

    class << self
      alias_method :run, :new
    end

    def expect(matcher, timeout = 30)
      case matcher
      when Hash
        expect_branches(matcher, timeout)
      else
        @expector.expect(matcher, timeout)
      end
    end

    def send_up_arrow
      @stdin.print("\e[A")
    end

    def send_right_arrow
      @stdin.print("\e[C")
    end

    def send_backspace
      @stdin.print("\b \b")
    end

    def send_keys(text_to_send)
      @stdin.puts(text_to_send)
    end

    def send_return
      @stdin.puts
    end

    def kill
      Process.kill('INT', @pid)
    end

    def exit_code(timeout = 5)
      return @code if @code

      code = nil
      begin
        Timeout.timeout(timeout) do
          _, code = Process.waitpid2(@pid)
        end
      rescue Timeout::Error
        raise ::Timeout::Error.new("execution expired, output was:\n#{@expector.read_to_end}")
      end

      @code = numeric_exit_code(code)
    end

    alias_method :wait_for_exit, :exit_code

    def exited?
      !running?
    end

    def success?
      @code.zero?
    end

    alias_method :successful?, :success?

    def running?
      !!Process.getpgid(@pid)
    end

    def output
      @expector.output
    end

    def debug
      @expector.debug
    end

    def debug=(x)
      @expector.debug = x
    end

    private

    def expect_branches(branches, timeout)
      branch_names = /#{branches.keys.collect { |k| Regexp.quote(k) }.join('|')}/
      expected = @expector.expect(branch_names, timeout)
      return unless expected

      data = expected.first.match(/(#{branch_names})$/)
      matched = data[1]
      branches[matched].call
      matched
    end

    def numeric_exit_code(status)
      status.exitstatus
    rescue NoMethodError
      status
    end
  end
end
