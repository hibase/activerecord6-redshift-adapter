require 'active_record/connection_adapters/abstract_adapter'
require 'active_record/connection_adapters/statement_pool'

require 'active_record/connection_adapters/redshift/utils'
require 'active_record/connection_adapters/redshift/column'
require 'active_record/connection_adapters/redshift/oid'
require 'active_record/connection_adapters/redshift/quoting'
require 'active_record/connection_adapters/redshift/referential_integrity'
require 'active_record/connection_adapters/redshift/schema_definitions'
require 'active_record/connection_adapters/redshift/schema_dumper'
require 'active_record/connection_adapters/redshift/schema_statements'
require 'active_record/connection_adapters/redshift/type_metadata'
require 'active_record/connection_adapters/redshift/database_statements'
require 'active_record/tasks/redshift_database_tasks'

require 'pg'

require 'ipaddr'

module PG
  class Connection
    class << self
      alias :orig_parse_connect_args :parse_connect_args
    end

    # We patch the original PG method in order
    # to delete the fallback_application_name
    # argument, which is otherwise always added
    def self::parse_connect_args( *args )
      parsed_args = orig_parse_connect_args(*args)

      if parsed_args.include? "remove_application_name='true'"
        parsed_args = parsed_args.gsub("remove_application_name='true'", "").gsub(/fallback_application_name='.*?'/, '').squish
      end

      parsed_args
    end
  end
end

ActiveRecord::Tasks::DatabaseTasks.register_task(/redshift/, "ActiveRecord::Tasks::PostgreSQLDatabaseTasks")

