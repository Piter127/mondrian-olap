require "spec_helper"

describe "Cube" do
  before(:all) do
    @schema = Mondrian::OLAP::Schema.define do
      measures_caption 'Measures caption'

      cube 'Sales' do
        description 'Sales description'
        caption 'Sales caption'
        annotations :foo => 'bar'
        table 'sales'
        visible true
        dimension 'Gender', :foreign_key => 'customer_id' do
          description 'Gender description'
          caption 'Gender caption'
          visible true
          hierarchy :has_all => true, :primary_key => 'id' do
            description 'Gender hierarchy description'
            caption 'Gender hierarchy caption'
            all_member_name 'All Genders'
            all_member_caption 'All Genders caption'
            table 'customers'
            visible true
            level 'Gender', :column => 'gender', :unique_members => true,
                            :description => 'Gender level description', :caption => 'Gender level caption' do
              visible true
              # Dimension values SQL generated by caption_expression fails on PostgreSQL and MS SQL
              if %w(mysql oracle).include?(MONDRIAN_DRIVER)
                caption_expression do
                  sql "'dummy'"
                end
              end
            end
          end
        end
        dimension 'Customers', :foreign_key => 'customer_id', :annotations => {:foo => 'bar'} do
          hierarchy :has_all => true, :all_member_name => 'All Customers', :primary_key => 'id', :annotations => {:foo => 'bar'} do
            table 'customers'
            level 'Country', :column => 'country', :unique_members => true, :annotations => {:foo => 'bar'}
            level 'State Province', :column => 'state_province', :unique_members => true
            level 'City', :column => 'city', :unique_members => false
            level 'Name', :column => 'fullname', :unique_members => true
          end
        end
        calculated_member 'Non-USA', :annotations => {:foo => 'bar'} do
          dimension 'Customers'
          formula '[Customers].[All Customers] - [Customers].[USA]'
        end
        dimension 'Time', :foreign_key => 'time_id', :type => 'TimeDimension' do
          hierarchy :has_all => false, :primary_key => 'id' do
            table 'time'
            level 'Year', :column => 'the_year', :type => 'Numeric', :unique_members => true, :level_type => 'TimeYears'
            level 'Quarter', :column => 'quarter', :unique_members => false, :level_type => 'TimeQuarters'
            level 'Month', :column => 'month_of_year', :type => 'Numeric', :unique_members => false, :level_type => 'TimeMonths'
          end
          hierarchy 'Weekly', :has_all => false, :primary_key => 'id' do
            table 'time'
            level 'Year', :column => 'the_year', :type => 'Numeric', :unique_members => true, :level_type => 'TimeYears'
            level 'Week', :column => 'weak_of_year', :type => 'Numeric', :unique_members => false, :level_type => 'TimeWeeks'
          end
        end
        calculated_member 'Last week' do
          hierarchy '[Time.Weekly]'
          formula 'Tail([Time.Weekly].[Week].Members).Item(0)'
        end
        measure 'Unit Sales', :column => 'unit_sales', :aggregator => 'sum', :annotations => {:foo => 'bar'}
        measure 'Store Sales', :column => 'store_sales', :aggregator => 'sum'
        measure 'Store Cost', :column => 'store_cost', :aggregator => 'sum', :visible => false
      end
    end
    @olap = Mondrian::OLAP::Connection.create(CONNECTION_PARAMS.merge :schema => @schema)
  end

  describe 'cache', unless: MONDRIAN_DRIVER == 'luciddb' do
    before(:all) do
      @connection = ActiveRecord::Base.connection
      @cube = @olap.cube('Sales')
      @query = <<-SQL
        SELECT {[Measures].[Store Cost], [Measures].[Store Sales]} ON COLUMNS
        FROM  [Sales]
        WHERE ([Time].[2010].[Q1], [Customers].[USA].[CA])
      SQL

      case MONDRIAN_DRIVER
      when 'mysql', 'jdbc_mysql', 'postgresql', 'oracle'
        @connection.execute 'CREATE TABLE sales_copy AS SELECT * FROM sales'
      when 'mssql', 'sqlserver'
        @connection.raw_connection.execute 'SELECT * INTO sales_copy FROM sales'
      end
    end

    after(:each) do
      case MONDRIAN_DRIVER
      when 'mysql', 'jdbc_mysql', 'postgresql', 'oracle'
        @connection.execute 'TRUNCATE TABLE sales'
        @connection.execute 'INSERT INTO sales SELECT * FROM sales_copy'
      when 'mssql', 'sqlserver'
        @connection.raw_connection.execute 'TRUNCATE TABLE sales'
        @connection.raw_connection.execute 'INSERT INTO sales SELECT * FROM sales_copy'
      end

      @olap.flush_schema_cache
      @olap.close
      @olap.connect
    end

    after(:all) do
      case MONDRIAN_DRIVER
      when 'mysql', 'jdbc_mysql', 'postgresql', 'oracle'
        @connection.execute 'DROP TABLE sales_copy'
      when 'mssql', 'sqlserver'
        @connection.raw_connection.execute 'DROP TABLE sales_copy'
      end
    end

    it 'should clear cache for deleted data at lower level with segments' do
      @olap.execute(@query).values.should == [6890.553, 11390.4]
      @connection.execute <<-SQL
        DELETE FROM sales
        WHERE  time_id IN (SELECT id
                           FROM   TIME
                           WHERE  the_year = 2010
                                  AND quarter = 'Q1')
               AND customer_id IN (SELECT id
                                   FROM   customers
                                   WHERE  country = 'USA'
                                          AND state_province = 'CA'
                                          AND city = 'Berkeley')
      SQL
      @cube.flush_region_cache_with_segments(%w(Time 2010 Q1), %w(Customers USA CA))
      @olap.execute(@query).values.should == [6756.4296, 11156.28]
    end

    it 'should clear cache for deleted data at same level with segments' do
      @olap.execute(@query).values.should == [6890.553, 11390.4]
      @connection.execute <<-SQL
        DELETE FROM sales
        WHERE  time_id IN (SELECT id
                           FROM   TIME
                           WHERE  the_year = 2010
                                  AND quarter = 'Q1')
               AND customer_id IN (SELECT id
                                   FROM   customers
                                   WHERE  country = 'USA'
                                          AND state_province = 'CA')
      SQL
      @cube.flush_region_cache_with_segments(%w(Time 2010 Q1), %w(Customers USA CA))
      @olap.execute(@query).values.should == [nil, nil]
    end

    it 'should clear cache for update data at lower level with segments' do
      @olap.execute(@query).values.should == [6890.553, 11390.4]
      @connection.execute <<-SQL
        UPDATE sales SET
            store_sales = store_sales + 1,
            store_cost = store_cost + 1
        WHERE  time_id IN (SELECT id
                           FROM   TIME
                           WHERE  the_year = 2010
                                  AND quarter = 'Q1')
               AND customer_id IN (SELECT id
                                   FROM   customers
                                   WHERE  country = 'USA'
                                          AND state_province = 'CA'
                                          AND city = 'Berkeley')
      SQL
      @cube.flush_region_cache_with_segments(%w(Time 2010 Q1), %w(Customers USA CA))
      @olap.execute(@query).values.should == [6891.553, 11391.4]
    end

    it 'should clear cache for update data at same level with segments' do
      @olap.execute(@query).values.should == [6890.553, 11390.4]
      @connection.execute <<-SQL
        UPDATE sales SET
            store_sales = store_sales + 1,
            store_cost = store_cost + 1
        WHERE  time_id IN (SELECT id
                           FROM   TIME
                           WHERE  the_year = 2010
                                  AND quarter = 'Q1')
               AND customer_id IN (SELECT id
                                   FROM   customers
                                   WHERE  country = 'USA'
                                          AND state_province = 'CA')
      SQL
      @cube.flush_region_cache_with_segments(%w(Time 2010 Q1), %w(Customers USA CA))
      @olap.execute(@query).values.should == [6935.553, 11435.4]
    end

    it 'should clear cache for deleted data at lower level with members' do
      @olap.execute(@query).values.should == [6890.553, 11390.4]
      @connection.execute <<-SQL
        DELETE FROM sales
        WHERE  time_id IN (SELECT id
                           FROM   TIME
                           WHERE  the_year = 2010
                                  AND quarter = 'Q1')
               AND customer_id IN (SELECT id
                                   FROM   customers
                                   WHERE  country = 'USA'
                                          AND state_province = 'CA'
                                          AND city = 'Berkeley')
      SQL
      @cube.flush_region_cache_with_full_names('[Time].[2010].[Q1]', '[Customers].[USA].[CA]')
      @olap.execute(@query).values.should == [6756.4296, 11156.28]
    end

    it 'should clear cache for deleted data at same level with members' do
      @olap.execute(@query).values.should == [6890.553, 11390.4]
      @connection.execute <<-SQL
        DELETE FROM sales
        WHERE  time_id IN (SELECT id
                           FROM   TIME
                           WHERE  the_year = 2010
                                  AND quarter = 'Q1')
               AND customer_id IN (SELECT id
                                   FROM   customers
                                   WHERE  country = 'USA'
                                          AND state_province = 'CA')
      SQL
      @cube.flush_region_cache_with_full_names('[Time].[2010].[Q1]', '[Customers].[USA].[CA]')
      @olap.execute(@query).values.should == [nil, nil]
    end

    it 'should clear cache for update data at lower level with members' do
      @olap.execute(@query).values.should == [6890.553, 11390.4]
      @connection.execute <<-SQL
        UPDATE sales SET
            store_sales = store_sales + 1,
            store_cost = store_cost + 1
        WHERE  time_id IN (SELECT id
                           FROM   TIME
                           WHERE  the_year = 2010
                                  AND quarter = 'Q1')
               AND customer_id IN (SELECT id
                                   FROM   customers
                                   WHERE  country = 'USA'
                                          AND state_province = 'CA'
                                          AND city = 'Berkeley')
      SQL
      @cube.flush_region_cache_with_full_names('[Time].[2010].[Q1]', '[Customers].[USA].[CA]')
      @olap.execute(@query).values.should == [6891.553, 11391.4]
    end

    it 'should clear cache for update data at same level with members' do
      @olap.execute(@query).values.should == [6890.553, 11390.4]
      @connection.execute <<-SQL
        UPDATE sales SET
            store_sales = store_sales + 1,
            store_cost = store_cost + 1
        WHERE  time_id IN (SELECT id
                           FROM   TIME
                           WHERE  the_year = 2010
                                  AND quarter = 'Q1')
               AND customer_id IN (SELECT id
                                   FROM   customers
                                   WHERE  country = 'USA'
                                          AND state_province = 'CA')
      SQL
      @cube.flush_region_cache_with_full_names('[Time].[2010].[Q1]', '[Customers].[USA].[CA]')
      @olap.execute(@query).values.should == [6935.553, 11435.4]
    end
  end
end
