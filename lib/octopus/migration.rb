require "set"
require "active_support/core_ext/module/aliasing"
require "active_support/core_ext/array/wrap"

module Octopus::Migration
  module InstanceOrClassMethods
    def announce_with_octopus(message)
      announce_without_octopus("#{message} - #{get_current_shard}")
    end

    def get_current_shard
      "Shard: #{connection.current_shard}" if connection.respond_to?(:current_shard)
    end
  end

  include InstanceOrClassMethods

  def self.included(base)
    base.extend(ClassMethods)

    base.alias_method_chain :announce, :octopus
    base.class_attribute :current_shard, :current_group, :current_group_specified, :instance_reader => false, :instance_writer => false
  end

  module ClassMethods
    def using(*args)
      return self unless connection.is_a?(Octopus::Proxy)

      self.current_shard = args
      self
    end

    def using_group(*groups)
      return self unless connection.is_a?(Octopus::Proxy)

      self.current_group = groups
      self.current_group_specified = true
      self
    end

    def shards
      shards = Set.new

      if groups = (current_group_specified ? current_group : Octopus.config[:default_migration_group])
        Array.wrap(groups).each do |group|
          group_shards = connection.shards_for_group(group)
          shards.merge(group_shards) if group_shards
        end
      elsif shard = current_shard
        shards.merge(Array.wrap(shard))
      end

      shards.to_a.presence || [:master]
    end
  end
end

module Octopus::Migrator
  def self.included(base)
    base.extend(ClassMethods)

    base.class_eval do
      class << self
        alias_method_chain :migrate, :octopus
        alias_method_chain :up, :octopus
        alias_method_chain :down, :octopus
        alias_method_chain :run, :octopus
        alias_method_chain :migrations, :octopus
      end
    end

    base.alias_method_chain :run, :octopus
    base.alias_method_chain :migrate, :octopus
  end

  def run_with_octopus(&block)
    run_without_octopus(&block)
  rescue ActiveRecord::UnknownMigrationVersionError => e
    raise unless migrations(true).find {|m| m.version == e.version}
  end

  def migrate_with_octopus(&block)
    migrate_without_octopus(&block)
  rescue ActiveRecord::UnknownMigrationVersionError => e
    raise unless migrations(true).find {|m| m.version == e.version}
  end

  module ClassMethods

    def migrations_with_octopus(paths)
      connection = ActiveRecord::Base.connection
      migrations = migrations_without_octopus(paths)
      return migrations if !connection.is_a?(Octopus::Proxy)

      migrations.select {|m| m.shards.include?(connection.current_shard.to_sym)}
    end

    def migrate_with_octopus(migrations_paths, target_version = nil, &block)
      return migrate_without_octopus(migrations_paths, target_version, &block) unless connection.is_a?(Octopus::Proxy)

      connection.send_queries_to_multiple_shards(connection.shard_names) do
        migrate_without_octopus(migrations_paths, target_version, &block)
      end
    end

    def up_with_octopus(migrations_paths, target_version = nil, &block)
      return up_without_octopus(migrations_paths, target_version, &block) unless connection.is_a?(Octopus::Proxy)
      return up_without_octopus(migrations_paths, target_version, &block) unless connection.current_shard == :master

      connection.send_queries_to_multiple_shards(connection.shard_names) do
        up_without_octopus(migrations_paths, target_version, &block)
      end
    end

    def down_with_octopus(migrations_paths, target_version = nil, &block)
      return down_without_octopus(migrations_paths, target_version, &block) unless connection.is_a?(Octopus::Proxy)
      return down_without_octopus(migrations_paths, target_version, &block) unless connection.current_shard == :master

      connection.send_queries_to_multiple_shards(connection.shard_names) do
        down_without_octopus(migrations_paths, target_version, &block)
      end
    end

    def run_with_octopus(direction, migrations_paths, target_version)
      return run_without_octopus(direction, migrations_paths, target_version) unless connection.is_a?(Octopus::Proxy)

      connection.send_queries_to_multiple_shards(connection.shard_names) do
        run_without_octopus(direction, migrations_paths, target_version)
      end
    end

    private
    def connection
      ActiveRecord::Base.connection
    end
  end
end

module Octopus::MigrationProxy
  def shards
    migration.class.shards
  end
end

module Octopus::UnknownMigrationVersionError
  def self.included(base)
    base.alias_method_chain :initialize, :octopus
    base.send(:attr_accessor, :version)
  end

  def initialize_with_octopus(version)
    @version = version
    initialize_without_octopus(version)
  end
end

ActiveRecord::Migration.send(:include, Octopus::Migration)
ActiveRecord::Migrator.send(:include, Octopus::Migrator)
ActiveRecord::MigrationProxy.send(:include, Octopus::MigrationProxy)
ActiveRecord::UnknownMigrationVersionError.send(:include, Octopus::UnknownMigrationVersionError)
