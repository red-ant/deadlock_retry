# Copyright (c) 2005 Jamis Buck
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require 'active_record/connection_adapters/mysql2_adapter'

module DeadlockRetry

  # How many retries should a query get before finally giving up?
  mattr_accessor :maximum_retries_on_deadlock
  self.maximum_retries_on_deadlock = 3

  # Implement how to log the messages from this module. It helps debugging.
  mattr_accessor :deadlock_logger
  self.deadlock_logger = proc { |msg| } # override as needed

  DEADLOCK_ERROR_MESSAGES = [
    "Deadlock found when trying to get lock",
    "Lock wait timeout exceeded"
  ]

  def self.included(klass)
    klass.class_eval do
      alias_method_chain :execute, :deadlock_handling
    end
  end

  def execute_with_deadlock_handling(*objects, &block)
    retry_count = 0

    begin
      execute_without_deadlock_handling(*objects, &block)
    rescue ActiveRecord::StatementInvalid => error
      raise unless DEADLOCK_ERROR_MESSAGES.any? { |msg| error.message =~ /#{Regexp.escape(msg)}/i }

      if in_nested_transaction?
        deadlock_log "Deadlock detected as part of a nested transaction, unable to recover"
        raise
      end

      if retry_count >= DeadlockRetry.maximum_retries_on_deadlock
        deadlock_log "Deadlock unavoidable (locked #{retry_count} times), please investigate"
        log_innodb_status
        raise
      end

      deadlock_log "Deadlock detected on retry #{retry_count}, restarting transaction"
      retry_count += 1
      retry
    end
  end

  private

  def in_nested_transaction?
    # open_transactions was added in 2.2's connection pooling changes.
    self.respond_to?(:open_transactions) && self.open_transactions > 0
  end

  def log_innodb_status
    # `show innodb status` is the only way to get visiblity into why the transaction deadlocked
    deadlock_log "INNODB Status follows:"
    self.select_values("show innodb status").each { |line|
      deadlock_log(line)
    }
  rescue Exception => e
    # If it fails (because user hasn't got the privilege to do it),
    # it's not the end of the world. Let's just ignore it.
    deadlock_log "Failed to log innodb status: #{e.message}"
  end

  def deadlock_log(msg)
    DeadlockRetry.deadlock_logger.call(msg)
  end

end
ActiveRecord::ConnectionAdapters::Mysql2Adapter.send(:include, DeadlockRetry)
