require 'thread'
require 'monitor'

require 'parallel_cucumber/cli'
require 'parallel_cucumber/grouper'
require 'parallel_cucumber/result_formatter'
require 'parallel_cucumber/runner'
require 'parallel_cucumber/version'

module ParallelCucumber
  class << self
    def run_tests_in_parallel(options)
      test_results = []
      report_time_taken do
        runner = Runner.new(options)

        queue = Grouper.all_runnable_scenarios(options)
        queue_full_size = queue.size

        slots = options[:n].times.map { |i| { worker: i, thread: nil } }
        slots.extend(MonitorMixin)
        slots_bumped = slots.new_cond

        # Pass ctrl-c to subprocesses; handle process termination through slot/thread mechanism.
        # Isn't there a way to send ctrl-c to the process group?
        trap('INT') { slots.each { |s| kill 'INT', s[:pid] if s[:pid] } }

        until queue.empty? && slots.none? { |s| s[:thread] } # All slots empty [nil, ...] or decommissioned (size==0)
          puts "queue #{queue.size}/#{queue_full_size} slots #{slots}"
          slots.synchronize do
            slots_bumped.wait_until {
              queue.any? ?
                slots.find { |slot| slot[:thread].nil? || !slot[:thread].status } :
                slots.find { |slot| slot[:thread] && ! slot[:thread].status }
            }

            process_terminated_threads(queue, slots, test_results)
            break if slots.empty?
            until queue.empty? || slots.all? { |s| s[:thread] }
              slots.each do |slot|
                next unless slot[:thread].nil? && queue.any?
                batch = queue.shift([1, queue.size / slots.size, 10].sort[1])
                slot[:thread] = Thread.new(slot[:worker], batch) do |worker_number, scenarios|
                  begin
                    slot[:slept] = sleep(worker_number * options[:thread_delay]) unless slot[:slept]
                    thread = Thread.current
                    thread[:scenarios] = scenarios
                    thread[:result] = runner.run_tests(worker_number, scenarios)
                  ensure
                    slots.synchronize { slots_bumped.signal }
                  end
                end
              end
            end
          end
        end

        trap('INT', 'DEFAULT')

        puts '** All slots were decommissioned' if slots.empty?
        ResultFormatter.report_results(test_results)
      end
      exit(1) if any_test_failed?(test_results)
    end

    private

    def process_terminated_threads(queue, slots, test_results)
      puts "Terminateds? #{slots}"
      slots.each do |slot|
        thread = slot[:thread]
        next if thread.nil? || thread.status || !thread[:result]
        exit_status = thread[:result][:exit_status]
        case exit_status
          when 0, 1
            test_results << thread[:result]
            slot[:thread] = nil
          else
            puts "Worker #{slot[:worker]} had special exit status #{exit_status}: Deleting worker, requeueing scenarios."
            # queue.push(thread[:scenarios])
            slot[:thread] = :delete_this_slot_and_worker
        end
      end
      slots.delete_if { |s| s[:thread] == :delete_this_slot_and_worker }
    end


    def any_test_failed?(test_results)
      test_results.any? { |result| result[:exit_status] != 0 }
    end

    def report_time_taken
      start = Time.now
      yield
      time_in_sec = Time.now - start
      mm, ss = time_in_sec.divmod(60)
      puts "\nTook #{mm} Minutes, #{ss.round(2)} Seconds"
    end
  end # class
end # ParallelCucumber
