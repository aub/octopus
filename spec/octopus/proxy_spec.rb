require "spec_helper"

describe Octopus::Proxy do
  let(:proxy) { subject }

  describe "creating a new instance", :shards => [] do
    it "should initialize all shards and groups" do
      # FIXME: Don't test implementation details
      proxy.shards.should include("canada", "brazil", "master", "sqlite_shard", "russia", "alone_shard",
                                                           "aug2009", "postgresql_shard", "aug2010", "aug2011")

      proxy.shards.should include("protocol_shard") if Octopus.rails_above_31?

      proxy.has_group?("country_shards").should be_true
      proxy.shards_for_group("country_shards").should include(:canada, :brazil, :russia)

      proxy.has_group?("history_shards").should be_true
      proxy.shards_for_group("history_shards").should include(:aug2009, :aug2010, :aug2011)
    end

    it "should initialize the block attribute as false" do
      proxy.block.should be_false
    end

    it "should initialize replicated attribute as false" do
      proxy.instance_variable_get(:@replicated).should be_false
    end

    it "should not verify connections for default" do
      proxy.verify_connection.should be_false
    end

    it "should work with thiking sphinx" do
      config = proxy.config
      config[:adapter].should == "mysql2"
      config[:database].should == "octopus_shard_1"
      config[:username].should == "root"
    end

    it 'should create a set with all adapters, to ensure that is needed to clean the table name.' do
      adapters = proxy.adapters
      adapters.should be_kind_of(Set)
      adapters.to_a.should =~ ["sqlite3", "mysql2", "postgresql"]
    end

    it 'should respond correctly to respond_to?(:pk_and_sequence_for)' do
      proxy.respond_to?(:pk_and_sequence_for).should be_true
    end

    it 'should respond correctly to respond_to?(:primary_key)' do
      proxy.respond_to?(:primary_key).should be_true
    end

    context 'when an adapter that modifies the config' do
      before(:all) { OctopusHelper.set_octopus_env("modify_config") }
      after(:all)  { OctopusHelper.set_octopus_env("octopus")       }

      it 'should not fail with missing adapter second time round' do
        pending "This test was actually failing because of a typo in the error message."
        Thread.current["octopus.current_shard"] = :modify_config_read

        lambda { Octopus::Proxy.new(Octopus.config()) }.should_not raise_error

        Thread.current["octopus.current_shard"] = nil
      end
    end

    describe "#should_clean_table_name?" do
      it 'should return true when you have a environment with multiple database types' do
        proxy.should_clean_table_name?.should be_true
      end

      context "when using a environment with a single table name" do
        before(:each) do
          OctopusHelper.set_octopus_env("production_replicated")
        end

        it 'should return false' do
          proxy.should_clean_table_name?.should be_false
        end
      end
    end

    describe "should raise error if you have duplicated shard names" do
      before(:each) do
        OctopusHelper.set_octopus_env("production_raise_error")
      end

      it "should raise the error" do
        lambda { proxy.shards }.should raise_error("You have duplicated shard names!")
      end
    end

    describe "should initialize just the master when you don't have a shards.yml file" do
      before(:each) do
        OctopusHelper.set_octopus_env("crazy_environment")
      end

      it "should initialize just the master shard" do
        proxy.shards.keys.should == ["master"]
      end

      it "should not initialize replication" do
        proxy.instance_variable_get(:@replicated).should be_nil
      end
    end
  end

  describe "when you have a replicated environment" do
    before(:each) do
      OctopusHelper.set_octopus_env("production_replicated")
    end

    it "should have the replicated attribute as true" do
      proxy.instance_variable_get(:@replicated).should be_true
    end

    it "should initialize the list of shards" do
      proxy.instance_variable_get(:@slaves_list).should == ["slave1", "slave2", "slave3", "slave4"]
    end
  end

  describe "when you have a rails application" do
    before(:each) do
      Rails = double()
      OctopusHelper.set_octopus_env("octopus_rails")
    end

    after(:each) do
      Object.send(:remove_const, :Rails)
      Octopus.instance_variable_set(:@config, nil)
      Octopus.instance_variable_set(:@rails_env, nil)
      OctopusHelper.clean_connection_proxy()
    end

    it "should initialize correctly octopus common variables for the environments" do
      Rails.stub(:env).and_return('staging')
      Octopus.instance_variable_set(:@rails_env, nil)
      Octopus.instance_variable_set(:@environments, nil)
      Octopus.config()

      proxy.instance_variable_get(:@replicated).should be_true
      proxy.verify_connection.should be_true
      Octopus.environments.should == ["staging", "production"]
    end

    it "should initialize correctly the shards for the staging environment" do
      Rails.stub(:env).and_return('staging')
      Octopus.instance_variable_set(:@rails_env, nil)
      Octopus.instance_variable_set(:@environments, nil)
      Octopus.config()

      proxy.shards.keys.to_set.should == Set.new(["slave1", "slave2", "master"])
    end

    it "should initialize correctly the shard octopus_shard value for logging" do
      Rails.stub(:env).and_return('staging')
      Octopus.instance_variable_set(:@rails_env, nil)
      Octopus.instance_variable_set(:@environments, nil)
      Octopus.config()

      proxy.shards['slave1'].spec.config.should have_key :octopus_shard
    end

    it "should initialize correctly the shards for the production environment" do
      Rails.stub(:env).and_return('production')
      Octopus.instance_variable_set(:@rails_env, nil)
      Octopus.instance_variable_set(:@environments, nil)
      Octopus.config()

      proxy.shards.keys.to_set.should == Set.new(["slave3", "slave4", "master"])
    end

    describe "using the master connection", :shards => [:russia, :master]  do
      before(:each) do
        Rails.stub(:env).and_return('development')
      end

      it "should use the master connection" do
        user = User.create!(:name =>"Thiago")
        user.name = "New Thiago"
        user.save()
        User.find_by_name("New Thiago").should_not be_nil
      end

      it "should work when using using syntax" do
        user = User.using(:russia).create!(:name =>"Thiago")

        user.name = "New Thiago"
        user.save()

        User.using(:russia).find_by_name("New Thiago").should == user
        User.find_by_name("New Thiago").should == user
      end

      it "should work when using blocks" do
        Octopus.using(:russia) do
          @user = User.create!(:name =>"Thiago")
        end

        User.find_by_name("Thiago").should == @user
      end

      it "should work with associations" do
        u = Client.create!(:name => "Thiago")
        i = Item.create(:name => "Item")
        u.items << i
        u.save()
      end
    end
  end

  describe "returning the correct connection" do
    describe "should return the shard name" do
      it "when current_shard is empty" do
        proxy.shard_name.should == :master
      end

      it "when current_shard is a single shard" do
        proxy.current_shard = :canada
        proxy.shard_name.should == :canada
      end

      it "when current_shard is more than one shard" do
        proxy.current_shard = [:russia, :brazil]
        proxy.shard_name.should == :russia
      end
    end

    describe "should return the connection based on shard_name" do
      it "when current_shard is empty" do
        proxy.select_connection().should == proxy.shards[:master].connection()
      end

      it "when current_shard is a single shard" do
        proxy.current_shard = :canada
        proxy.select_connection().should == proxy.shards[:canada].connection()
      end
    end
  end
end