module ActiveRecord
  module ConnectionHandling # :nodoc:
    RS_VALID_CONN_PARAMS = [:host, :hostaddr, :port, :dbname, :user, :password, :connect_timeout,
                         :client_encoding, :options, # :application_name, :fallback_application_name,
                         :keepalives, :keepalives_idle, :keepalives_interval, :keepalives_count,
                         :tty, :sslmode, :requiressl, :sslcompression, :sslcert, :sslkey,
                         :sslrootcert, :sslcrl, :requirepeer, :krbsrvname, :gsslib, :service]

    # Establishes a connection to the database that's used by all Active Record objects
    def redshift_connection(config)
      conn_params = config.symbolize_keys.compact

      # Map ActiveRecords param names to PGs.
      conn_params[:user] = conn_params.delete(:username) if conn_params[:username]
      conn_params[:dbname] = conn_params.delete(:database) if conn_params[:database]

      # Forward only valid config params to PG::Connection.connect.
      conn_params.keep_if { |k, _| RS_VALID_CONN_PARAMS.include?(k) }

      # The postgres drivers don't allow the creation of an unconnected PG::Connection object,
      # so just pass a nil connection object for the time being.
      ConnectionAdapters::RedshiftAdapter.new(nil, logger, conn_params, config)
    end
  end

  module ConnectionAdapters
    # The PostgreSQL adapter works with the native C (https://bitbucket.org/ged/ruby-pg) driver.
    #
    # Options:
    #
    # * <tt>:host</tt> - Defaults to a Unix-domain socket in /tmp. On machines without Unix-domain sockets,
    #   the default is to connect to localhost.
    # * <tt>:port</tt> - Defaults to 5432.
    # * <tt>:username</tt> - Defaults to be the same as the operating system name of the user running the application.
    # * <tt>:password</tt> - Password to be used if the server demands password authentication.
    # * <tt>:database</tt> - Defaults to be the same as the user name.
    # * <tt>:schema_search_path</tt> - An optional schema search path for the connection given
    #   as a string of comma-separated schema names. This is backward-compatible with the <tt>:schema_order</tt> option.
    # * <tt>:encoding</tt> - An optional client encoding that is used in a <tt>SET client_encoding TO
    #   <encoding></tt> call on the connection.
    # * <tt>:min_messages</tt> - An optional client min messages that is used in a
    #   <tt>SET client_min_messages TO <min_messages></tt> call on the connection.
    # * <tt>:variables</tt> - An optional hash of additional parameters that
    #   will be used in <tt>SET SESSION key = val</tt> calls on the connection.
    # * <tt>:insert_returning</tt> - Does nothing for Redshift.
    #
    # Any further options are used as connection parameters to libpq. See
    # http://www.postgresql.org/docs/9.1/static/libpq-connect.html for the
    # list of parameters.
    #
    # In addition, default connection parameters of libpq can be set per environment variables.
    # See http://www.postgresql.org/docs/9.1/static/libpq-envars.html .
    class RedshiftAdapter < AbstractAdapter
      ADAPTER_NAME = 'Redshift'.freeze

      NATIVE_DATABASE_TYPES = {
        primary_key: "integer primary key",
        identity:    "integer identity primary key",
        string:      { name: "varchar" },
        text:        { name: "varchar", limit: 65535 },
        integer:     { name: "integer" },
        float:       { name: "decimal" },
        decimal:     { name: "decimal" },
        datetime:    { name: "timestamp" },
        time:        { name: "timestamp" },
        date:        { name: "date" },
        bigint:      { name: "bigint" },
        smallint:    { name: "smallint" },
        boolean:     { name: "boolean" },
      }

      MOCK_DATABASE_TYPES = {
        identity: "integer primary key"
      }

      OID = Redshift::OID #:nodoc:

      include Redshift::Quoting
      include Redshift::ReferentialIntegrity
      include Redshift::SchemaStatements
      include Redshift::DatabaseStatements

      def schema_creation # :nodoc:
        Redshift::SchemaCreation.new self
      end

      def supports_index_sort_order?
        false
      end

      def supports_partial_index?
        false
      end

      def supports_transaction_isolation?
        false
      end

      def supports_foreign_keys?
        true
      end

      def supports_views?
        true
      end

      def index_algorithms
        { concurrently: 'CONCURRENTLY' }
      end

      class StatementPool < ConnectionAdapters::StatementPool # :nodoc:
        def initialize(connection, max)
          super(max)
          @connection = connection
          @counter = 0
        end

        def next_key
          "a#{@counter + 1}"
        end

        def []=(sql, key)
          super.tap { @counter += 1 }
        end

        private
          def dealloc(key)
            @connection.query "DEALLOCATE #{key}" if connection_active?
          rescue PG::Error
          end

          def connection_active?
            @connection.status == PG::CONNECTION_OK
          rescue PG::Error
            false
          end
      end

      # Initializes and connects a PostgreSQL adapter.
      def initialize(connection, logger, connection_parameters, config)
        super(connection, logger, config)

        @visitor = Arel::Visitors::PostgreSQL.new self
        @visitor.extend(ConnectionAdapters::DetermineIfPreparableVisitor)
        @prepared_statements = false

        @connection_parameters = connection_parameters

        # @local_tz is initialized as nil to avoid warnings when connect tries to use it
        @local_tz = nil
        @table_alias_length = nil

        connect
        add_pg_encoders
        @statements = StatementPool.new @connection,
                                        self.class.type_cast_config_to_integer(config[:statement_limit])

        add_pg_decoders

        @type_map = Type::HashLookupTypeMap.new
        initialize_type_map
        @local_tz = execute('SHOW TIME ZONE', 'SCHEMA').first["TimeZone"]
        @use_insert_returning = @config.key?(:insert_returning) ? self.class.type_cast_config_to_boolean(@config[:insert_returning]) : false

        @sql_type_to_oid = {}
      end

      # Clears the prepared statements cache.
      def clear_cache!
        @statements.clear
      end

      def truncate(table_name, name = nil)
        exec_query "TRUNCATE TABLE #{quote_table_name(table_name)}", name, []
      end

      # Is this connection alive and ready for queries?
      def active?
        @connection.query 'SELECT 1'
        true
      rescue PG::Error
        false
      end

      # Close then reopen the connection.
      def reconnect!
        super
        @connection.reset
        configure_connection
      end

      def reset!
        clear_cache!
        reset_transaction
        unless @connection.transaction_status == ::PG::PQTRANS_IDLE
          @connection.query 'ROLLBACK'
        end
        # @connection.query 'DISCARD ALL'
        session_auth = 'DEFAULT'
        @connection.query 'RESET ALL'
        @statements.clear if @statements

        configure_connection
      end

      # Disconnects from the database if already connected. Otherwise, this
      # method does nothing.
      def disconnect!
        super
        @connection.close rescue nil
      end

      def native_database_types #:nodoc:
        NATIVE_DATABASE_TYPES.merge(@config[:mock] ? MOCK_DATABASE_TYPES : {})
      end

      # Returns true, since this connection adapter supports migrations.
      def supports_migrations?
        true
      end

      # Does PostgreSQL support finding primary key on non-Active Record tables?
      def supports_primary_key? #:nodoc:
        true
      end

      def supports_ddl_transactions?
        true
      end

      def supports_explain?
        true
      end

      def supports_extensions?
        false
      end

      def supports_ranges?
        false
      end

      def supports_materialized_views?
        false
      end

      def supports_import?
        true
      end

      def enable_extension(name)
      end

      def disable_extension(name)
      end

      def extension_enabled?(name)
        false
      end

      # Returns the configured supported identifier length supported by PostgreSQL
      def table_alias_length
        @table_alias_length ||= query('SHOW max_identifier_length', 'SCHEMA')[0][0].to_i
      end

      # Set the authorized user for this session
      def session_auth=(user)
        clear_cache!
        exec_query "SET SESSION AUTHORIZATION #{user}"
      end

      def use_insert_returning?
        false
      end

      def valid_type?(type)
        !native_database_types[type].nil?
      end

      def update_table_definition(table_name, base) #:nodoc:
        Redshift::Table.new(table_name, base)
      end

      def lookup_cast_type(sql_type) # :nodoc:
        oid = (@sql_type_to_oid[sql_type] ||= execute("SELECT #{quote(sql_type)}::regtype::oid", "SCHEMA").first['oid'].to_i)
        super(oid)
      end

      def column_name_for_operation(operation, node) # :nodoc:
        OPERATION_ALIASES.fetch(operation) { operation.downcase }
      end

      OPERATION_ALIASES = { # :nodoc:
        "maximum" => "max",
        "minimum" => "min",
        "average" => "avg",
      }

      protected

        # Returns the version of the connected PostgreSQL server.
        def redshift_version
          @connection.server_version
        end

      private
        # See https://www.postgresql.org/docs/8.0/static/errcodes-appendix.html
        VALUE_LIMIT_VIOLATION = "22001"
        NUMERIC_VALUE_OUT_OF_RANGE = "22003"
        NOT_NULL_VIOLATION    = "23502"
        FOREIGN_KEY_VIOLATION = "23503"
        UNIQUE_VIOLATION      = "23505"
        SERIALIZATION_FAILURE = "40001"
        DEADLOCK_DETECTED     = "40P01"
        LOCK_NOT_AVAILABLE    = "55P03"
        QUERY_CANCELED        = "57014"

        def translate_exception(exception, message:, sql:, binds:)
          return exception unless exception.respond_to?(:result)

          case exception.result.try(:error_field, PG::PG_DIAG_SQLSTATE)
          when UNIQUE_VIOLATION
            RecordNotUnique.new(message)
          when FOREIGN_KEY_VIOLATION
            InvalidForeignKey.new(message)
          when VALUE_LIMIT_VIOLATION
            ValueTooLong.new(message)
          when NUMERIC_VALUE_OUT_OF_RANGE
            RangeError.new(message)
          when NOT_NULL_VIOLATION
            NotNullViolation.new(message)
          when SERIALIZATION_FAILURE
            SerializationFailure.new(message)
          when DEADLOCK_DETECTED
            Deadlocked.new(message)
          when LOCK_NOT_AVAILABLE
            LockWaitTimeout.new(message)
          when QUERY_CANCELED
            QueryCanceled.new(message)
          else
            super
          end
        end

        def get_oid_type(oid, fmod, column_name, sql_type = '') # :nodoc:
          if !type_map.key?(oid)
            load_additional_types(type_map, [oid])
          end

          type_map.fetch(oid, fmod, sql_type) {
            warn "unknown OID #{oid}: failed to recognize type of '#{column_name}'. It will be treated as String."
            Type::Value.new.tap do |cast_type|
              type_map.register_type(oid, cast_type)
            end
          }
        end

        def initialize_type_map(m=type_map) # :nodoc:
          m.register_type "int2", Type::Integer.new(limit: 2)
          m.register_type "int4", Type::Integer.new(limit: 4)
          m.register_type "int8", Type::Integer.new(limit: 8)
          m.register_type "oid", OID::Oid.new
          m.register_type 'float4', Type::Float.new
          m.alias_type 'float8', 'float4'
          m.register_type 'text', Type::Text.new
          register_class_with_limit m, 'varchar', Type::String
          m.alias_type 'char', 'varchar'
          m.alias_type 'name', 'varchar'
          m.alias_type 'bpchar', 'varchar'
          m.register_type 'bool', Type::Boolean.new
          m.alias_type 'timestamptz', 'timestamp'
          m.register_type 'date', Type::Date.new
          m.register_type 'time', Type::Time.new
          m.alias_type 2205, 'varchar'

          m.register_type 'timestamp' do |_, _, sql_type|
            precision = extract_precision(sql_type)
            OID::DateTime.new(precision: precision)
          end

          m.register_type 'numeric' do |_, fmod, sql_type|
            precision = extract_precision(sql_type)
            scale = extract_scale(sql_type)

            # The type for the numeric depends on the width of the field,
            # so we'll do something special here.
            #
            # When dealing with decimal columns:
            #
            # places after decimal  = fmod - 4 & 0xffff
            # places before decimal = (fmod - 4) >> 16 & 0xffff
            if fmod && (fmod - 4 & 0xffff).zero?
              # FIXME: Remove this class, and the second argument to
              # lookups on PG
              Type::DecimalWithoutScale.new(precision: precision)
            else
              OID::Decimal.new(precision: precision, scale: scale)
            end
          end

          load_additional_types(m)
        end

        def extract_limit(sql_type) # :nodoc:
          case sql_type
          when /^bigint/i, /^int8/i
            8
          when /^smallint/i
            2
          else
            super
          end
        end

        # Extracts the value from a PostgreSQL column default definition.
        def extract_value_from_default(default)
          case default
            # Quoted types
          when /\A[\(B]?'(.*)'.*::"?([\w. ]+)"?(?:\[\])?\z/m
            # The default 'now'::date is CURRENT_DATE
            if $1 == "now".freeze && $2 == "date".freeze
              nil
            else
              $1.gsub("''".freeze, "'".freeze)
            end
            # Boolean types
          when "true".freeze, "false".freeze
            default
            # Numeric types
          when /\A\(?(-?\d+(\.\d*)?)\)?(::bigint)?\z/
            $1
            # Object identifier types
          when /\A-?\d+\z/
            $1
          else
            # Anything else is blank, some user type, or some function
            # and we can't know the value of that, so return nil.
            nil
          end
        end

        def extract_default_function(default_value, default) # :nodoc:
          default if has_default_function?(default_value, default)
        end

        def has_default_function?(default_value, default) # :nodoc:
          !default_value && %r{\w+\(.*\)|\(.*\)::\w+|CURRENT_DATE|CURRENT_TIMESTAMP}.match?(default)
        end

        def load_additional_types(type_map, oids = nil) # :nodoc:
          initializer = OID::TypeMapInitializer.new(type_map)

          if supports_ranges?
            query = <<-SQL
              SELECT t.oid, t.typname, t.typelem, t.typdelim, t.typinput, r.rngsubtype, t.typtype, t.typbasetype
              FROM pg_type as t
              LEFT JOIN pg_range as r ON oid = rngtypid
            SQL
          else
            query = <<-SQL
              SELECT t.oid, t.typname, t.typelem, t.typdelim, t.typinput, t.typtype, t.typbasetype
              FROM pg_type as t
            SQL
          end

          if oids
            query += "WHERE t.oid::integer IN (%s)" % oids.join(", ")
          end

          execute_and_clear(query, 'SCHEMA', []) do |records|
            initializer.run(records)
          end
        end

        FEATURE_NOT_SUPPORTED = "0A000" #:nodoc:

        def execute_and_clear(sql, name, binds, prepare: false)
          if without_prepared_statement?(binds)
            result = exec_no_cache(sql, name, [])
          elsif !prepare
            result = exec_no_cache(sql, name, binds)
          else
            result = exec_cache(sql, name, binds)
          end
          ret = yield result
          result.clear
          ret
        end


        def exec_no_cache(sql, name, binds)
          materialize_transactions

          # make sure we carry over any changes to ActiveRecord::Base.default_timezone that have been
          # made since we established the connection
          update_typemap_for_default_timezone

          type_casted_binds = type_casted_binds(binds)
          log(sql, name, binds, type_casted_binds) do
            ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
              @connection.exec_params(sql, type_casted_binds)
            end
          end
        end

        def exec_cache(sql, name, binds)
          materialize_transactions
          update_typemap_for_default_timezone

          stmt_key = prepare_statement(sql, binds)
          type_casted_binds = type_casted_binds(binds)

          log(sql, name, binds, type_casted_binds, stmt_key) do
            ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
              @connection.exec_prepared(stmt_key, type_casted_binds)
            end
          end
        rescue ActiveRecord::StatementInvalid => e
          raise unless is_cached_plan_failure?(e)

          # Nothing we can do if we are in a transaction because all commands
          # will raise InFailedSQLTransaction
          if in_transaction?
            raise ActiveRecord::PreparedStatementCacheExpired.new(e.cause.message)
          else
            @lock.synchronize do
              # outside of transactions we can simply flush this query and retry
              @statements.delete sql_key(sql)
            end
            retry
          end
        end

        # Annoyingly, the code for prepared statements whose return value may
        # have changed is FEATURE_NOT_SUPPORTED.
        #
        # This covers various different error types so we need to do additional
        # work to classify the exception definitively as a
        # ActiveRecord::PreparedStatementCacheExpired
        #
        # Check here for more details:
        # https://git.postgresql.org/gitweb/?p=postgresql.git;a=blob;f=src/backend/utils/cache/plancache.c#l573
        CACHED_PLAN_HEURISTIC = "cached plan must not change result type"
        def is_cached_plan_failure?(e)
          pgerror = e.cause
          code = pgerror.result.result_error_field(PG::PG_DIAG_SQLSTATE)
          code == FEATURE_NOT_SUPPORTED && pgerror.message.include?(CACHED_PLAN_HEURISTIC)
        rescue
          false
        end

        # Returns the statement identifier for the client side cache
        # of statements
        def sql_key(sql)
          "#{schema_search_path}-#{sql}"
        end

        # Prepare the statement if it hasn't been prepared, return
        # the statement key.
        def prepare_statement(sql, binds)
          @lock.synchronize do
            sql_key = sql_key(sql)
            unless @statements.key? sql_key
              nextkey = @statements.next_key
              begin
                @connection.prepare nextkey, sql
              rescue => e
                raise translate_exception_class(e, sql, binds)
              end
              # Clear the queue
              @connection.get_last_result
              @statements[sql_key] = nextkey
            end
            @statements[sql_key]
          end
        end

        # Connects to a PostgreSQL server and sets up the adapter depending on the
        # connected server's characteristics.
        def connect
          @connection = PG.connect(@connection_parameters)
          configure_connection
          add_pg_encoders
          add_pg_decoders
        rescue ::PG::Error => error
          if error.message.include?("does not exist")
            raise ActiveRecord::NoDatabaseError.new(error.message)
          else
            raise
          end
        end

        # Configures the encoding, verbosity, schema search path, and time zone of the connection.
        # This is called by #connect and should not be called manually.
        def configure_connection
          if @config[:encoding]
            @connection.set_client_encoding(@config[:encoding])
          end
          self.client_min_messages = @config[:min_messages] || "warning"
          self.schema_search_path = @config[:schema_search_path] || @config[:schema_order]

          # Use standard-conforming strings so we don't have to do the E'...' dance.
          # set_standard_conforming_strings
          variables = @config.fetch(:variables, {}).stringify_keys

          # If using Active Record's time zone support configure the connection to return
          # TIMESTAMP WITH ZONE types in UTC.
          unless variables["timezone"]
            if ActiveRecord::Base.default_timezone == :utc
              variables["timezone"] = "UTC"
            elsif @local_tz
              variables["timezone"] = @local_tz
            end
          end

          # SET statements from :variables config hash
          # http://www.postgresql.org/docs/8.3/static/sql-set.html
          variables.map do |k, v|
            if v == ':default' || v == :default
              # Sets the value to the global or compile default
              execute("SET #{k} TO DEFAULT", 'SCHEMA')
            elsif !v.nil?
              execute("SET #{k} TO #{quote(v)}", 'SCHEMA')
            end
          end
        end

        def last_insert_id_result(sequence_name) #:nodoc:
          exec_query("SELECT currval('#{sequence_name}')", 'SQL')
        end

        # Returns the list of a table's column names, data types, and default values.
        #
        # The underlying query is roughly:
        #  SELECT column.name, column.type, default.value
        #    FROM column LEFT JOIN default
        #      ON column.table_id = default.table_id
        #     AND column.num = default.column_num
        #   WHERE column.table_id = get_table_id('table_name')
        #     AND column.num > 0
        #     AND NOT column.is_dropped
        #   ORDER BY column.num
        #
        # If the table name is not prefixed with a schema, the database will
        # take the first match from the schema search path.
        #
        # Query implementation notes:
        #  - format_type includes the column size constraint, e.g. varchar(50)
        #  - ::regclass is a function that gives the id for a table name

        # Edited to include attisdistkey and attsortkeyord
        # https://github.com/awslabs/amazon-redshift-utils/blob/master/src/AdminViews/v_generate_tbl_ddl.sql
        def column_definitions(table_name) # :nodoc:
          query(<<-end_sql, 'SCHEMA')
              SELECT a.attname, format_type(a.atttypid, a.atttypmod),
                     pg_get_expr(d.adbin, d.adrelid), a.attnotnull, a.atttypid, a.atttypmod,
                     CASE WHEN pk.conrelid IS NULL THEN false ELSE true END AS is_primary_key,
                     a.attnum AS column_index,
                     CASE WHEN pk.conrelid IS NULL THEN NULL ELSE pk.conkey END AS primary_key_order,
                     #{@config[:mock] ? 'null, null' : 'attisdistkey, attsortkeyord'},
                     CASE WHEN #{@config[:mock] ? '\'none\'' : 'format_encoding((a.attencodingtype)::integer)'} = 'none'
                     THEN NULL
                     ELSE #{@config[:mock] ? 'null' : 'format_encoding((a.attencodingtype)::integer)'}
                     END AS col_encoding

              FROM pg_attribute a
                LEFT JOIN pg_attrdef d ON a.attrelid = d.adrelid AND a.attnum = d.adnum
                LEFT JOIN pg_constraint pk ON pk.contype = 'p' AND a.attrelid = pk.conrelid AND a.attnum = any(pk.conkey)

               WHERE a.attrelid = '#{quote_table_name(table_name)}'::regclass
                 AND a.attnum > 0 AND NOT a.attisdropped

               ORDER BY a.attnum
          end_sql

          # Alternative solution
          # query(<<-end_sql, 'SCHEMA')
          #     SELECT a.attname, format_type(a.atttypid, a.atttypmod),
          #            pg_get_expr(d.adbin, d.adrelid), a.attnotnull, a.atttypid, a.atttypmod,
          #            pk.indisprimary as is_primary_key,
          #            attisdistkey, attsortkeyord,
          #            CASE WHEN format_encoding((a.attencodingtype)::integer) = 'none'
          #            THEN NULL
          #            ELSE format_encoding((a.attencodingtype)::integer)
          #            END AS col_encoding

          #     FROM pg_attribute a
          #       LEFT JOIN pg_attrdef d ON a.attrelid = d.adrelid AND a.attnum = d.adnum
          #       LEFT JOIN (
          #         SELECT pg_index.indisprimary,
          #           pg_index.indrelid,
          #           string_to_array(textin(int2vectorout(pg_index.indkey)), ' ') AS indkey
          #         FROM pg_index
          #         WHERE pg_index.indisprimary
          #       ) pk ON a.attrelid = pk.indrelid AND a.attnum = ANY(pk.indkey)

          #      WHERE a.attrelid = '#{quote_table_name(table_name)}'::regclass
          #        AND a.attnum > 0 AND NOT a.attisdropped

          #      ORDER BY a.attnum
          # end_sql
        end

        def extract_table_ref_from_insert_sql(sql)
          sql[/into\s("[A-Za-z0-9_."\[\]\s]+"|[A-Za-z0-9_."\[\]]+)\s*/im]
          $1.strip if $1
        end

        def arel_visitor
          Arel::Visitors::PostgreSQL.new(self)
        end

        def build_statement_pool
          StatementPool.new(@connection, self.class.type_cast_config_to_integer(@config[:statement_limit]))
        end


        def can_perform_case_insensitive_comparison_for?(column)
          @case_insensitive_cache ||= {}
          @case_insensitive_cache[column.sql_type] ||= begin
            sql = <<~SQL
              SELECT exists(
                SELECT * FROM pg_proc
                WHERE proname = 'lower'
                  AND proargtypes = ARRAY[#{quote column.sql_type}::regtype]::oidvector
              ) OR exists(
                SELECT * FROM pg_proc
                INNER JOIN pg_cast
                  ON ARRAY[casttarget]::oidvector = proargtypes
                WHERE proname = 'lower'
                  AND castsource = #{quote column.sql_type}::regtype
              )
            SQL
            execute_and_clear(sql, "SCHEMA", []) do |result|
              result.getvalue(0, 0)
            end
          end
        end

        def add_pg_encoders
          map = PG::TypeMapByClass.new
          map[Integer] = PG::TextEncoder::Integer.new
          map[TrueClass] = PG::TextEncoder::Boolean.new
          map[FalseClass] = PG::TextEncoder::Boolean.new
          @connection.type_map_for_queries = map
        end

        def update_typemap_for_default_timezone
          if @default_timezone != ActiveRecord::Base.default_timezone && @timestamp_decoder
            decoder_class = ActiveRecord::Base.default_timezone == :utc ?
              PG::TextDecoder::TimestampUtc :
              PG::TextDecoder::TimestampWithoutTimeZone

            @timestamp_decoder = decoder_class.new(@timestamp_decoder.to_h)
            @connection.type_map_for_results.add_coder(@timestamp_decoder)
            @default_timezone = ActiveRecord::Base.default_timezone
          end
        end


        def add_pg_decoders
          @default_timezone = nil
          @timestamp_decoder = nil

          coders_by_name = {
            "int2" => PG::TextDecoder::Integer,
            "int4" => PG::TextDecoder::Integer,
            "int8" => PG::TextDecoder::Integer,
            "oid" => PG::TextDecoder::Integer,
            "float4" => PG::TextDecoder::Float,
            "float8" => PG::TextDecoder::Float,
            "json" => PG::TextDecoder::JSON,
            "bool" => PG::TextDecoder::Boolean,
          }

          if defined?(PG::TextDecoder::TimestampUtc)
            # Use native PG encoders available since pg-1.1
            coders_by_name["timestamp"] = PG::TextDecoder::TimestampUtc
            coders_by_name["timestamptz"] = PG::TextDecoder::TimestampWithTimeZone
          end

          known_coder_types = coders_by_name.keys.map { |n| quote(n) }
          query = <<~SQL % known_coder_types.join(", ")
            SELECT t.oid, t.typname
            FROM pg_type as t
            WHERE t.typname IN (%s)
          SQL
          coders = execute_and_clear(query, "SCHEMA", []) do |result|
            result
              .map { |row| construct_coder(row, coders_by_name[row["typname"]]) }
              .compact
          end

          map = PG::TypeMapByOid.new
          coders.each { |coder| map.add_coder(coder) }
          @connection.type_map_for_results = map

          # extract timestamp decoder for use in update_typemap_for_default_timezone
          @timestamp_decoder = coders.find { |coder| coder.name == "timestamp" }
          update_typemap_for_default_timezone
        end

        def construct_coder(row, coder_class)
          return unless coder_class
          coder_class.new(oid: row["oid"].to_i, name: row["typname"])
        end

        def create_table_definition(*args) # :nodoc:
          Redshift::TableDefinition.new(self, *args)
        end

        def add_pg_encoders
          map = PG::TypeMapByClass.new
          map[Integer] = PG::TextEncoder::Integer.new
          map[TrueClass] = PG::TextEncoder::Boolean.new
          map[FalseClass] = PG::TextEncoder::Boolean.new
          @connection.type_map_for_queries = map
        end

        def add_pg_decoders
          coders_by_name = {
            "int2" => PG::TextDecoder::Integer,
            "int4" => PG::TextDecoder::Integer,
            "int8" => PG::TextDecoder::Integer,
            "oid" => PG::TextDecoder::Integer,
            "float4" => PG::TextDecoder::Float,
            "float8" => PG::TextDecoder::Float,
            "bool" => PG::TextDecoder::Boolean,
          }
          known_coder_types = coders_by_name.keys.map { |n| quote(n) }
          query = <<-SQL % known_coder_types.join(", ")
            SELECT t.oid, t.typname
            FROM pg_type as t
            WHERE t.typname IN (%s)
          SQL
          coders = execute_and_clear(query, "SCHEMA", []) do |result|
            result
              .map { |row| construct_coder(row, coders_by_name[row["typname"]]) }
              .compact
          end

          map = PG::TypeMapByOid.new
          coders.each { |coder| map.add_coder(coder) }
          @connection.type_map_for_results = map
        end

        def construct_coder(row, coder_class)
          return unless coder_class
          coder_class.new(oid: row["oid"].to_i, name: row["typname"])
        end

        ActiveRecord::Type.register(:datetime, OID::DateTime, adapter: :redshift)
        ActiveRecord::Type.register(:decimal, OID::Decimal, adapter: :redshift)
        ActiveRecord::Type.register(:json, OID::Json, adapter: :redshift)
        ActiveRecord::Type.register(:jsonb, OID::Jsonb, adapter: :redshift)
    end
  end
end
