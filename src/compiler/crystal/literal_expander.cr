module Crystal
  class LiteralExpander
    def initialize(@program)
    end

    # Convert an array literal to creating an Array and storing the values:
    #
    # From:
    #
    #     [] of T
    #
    # To:
    #
    #     Array(T).new
    #
    # From:
    #
    #     [1, 2, 3]
    #
    # To:
    #
    #     ary = Array(typeof(1, 2, 3)).new(3)
    #     ary.length = 3
    #     buffer = ary.buffer
    #     buffer[0] = 1
    #     buffer[1] = 2
    #     buffer[2] = 3
    #     ary
    def expand(node : ArrayLiteral)
      if node_of = node.of
        if node.elements.length == 0
          generic = Generic.new(Path.new(["Array"], true), [node_of] of ASTNode)
          generic.location = node.location

          call = Call.new(generic, "new")
          call.location = node.location
          return call
        end

        type_var = node_of
      else
        type_var = TypeOf.new(node.elements)
      end

      length = node.elements.length
      capacity = length

      generic = Generic.new(Path.new(["Array"], true), [type_var] of ASTNode)
      generic.location = node.location

      constructor = Call.new(generic, "new", [NumberLiteral.new(capacity, :i32)] of ASTNode)
      constructor.location = node.location

      temp_var = new_temp_var
      assign = Assign.new(temp_var.clone, constructor)
      assign.location = node.location

      set_length = Call.new(temp_var.clone, "length=", [NumberLiteral.new(length, :i32)] of ASTNode)
      set_length.location = node.location

      get_buffer = Call.new(temp_var.clone, "buffer")
      get_buffer.location = node.location

      buffer = new_temp_var
      buffer.location = node.location

      assign_buffer = Assign.new(buffer.clone, get_buffer)
      assign_buffer.location = node.location

      exps = [assign, set_length, assign_buffer] of ASTNode

      node.elements.each_with_index do |elem, i|
        assign_index = Call.new(buffer.clone, "[]=", [NumberLiteral.new(i, :i32), elem] of ASTNode)
        assign_index.location = node.location

        exps << assign_index
      end

      exps << temp_var.clone

      exps = Expressions.new(exps)
      exps.location = node.location
      exps
    end

    # Convert a HashLiteral into creating a Hash and assigning keys and values:
    #
    # From:
    #
    #     {} of K => V
    #
    # To:
    #
    #     Hash(K, V).new
    #
    # From:
    #
    #     {a => b, c => d}
    #
    # To:
    #
    #     hash = Hash(typeof(a, c), typeof(b, d)).new
    #     hash[a] = b
    #     hash[c] = d
    #     hash
    def expand(node : HashLiteral)
      if (node_of_key = node.of_key)
        type_vars = [node_of_key, node.of_value.not_nil!] of ASTNode
      else
        type_vars = [TypeOf.new(node.keys), TypeOf.new(node.values)] of ASTNode
      end

      constructor = Call.new(Generic.new(Path.new(["Hash"], true), type_vars), "new")
      if node.keys.length == 0
        constructor.location = node.location
        constructor
      else
        temp_var = new_temp_var
        assign = Assign.new(temp_var.clone, constructor)

        exps = [assign] of ASTNode
        node.keys.each_with_index do |key, i|
          exps << Call.new(temp_var.clone, "[]=", [key, node.values[i]])
        end
        exps << temp_var.clone
        exp = Expressions.new exps
        exp.location = node.location
        exp
      end
    end

    def expand(node)
      raise "#{node} can't be expanded"
    end

    def new_temp_var
      @program.new_temp_var
    end
  end
end
