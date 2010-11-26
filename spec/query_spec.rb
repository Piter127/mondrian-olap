require "spec_helper"

describe "Query" do
  before(:all) do
    @olap = Mondrian::OLAP::Connection.create(CONNECTION_PARAMS_WITH_CATALOG)
    @sql = ActiveRecord::Base.connection

    @query_string = <<-SQL
    SELECT  {[Measures].[Unit Sales], [Measures].[Store Sales]} ON COLUMNS,
            {[Product].children} ON ROWS
      FROM  [Sales]
      WHERE ([Time].[1997].[Q1], [Customers].[USA].[CA])
    SQL

    @sql_select = <<-SQL
    SELECT SUM(sales.unit_sales) unit_sales_sum, SUM(sales.store_sales) store_sales_sum
    FROM sales_fact_1997 AS sales
      LEFT JOIN product ON sales.product_id = product.product_id
      LEFT JOIN product_class ON product.product_class_id = product_class.product_class_id
      LEFT JOIN time_by_day ON sales.time_id = time_by_day.time_id
      LEFT JOIN customer ON sales.customer_id = customer.customer_id
    WHERE time_by_day.the_year = 1997 AND time_by_day.quarter = 'Q1'
      AND customer.country = 'USA' AND customer.state_province = 'CA'
    GROUP BY product_class.product_family
    SQL

  end

  def sql_select_numbers(select_string)
    @sql.select_rows(select_string).map do |rows|
      rows.map{|col| BigDecimal(col)}
    end
  end

  describe "result" do
    before(:all) do

      # TODO: replace hardcoded expected values with result of SQL query
      @expected_column_names = ["Unit Sales", "Store Sales"]
      @expected_column_full_names = ["[Measures].[Unit Sales]", "[Measures].[Store Sales]"]
      @expected_drillable_columns = [false, false]
      @expected_row_names = ["Drink", "Food", "Non-Consumable"]
      @expected_row_full_names = ["[Product].[Drink]", "[Product].[Food]", "[Product].[Non-Consumable]"]
      @expected_drillable_rows = [true, true, true]

      # @expected_result_values = [
      #   [1654.0, 3309.75],
      #   [12064.0, 26044.84],
      #   [3172.0, 6820.61]
      # ]

      # AR JDBC driver always returns strings, need to convert to BigDecimal
      @expected_result_values = sql_select_numbers(@sql_select)

      @expected_result_values_by_columns =
        [@expected_result_values.map{|row| row[0]}, @expected_result_values.map{|row| row[1]}]

      @result = @olap.execute @query_string
    end

    it "should return axes" do
      @result.axes_count.should == 2
    end

    it "should return column names" do
      @result.column_names.should == @expected_column_names
      @result.column_full_names.should == @expected_column_full_names
    end

    it "should return row names" do
      @result.row_names.should == @expected_row_names
      @result.row_full_names.should == @expected_row_full_names
    end

    it "should return axis by index names" do
      @result.axis_names[0].should == @expected_column_names
      @result.axis_full_names[0].should == @expected_column_full_names
    end

    it "should return column members" do
      @result.column_members.map(&:name).should == @expected_column_names
      @result.column_members.map(&:full_name).should == @expected_column_full_names
      @result.column_members.map(&:"drillable?").should == @expected_drillable_columns
    end

    it "should return row members" do
      @result.row_members.map(&:name).should == @expected_row_names
      @result.row_members.map(&:full_name).should == @expected_row_full_names
      @result.row_members.map(&:"drillable?").should == @expected_drillable_rows
    end

    it "should return cells" do
      @result.values.should == @expected_result_values
    end

    it "should return cells with specified axes number sequence" do
      @result.values(0, 1).should == @expected_result_values_by_columns
    end

    it "should return cells with specified axes name sequence" do
      @result.values(:columns, :rows).should == @expected_result_values_by_columns
    end

    it "should return formatted cells" do
      @result.formatted_values.map{|r| r.map{|s| BigDecimal.new(s.gsub(',',''))}}.should == @expected_result_values
    end

  end

  describe "builder" do

    before(:each) do
      @query = @olap.from('Sales')
    end

    describe "from cube" do
      it "should return query" do
        @query.should be_a(Mondrian::OLAP::Query)
        @query.cube_name.should == 'Sales'
      end
    end

    describe "columns" do
      it "should accept list" do
        @query.columns('[Measures].[Unit Sales]', '[Measures].[Store Sales]').should equal(@query)
        @query.columns.should == ['[Measures].[Unit Sales]', '[Measures].[Store Sales]']
      end

      it "should accept list as array" do
        @query.columns(['[Measures].[Unit Sales]', '[Measures].[Store Sales]'])
        @query.columns.should == ['[Measures].[Unit Sales]', '[Measures].[Store Sales]']
      end

      it "should accept with several method calls" do
        @query.columns('[Measures].[Unit Sales]').columns('[Measures].[Store Sales]')
        @query.columns.should == ['[Measures].[Unit Sales]', '[Measures].[Store Sales]']
      end
    end

    describe "other axis" do
      it "should accept axis with index member list" do
        @query.axis(0, '[Measures].[Unit Sales]', '[Measures].[Store Sales]')
        @query.axis(0).should == ['[Measures].[Unit Sales]', '[Measures].[Store Sales]']
      end

      it "should accept rows list" do
        @query.rows('[Product].children')
        @query.rows.should == ['[Product].children']
      end

      it "should accept pages list" do
        @query.pages('[Product].children')
        @query.pages.should == ['[Product].children']
      end
    end

    describe "crossjoin" do
      it "should do crossjoin of several dimensions" do
        @query.rows('[Product].children').crossjoin('[Customers].[Canada]', '[Customers].[USA]')
        @query.rows.should == [:crossjoin, ['[Product].children'], ['[Customers].[Canada]', '[Customers].[USA]']]
      end

      it "should do crossjoin passing array as first argument" do
        @query.rows('[Product].children').crossjoin(['[Customers].[Canada]', '[Customers].[USA]'])
        @query.rows.should == [:crossjoin, ['[Product].children'], ['[Customers].[Canada]', '[Customers].[USA]']]
      end
    end

    describe "nonempty" do
      it "should limit to set of members with nonempty values" do
        @query.rows('[Product].children').nonempty
        @query.rows.should == [:nonempty, ['[Product].children']]
      end
    end

    describe "order" do
      it "should order by one measure" do
        @query.rows('[Product].children').order('[Measures].[Unit Sales]', :bdesc)
        @query.rows.should == [:order, ['[Product].children'], '[Measures].[Unit Sales]', 'BDESC']
      end

      it "should order using String order direction" do
        @query.rows('[Product].children').order('[Measures].[Unit Sales]', 'DESC')
        @query.rows.should == [:order, ['[Product].children'], '[Measures].[Unit Sales]', 'DESC']
      end

      it "should order by measure and other member" do
        @query.rows('[Product].children').order(['[Measures].[Unit Sales]', '[Customers].[USA]'], :basc)
        @query.rows.should == [:order, ['[Product].children'], ['[Measures].[Unit Sales]', '[Customers].[USA]'], 'BASC']
      end
    end

    describe "hierarchize" do
      it "should hierarchize simple set" do
        @query.rows('[Customers].[Country].Members', '[Customers].[City].Members').hierarchize
        @query.rows.should == [:hierarchize, ['[Customers].[Country].Members', '[Customers].[City].Members']]
      end

      it "should hierarchize last set of crossjoin" do
        @query.rows('[Product].children').crossjoin('[Customers].[Country].Members', '[Customers].[City].Members').hierarchize
        @query.rows.should == [:crossjoin, ['[Product].children'],
          [:hierarchize, ['[Customers].[Country].Members', '[Customers].[City].Members']]]
      end

      it "should hierarchize all crossjoin" do
        @query.rows('[Product].children').crossjoin('[Customers].[Country].Members', '[Customers].[City].Members').hierarchize_all
        @query.rows.should == [:hierarchize, [:crossjoin, ['[Product].children'],
          ['[Customers].[Country].Members', '[Customers].[City].Members']]]
      end

      it "should hierarchize with POST" do
        @query.rows('[Customers].[Country].Members', '[Customers].[City].Members').hierarchize(:post)
        @query.rows.should == [:hierarchize, ['[Customers].[Country].Members', '[Customers].[City].Members'], 'POST']
      end

    end

    describe "except" do
      it "should except one set from other" do
        @query.rows('[Customers].[Country].Members').except('[Customers].[USA]')
        @query.rows.should == [:except, ['[Customers].[Country].Members'], ['[Customers].[USA]']]
      end

      it "should except from last set of crossjoin" do
        @query.rows('[Product].children').crossjoin('[Customers].[Country].Members').except('[Customers].[USA]')
        @query.rows.should == [:crossjoin, ['[Product].children'],
          [:except, ['[Customers].[Country].Members'], ['[Customers].[USA]']]]
      end
    end

    describe "where" do
      it "should accept conditions" do
        @query.where('[Time].[1997].[Q1]', '[Customers].[USA].[CA]').should equal(@query)
        @query.where.should == ['[Time].[1997].[Q1]', '[Customers].[USA].[CA]']
      end

      it "should accept conditions as array" do
        @query.where(['[Time].[1997].[Q1]', '[Customers].[USA].[CA]'])
        @query.where.should == ['[Time].[1997].[Q1]', '[Customers].[USA].[CA]']
      end

      it "should accept conditions with several method calls" do
        @query.where('[Time].[1997].[Q1]').where('[Customers].[USA].[CA]')
        @query.where.should == ['[Time].[1997].[Q1]', '[Customers].[USA].[CA]']
      end
    end

    describe "with member" do
      it "should accept definition" do
        @query.with_member('[Measures].[ProfitPct]',
          :as =>  'Val((Measures.[Store Sales] - Measures.[Store Cost]) / Measures.[Store Sales])').
          should equal(@query)
        @query.with_member.should == [['[Measures].[ProfitPct]',
          {:as =>  'Val((Measures.[Store Sales] - Measures.[Store Cost]) / Measures.[Store Sales])'}]]
      end

      it "should accept definition as array" do
        @query.with_member([['[Measures].[ProfitPct]',
          {:as =>  'Val((Measures.[Store Sales] - Measures.[Store Cost]) / Measures.[Store Sales])'}]])
        @query.with_member.should == [['[Measures].[ProfitPct]',
          {:as =>  'Val((Measures.[Store Sales] - Measures.[Store Cost]) / Measures.[Store Sales])'}]]
      end

      it "should accept definition with additional parameters" do
        @query.with_member('[Measures].[ProfitPct]',
          :as =>  'Val((Measures.[Store Sales] - Measures.[Store Cost]) / Measures.[Store Sales])',
          :solve_order => 1,
          :format_string => 'Percent')
        @query.with_member.should == [['[Measures].[ProfitPct]',
          {:as =>  'Val((Measures.[Store Sales] - Measures.[Store Cost]) / Measures.[Store Sales])',
          :solve_order => 1, :format_string => 'Percent'}]]
      end
    end

    describe "to MDX" do
      it "should return MDX query" do
        @query.columns('[Measures].[Unit Sales]', '[Measures].[Store Sales]').
          rows('[Product].children').
          where('[Time].[1997].[Q1]', '[Customers].[USA].[CA]').
          to_mdx.should be_like <<-SQL
            SELECT  {[Measures].[Unit Sales], [Measures].[Store Sales]} ON COLUMNS,
                    [Product].children ON ROWS
              FROM  [Sales]
              WHERE ([Time].[1997].[Q1], [Customers].[USA].[CA])
          SQL
      end

      it "should return query with crossjoin" do
        @query.columns('[Measures].[Unit Sales]', '[Measures].[Store Sales]').
          rows('[Product].children').crossjoin('[Customers].[Canada]', '[Customers].[USA]').
          where('[Time].[1997].[Q1]').
          to_mdx.should be_like <<-SQL
            SELECT  {[Measures].[Unit Sales], [Measures].[Store Sales]} ON COLUMNS,
                    CROSSJOIN([Product].children, {[Customers].[Canada], [Customers].[USA]}) ON ROWS
              FROM  [Sales]
              WHERE ([Time].[1997].[Q1])
          SQL
      end

      it "should return query with several crossjoins" do
        @query.columns('[Measures].[Unit Sales]', '[Measures].[Store Sales]').
          rows('[Product].children').crossjoin('[Customers].[Canada]', '[Customers].[USA]').
          crossjoin('[Time].[1997].[Q1]', '[Time].[1997].[Q2]').
          to_mdx.should be_like <<-SQL
            SELECT  {[Measures].[Unit Sales], [Measures].[Store Sales]} ON COLUMNS,
                    CROSSJOIN(CROSSJOIN([Product].children, {[Customers].[Canada], [Customers].[USA]}),
                              {[Time].[1997].[Q1], [Time].[1997].[Q2]}) ON ROWS
              FROM  [Sales]
          SQL
      end

      it "should return query with crossjoin and nonempty" do
        @query.columns('[Measures].[Unit Sales]', '[Measures].[Store Sales]').
          rows('[Product].children').crossjoin('[Customers].[Canada]', '[Customers].[USA]').nonempty.
          where('[Time].[1997].[Q1]').
          to_mdx.should be_like <<-SQL
            SELECT  {[Measures].[Unit Sales], [Measures].[Store Sales]} ON COLUMNS,
                    NON EMPTY CROSSJOIN([Product].children, {[Customers].[Canada], [Customers].[USA]}) ON ROWS
              FROM  [Sales]
              WHERE ([Time].[1997].[Q1])
          SQL
      end

      it "should return query with order by one measure" do
        @query.columns('[Measures].[Unit Sales]', '[Measures].[Store Sales]').
          rows('[Product].children').order('[Measures].[Unit Sales]', :bdesc).
          to_mdx.should be_like <<-SQL
            SELECT  {[Measures].[Unit Sales], [Measures].[Store Sales]} ON COLUMNS,
                    ORDER([Product].children, [Measures].[Unit Sales], BDESC) ON ROWS
              FROM  [Sales]
          SQL
      end

      it "should return query with order by measure and other member" do
        @query.columns('[Measures].[Unit Sales]', '[Measures].[Store Sales]').
          rows('[Product].children').order(['[Measures].[Unit Sales]', '[Customers].[USA]'], :asc).
          to_mdx.should be_like <<-SQL
            SELECT  {[Measures].[Unit Sales], [Measures].[Store Sales]} ON COLUMNS,
                    ORDER([Product].children, ([Measures].[Unit Sales], [Customers].[USA]), ASC) ON ROWS
              FROM  [Sales]
          SQL
      end

      it "should return query with hierarchize" do
        @query.columns('[Measures].[Unit Sales]', '[Measures].[Store Sales]').
          rows('[Customers].[Country].Members', '[Customers].[City].Members').hierarchize.
          to_mdx.should be_like <<-SQL
            SELECT  {[Measures].[Unit Sales], [Measures].[Store Sales]} ON COLUMNS,
                    HIERARCHIZE({[Customers].[Country].Members, [Customers].[City].Members}) ON ROWS
              FROM  [Sales]
          SQL
      end

      it "should return query with hierarchize and order" do
        @query.columns('[Measures].[Unit Sales]', '[Measures].[Store Sales]').
          rows('[Customers].[Country].Members', '[Customers].[City].Members').hierarchize(:post).
          to_mdx.should be_like <<-SQL
            SELECT  {[Measures].[Unit Sales], [Measures].[Store Sales]} ON COLUMNS,
                    HIERARCHIZE({[Customers].[Country].Members, [Customers].[City].Members}, POST) ON ROWS
              FROM  [Sales]
          SQL
      end

      it "should return query with except" do
        @query.columns('[Measures].[Unit Sales]', '[Measures].[Store Sales]').
          rows('[Customers].[Country].Members').except('[Customers].[USA]').
          to_mdx.should be_like <<-SQL
            SELECT  {[Measures].[Unit Sales], [Measures].[Store Sales]} ON COLUMNS,
                    EXCEPT([Customers].[Country].Members, [Customers].[USA]) ON ROWS
              FROM  [Sales]
          SQL
      end

      it "should return query including WITH MEMBER clause" do
        @query.with_member('[Measures].[ProfitPct]',
            :as =>  'Val((Measures.[Store Sales] - Measures.[Store Cost]) / Measures.[Store Sales])',
            :solve_order => 1, :format_string => 'Percent').
          with_member('[Measures].[ProfitValue]',
            :as => '[Measures].[Store Sales] * [Measures].[ProfitPct]',
            :solve_order => 2, :format_string => 'Currency').
          columns('[Measures].[Unit Sales]', '[Measures].[Store Sales]').
          rows('[Product].children').
          where('[Time].[1997].[Q1]', '[Customers].[USA].[CA]').
          to_mdx.should be_like <<-SQL
            WITH
               MEMBER [Measures].[ProfitPct] AS 
               'Val((Measures.[Store Sales] - Measures.[Store Cost]) / Measures.[Store Sales])',
               SOLVE_ORDER = 1, FORMAT_STRING = 'Percent'
               MEMBER [Measures].[ProfitValue] AS 
               '[Measures].[Store Sales] * [Measures].[ProfitPct]',
               SOLVE_ORDER = 2, FORMAT_STRING = 'Currency'
            SELECT  {[Measures].[Unit Sales], [Measures].[Store Sales]} ON COLUMNS,
                    [Product].children ON ROWS
              FROM  [Sales]
              WHERE ([Time].[1997].[Q1], [Customers].[USA].[CA])
          SQL
      end
    end

    describe "execute" do
      it "should return result" do
        result = @query.columns('[Measures].[Unit Sales]', '[Measures].[Store Sales]').
          rows('[Product].children').
          where('[Time].[1997].[Q1]', '[Customers].[USA].[CA]').
          execute
        result.values.should == sql_select_numbers(@sql_select)
      end
    end

    describe "result HTML formatting" do
      it "should format result" do
        result = @query.columns('[Measures].[Unit Sales]', '[Measures].[Store Sales]').
          rows('[Product].children').
          where('[Time].[1997].[Q1]', '[Customers].[USA].[CA]').
          execute
        Nokogiri::HTML.fragment(result.to_html).css('tr').size.should == (sql_select_numbers(@sql_select).size + 1)
      end

      # it "test" do
      #   puts @olap.from('Sales').
      #     columns('[Product].children').
      #     rows('[Customers].[USA].[CA].children').
      #     where('[Time].[1997].[Q1]', '[Measures].[Store Sales]').
      #     execute.to_html
      # end
    end

  end

end