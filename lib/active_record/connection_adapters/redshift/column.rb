module ActiveRecord
  module ConnectionAdapters
    class RedshiftColumn < Column #:nodoc:
      delegate :oid, :fmod, to: :sql_type_metadata

      attr_reader :primary_key, :redshift_distribution_key, :redshift_sort_key_order, :redshift_column_encoding

      def initialize(name, default, sql_type_metadata, null = true, table_name= nil, default_function = nil, is_primary_key = false, is_dist_key = false, sort_key_order = 0, col_encoding = nil)
        super name, default, sql_type_metadata, null, table_name, default_function, nil
        @primary_key = is_primary_key
        @redshift_distribution_key = is_dist_key
        @redshift_sort_key_order = sort_key_order if sort_key_order != '0'
        @redshift_column_encoding = col_encoding
      end
    end
  end
end
