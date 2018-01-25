require "cases/helper"

class SqlTypesTest < ActiveRecord::TestCase
  def test_binary_types
    assert_equal 'varbinary(64)', type_to_sql(:binary, limit: 64)
    assert_equal 'varbinary(4095)', type_to_sql(:binary, limit: 4095)
    assert_equal 'blob(4096)', type_to_sql(:binary, limit: 4096)
    assert_equal 'blob', type_to_sql(:binary)
  end

  def type_to_sql(*args, **named_args)
    ActiveRecord::Base.connection.type_to_sql(*args, **named_args)
  end
end
