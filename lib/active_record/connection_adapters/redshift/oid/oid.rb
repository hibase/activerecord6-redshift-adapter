module ActiveRecord
  module ConnectionAdapters
    module Redshift
      module OID # :nodoc:
        class Oid < Type::Integer # :nodoc:
          def type
            :oid
          end
        end
      end
    end
  end
end
