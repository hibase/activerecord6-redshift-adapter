module ActiveRecord
  module ConnectionAdapters
    class RedshiftColumn < Column #:nodoc:
      delegate :oid, :fmod, to: :sql_type_metadata
      attr_reader :primary_key, :primary_key_index, :redshift_distribution_key, :redshift_sort_key_order, :redshift_column_encoding

      def initialize(name, default, sql_type_metadata, null = true, default_function = nil, is_primary_key = false, column_index = nil, primary_key_order = nil, is_dist_key = false, sort_key_order = 0, col_encoding = nil)
        super name, default, sql_type_metadata, null, default_function
        @primary_key = is_primary_key
        if is_primary_key && primary_key_order
          # ~5x faster than converting to 
          # array and calling index()
          @primary_key_index = primary_key_order.split("#{column_index}")[0].count(',')
        end
        @redshift_distribution_key = is_dist_key
        @redshift_sort_key_order = sort_key_order if sort_key_order != '0'
        @redshift_column_encoding = col_encoding
      end
    end
  end
end
