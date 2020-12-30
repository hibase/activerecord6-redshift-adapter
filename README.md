activerecord6-redshift-adapter
==============================

Amazon Redshift adapter for ActiveRecord 6 (Rails 6).
I forked the project from https://github.com/ConsultingMD/activerecord5-redshift-adapter

Thanks for the auhors.

Usage
-------------------

For Rails 6, write following in Gemfile:

```ruby
gem 'activerecord6-redshift-adapter'
```

In database.yml

```YAML
development:
  adapter: redshift
  host: host
  port: port
  database: db
  username: user
  password: password
  encoding: utf8
```

OR your can use in URL
```ruby
class SomeModel < ApplicationRecord
  establish_connection('redshift://username:password@host/database')
end
```

License
---------

MIT license (same as ActiveRecord)
