module ActiveRecord
  module ConnectionAdapters
    module Redshift
      module ReferentialIntegrity # :nodoc:
        def supports_disable_referential_integrity? # :nodoc:
          true
        end

        def disable_referential_integrity # :nodoc:
          if !@config[:mock]
            yield
          else
            begin
              transaction(requires_new: true) do
                execute("SET CONSTRAINTS ALL DEFERRED")
                yield
              end
            rescue ActiveRecord::InvalidForeignKey, ActiveRecord::ActiveRecordError => e
              warn <<-WARNING
                WARNING: Rails was not able to disable referential integrity.
                cause: #{e.try(:message)}
                WARNING
              raise e
            end
          end
        end
      end
    end
  end
end
