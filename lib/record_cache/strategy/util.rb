# Utility methods for the Cache Strategies
module RecordCache
  module Strategy
    module Util
      CLASS_KEY = :c
      ATTRIBUTES_KEY = :a

      class << self

        # serialize one record before adding it to the cache
        # creates a shallow clone with a version and without associations
        def serialize(record)
          {CLASS_KEY => record.class.name,
           ATTRIBUTES_KEY => record.instance_variable_get(:@attributes).dup}
        end

        # deserialize a cached record
        def deserialize(serialized)
          record = serialized[CLASS_KEY].constantize.allocate
          attributes = serialized[ATTRIBUTES_KEY]
          record.class.serialized_attributes.keys.each do |attribute|
            attributes[attribute] = attributes[attribute].unserialize if attributes[attribute].respond_to?(:unserialize)
          end
          record.init_with('attributes' => attributes)
          record
        end

        # Filter the cached records in memory
        # only simple x = y or x IN (a,b,c) can be handled
        # string comparison is case insensitive
        # Example:
        #  RecordCache::Strategy::Util.filter!(Apple.all, :price => [0.49, 0.59, 0.69], :name => "Green Apple")
        def filter!(records, wheres)
          wheres.each_pair do |attr, value|
            attr = attr.to_sym
            if value.is_a?(Array)
              where_values = Set.new(value.first.respond_to?(:downcase) ? value.map(&:downcase) : value)
              records.select! do |record|
                attribute_value = record.send(attr)
                attribute_value = attribute_value.downcase if attribute_value.respond_to?(:downcase)
                where_values.include?(attribute_value)
              end
            else
              where_value = value.respond_to?(:downcase) ? value.downcase : value
              records.select! do |record|
                attribute_value = record.send(attr)
                attribute_value = attribute_value.downcase if attribute_value.respond_to?(:downcase)
                if [Fixnum, String].to_set == [attribute_value, where_value].map(&:class).to_set
                  attribute_value.to_s == where_value.to_s
                else
                  attribute_value == where_value
                end
              end
            end
          end
        end

        # Sort the cached records in memory, similar to MySql sorting rules including collatiom
        # Simply provide the Symbols of the attributes to sort in Ascending order, or use
        # [<attribute>, false] for Descending order.
        # Example:
        #  RecordCache::Strategy::Util.sort!(Apple.all, :name)
        #  RecordCache::Strategy::Util.sort!(Apple.all, [:name, false])
        #  RecordCache::Strategy::Util.sort!(Apple.all, [:price, false], :name)
        #  RecordCache::Strategy::Util.sort!(Apple.all, [:price, false], [:name, true])
        #  RecordCache::Strategy::Util.sort!(Apple.all, [[:price, false], [:name, true]])
        def sort!(records, *sort_orders)
          return records if records.empty? || sort_orders.empty?
          if sort_orders.first.is_a?(Array) && sort_orders.first.first.is_a?(Array)
            sort_orders = sort_orders.first
          else
            sort_orders = sort_orders.map{ |order| order.is_a?(Array) ? order : [order, true] } unless sort_orders.all?{ |order| order.is_a?(Array) }
          end
          records.sort!(&sort_proc(records.first.class, sort_orders))
          Collator.clear
          records
        end

        private

        # Retrieve the Proc based on the order by attributes
        # Note: Case insensitive sorting with collation is used for Strings
        def sort_proc(base, sort_orders)
          # [['(COLLATER.collate(x.name) || NIL_COMES_FIRST)', 'COLLATER.collate(y.name)'], ['(y.updated_at || NIL_COMES_FIRST)', 'x.updated_at']]
          sort = sort_orders.map do |attr, asc|
            attr = attr.to_s
            lr = ["x.", "y."]
            lr.reverse! unless asc
            lr.each{ |s| s << attr }
            lr.each{ |s| s.replace("Collator.collate(#{s})") } if base.columns_hash[attr].type == :string
            lr[0].replace("(#{lr[0]} || NIL_COMES_FIRST)")
            lr
          end
          # ['[(COLLATER.collate(x.name) || NIL_COMES_FIRST), (y.updated_at || NIL_COMES_FIRST)]', '[COLLATER.collate(y.name), x.updated_at]']
          sort = sort.transpose.map{|s| s.size == 1 ? s.first : "[#{s.join(',')}]"}
          # Proc.new{ |x,y| { ([(COLLATER.collate(x.name) || NIL_COMES_FIRST), (y.updated_at || NIL_COMES_FIRST)] <=> [COLLATER.collate(y.name), x.updated_at]) || 1 }
          eval("Proc.new{ |x,y| (#{sort[0]} <=> #{sort[1]}) || 1 }")
        end

        # If +x.nil?+ this class will return -1 for +x <=> y+
        NIL_COMES_FIRST = ((class NilComesFirst; def <=>(y); -1; end; end); NilComesFirst.new)

        # StringCollator uses the Rails transliterate method for collation
        module Collator
          @collated = []

          def self.clear
            @collated.each { |string| string.send(:remove_instance_variable, :@rc_collated) }
            @collated.clear
          end

          def self.collate(string)
            collated = string.instance_variable_get(:@rc_collated)
            return collated if collated
            normalized = ActiveSupport::Multibyte::Unicode.normalize(ActiveSupport::Multibyte::Unicode.tidy_bytes(string || ''), :c).mb_chars
            collated = I18n.transliterate(normalized).downcase.mb_chars
            # transliterate will replace ignored/unknown chars with ? the following line replaces ? with the original character
            collated.chars.each_with_index{ |c, i| collated[i] = normalized[i] if c == '?' } if collated.index('?')
            # puts "collation: #{string} => #{collated.to_s}"
            string.instance_variable_set(:@rc_collated, collated)
            @collated << string
            collated
          end
        end
      end

    end
  end
end
