require 'English'

module ParallelCucumber
  class Runner
    def initialize(options)
      @options = options
    end

    def run_tests(process_number, scenarios)
      cmd = command_for_test(scenarios)
      execute_command_for_process(process_number, cmd)
    end

    private

    def command_for_test(scenarios)
      cucumber_options = @options[:cucumber_options]
      setup_script = @options[:setup_script]
      teardown_script = @options[:teardown_script]

      cucumber_cmd = ['cucumber', cucumber_options, *scenarios].compact.join(' ')

      cmd = [setup_script, cucumber_cmd].compact.join(' && ')
      teardown_script.nil? ? cmd : "#{cmd}; RET=$?; #{teardown_script}; exit ${RET}"
    end

    def execute_command_for_process(process_number, cmd)
      env = env_for_process(process_number)
      print_chevron_msg(process_number, "Custom env: #{env.map { |k, v| "#{k}=#{v}" }.join(' ')}; command: #{cmd}")

      begin
        output = IO.popen(env, "#{cmd} 2>&1") do |io|
          print_chevron_msg(process_number, "Pid: #{io.pid}")
          show_output(io, process_number)
        end
      ensure
        exit_status = -1
        if !$CHILD_STATUS.nil? && $CHILD_STATUS.exited?
          exit_status = $CHILD_STATUS.exitstatus
          print_chevron_msg(process_number, "Exited with status #{exit_status}")
        end
      end

      { stdout: output, exit_status: exit_status }
    end

    def env_for_process(process_number)
      env_variables = @options[:env_variables]
      env = env_variables.map do |k, v|
        case v
        when String, Numeric, TrueClass, FalseClass
          [k, v]
        when Array
          [k, v[process_number]]
        when Hash
          value = v[process_number.to_s]
          [k, value] unless value.nil?
        when NilClass
        else
          raise("Don't know how to set '#{v}'(#{v.class}) to the environment variable '#{k}'")
        end
      end.compact.to_h

      {
        TEST: 1,
        TEST_PROCESS_NUMBER: "#{Time.now.strftime('%y%m%d-%H%M%S')}-#{process_number}"  # Sorts nicely numerically.
      }.merge(env).map { |k, v| [k.to_s, v.to_s] }.to_h
    end

    def print_chevron_msg(chevron, line, io = $stdout)
      msg = "#{chevron}> #{line}\n"
      io.print(msg)
      io.flush
    end

    def show_output(io, process_number)
      file = File.open("process_#{process_number}.log", 'w')
      remaining_part = ''
      probable_finish = false
      begin
        loop do
          text_block = remaining_part + io.read_nonblock(32 * 1024)
          lines = text_block.split("\n")
          remaining_part = lines.pop
          probable_finish = last_cucumber_line?(remaining_part)
          lines.each do |line|
            probable_finish = true if last_cucumber_line?(line)
            print_chevron_msg(process_number, line)
            file.write("#{line}\n")
          end
        end
      rescue IO::WaitReadable
        timeout = probable_finish ? 10 : 1800
        result = IO.select([io], [], [], timeout)
        if result.nil?
          if probable_finish
            print_chevron_msg(process_number,
                              "Timeout reached in #{timeout}s, but process has probably finished", $stderr)
          else
            raise("Read timeout has reached for process #{process_number}. There is no output in #{timeout}s")
          end
        else
          retry
        end
      rescue EOFError # rubocop:disable Lint/HandleExceptions
      ensure
        print_chevron_msg(process_number, remaining_part)
        file.write(remaining_part.to_s)
        file.close unless file.nil?
      end
      File.read("process_#{process_number}.log")
    end

    def last_cucumber_line?(line)
      !(line =~ /\d+m[\d\.]+s/).nil?
    end
  end # Runner
end # ParallelCucumber
