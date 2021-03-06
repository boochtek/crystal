require "../ast"
require "../types"
require "../primitives"
require "type_lookup"

module Crystal
  class Call
    property! mod
    property! scope
    property! parent_visitor
    property target_defs
    property expanded

    def target_def
      if defs = @target_defs
        if defs.length == 1
          return defs.first
        else
          ::raise "#{defs.length} target defs for #{self}"
        end
      end

      ::raise "Zero target defs for #{self}"
    end

    def update_input(from)
      recalculate
    end

    def recalculate
      obj = @obj
      obj_type = obj.type? if obj

      if obj_type.is_a?(LibType)
        recalculate_lib_call(obj_type)
        return
      elsif !obj || (obj_type && !obj_type.is_a?(LibType))
        check_not_lib_out_args
      end

      if args.any? &.type?.try &.no_return?
        set_type mod.no_return
        return
      end

      return unless obj_and_args_types_set?

      # Ignore extra recalculations when more than one argument changes at the same time
      # types_signature = args.map { |arg| arg.type.type_id }
      # types_signature << obj.type.type_id if obj
      # return if @types_signature == types_signature
      # @types_signature = types_signature

      block = @block

      unbind_from @target_defs if @target_defs
      unbind_from block.break if block
      @subclass_notifier.try &.remove_subclass_observer(self)

      @target_defs = nil

      if block_arg = @block_arg
        replace_block_arg_with_block(block_arg)
      end

      if obj
        matches = lookup_matches_in(obj.type)
      else
        if name == "super"
          matches = lookup_matches_in_super
        else
          matches = lookup_matches_in scope
        end
      end

      # If @target_defs is set here it means there was a recalculation
      # fired as a result of a recalculation. We keep the last one.

      return if @target_defs

      @target_defs = matches

      bind_to matches if matches
      bind_to block.break if block

      if (parent_visitor = @parent_visitor) && parent_visitor.typed_def? && matches && matches.any?(&.raises)
        parent_visitor.typed_def.raises = true
      end
    end

    def lookup_matches_in(owner : AliasType)
      lookup_matches_in(owner.remove_alias)
    end

    def lookup_matches_in(owner : UnionType)
      owner.union_types.flat_map { |type| lookup_matches_in(type) }
    end

    def lookup_matches_in(owner : Type, self_type = nil, def_name = self.name)
      arg_types = args.map &.type

      matches = check_tuple_indexer(owner, def_name, args, arg_types)
      matches ||= owner.lookup_matches(def_name, arg_types, block)

      if matches.empty?
        if def_name == "new" && owner.metaclass? && (owner.instance_type.class? || owner.instance_type.hierarchy?) && !owner.instance_type.pointer?
          new_matches = define_new owner, arg_types
          unless new_matches.empty?
            if owner.hierarchy_metaclass?
              matches = owner.lookup_matches(def_name, arg_types, block)
            else
              matches = new_matches
            end
          end
        elsif !obj && owner != mod
          mod_matches = mod.lookup_matches(def_name, arg_types, block)
          matches = mod_matches unless mod_matches.empty?
        end
      end

      if matches.empty? && owner.class? && owner.abstract
        matches = owner.hierarchy_type.lookup_matches(def_name, arg_types, block)
      end

      if matches.empty?
        defined_method_missing = owner.check_method_missing(def_name, arg_types, block)
        if defined_method_missing
          matches = owner.lookup_matches(def_name, arg_types, block)
        end
      end

      if matches.empty?
        # For now, if the owner is a NoReturn just ignore the error (this call should be recomputed later)
        unless owner.no_return?
          raise_matches_not_found(matches.owner || owner, def_name, matches)
        end
      end

      # If this call is an implicit call to self
      if !obj && !mod_matches && !owner.is_a?(Program)
        parent_visitor.check_self_closured
      end

      if owner.is_a?(HierarchyType)
        owner.base_type.add_subclass_observer(self)
        @subclass_notifier = owner.base_type
      end

      block = @block

      typed_defs = Array(Def).new(matches.length)

      matches.each do |match|
        # Discard abstract defs for abstract classes
        next if match.def.abstract && match.owner.abstract

        check_not_abstract match

        yield_vars = match_block_arg(match)
        use_cache = !block || match.def.block_arg
        block_type = block && block.body && match.def.block_arg ? block.body.type? : nil
        lookup_self_type = self_type || match.owner
        if self_type
          lookup_arg_types = Array(Type).new(match.arg_types.length + 1)
          lookup_arg_types.push self_type
          lookup_arg_types.concat match.arg_types
        else
          lookup_arg_types = match.arg_types
        end
        match_owner = match.owner
        typed_def = match_owner.lookup_def_instance(match.def.object_id, lookup_arg_types, block_type) if use_cache
        unless typed_def
          typed_def, typed_def_args = prepare_typed_def_with_args(match.def, match_owner, lookup_self_type, match.arg_types)
          match_owner.add_def_instance(match.def.object_id, lookup_arg_types, block_type, typed_def) if use_cache
          if return_type = typed_def.return_type
            typed_def.type = TypeLookup.lookup(match.def.macro_owner.not_nil!, return_type)
            mod.push_def_macro typed_def
          else
            bubbling_exception do
              visitor = TypeVisitor.new(mod, typed_def_args, typed_def)
              visitor.yield_vars = yield_vars
              visitor.free_vars = match.free_vars
              visitor.untyped_def = match.def
              visitor.call = self
              visitor.scope = lookup_self_type
              visitor.type_lookup = match.type_lookup
              typed_def.body.accept visitor

              if visitor.is_initialize
                visitor.bind_initialize_instance_vars(owner)
              end
            end
          end
        end
        typed_defs << typed_def
      end

      typed_defs
    end

    def lookup_matches_in(owner : Nil)
      raise "Bug: trying to lookup matches in nil in #{self}"
    end

    def check_tuple_indexer(owner, def_name, args, arg_types)
      if owner.is_a?(TupleInstanceType) && def_name == "[]" && args.length == 1
        arg = args.first
        if arg.is_a?(NumberLiteral) && arg.kind == :i32
          index = arg.value.to_i
          if 0 <= index < owner.tuple_types.length
            indexer_def = owner.tuple_indexer(index)
            indexer_match = Match.new(owner, indexer_def, owner, arg_types)
            return Matches.new([indexer_match], true)
          else
            raise "index out of bounds for tuple #{owner}"
          end
        end
      end
      nil
    end

    def check_not_abstract(match)
      if match.def.abstract
        bubbling_exception do
          owner = match.owner
          owner = owner.base_type if owner.is_a?(HierarchyType)
          match.def.raise "abstract def #{match.def.owner}##{match.def.name} must be implemented by #{owner}"
        end
      end
    end

    def replace_block_arg_with_block(block_arg)
      block_arg_type = block_arg.type
      if block_arg_type.is_a?(FunInstanceType)
        vars = [] of Var
        args = [] of ASTNode
        block_arg_type.arg_types.map_with_index do |type, i|
          arg = Var.new("#arg#{i}")
          vars << arg
          args << arg
        end
        block = Block.new(vars, Call.new(block_arg, "call", args))
        block.vars = self.before_vars
        self.block = block
      else
        block_arg.raise "expected a function type, not #{block_arg.type}"
      end
    end

    def find_owner_trace(node, owner)
      owner_trace = [] of ASTNode

      visited = Set(typeof(object_id)).new
      visited.add node.object_id
      while deps = node.dependencies?
        dependencies = deps.select { |dep| dep.type? && dep.type.includes_type?(owner) && !visited.includes?(dep.object_id) }
        if dependencies.length > 0
          node = dependencies.first
          owner_trace << node if node
          visited.add node.object_id
        else
          break
        end
      end

      MethodTraceException.new(owner, owner_trace)
    end

    def check_not_lib_out_args
      args.each do |arg|
        if arg.out?
          arg.raise "out can only be used with lib funs"
        end
      end
    end

    def lookup_matches_in_super
      if args.empty? && !has_parenthesis
        parent_args = parent_visitor.typed_def.args
        self.args = Array(ASTNode).new(parent_args.length)
        parent_args.each do |arg|
          var = Var.new(arg.name)
          var.bind_to arg
          self.args.push var
        end
      end

      # TODO: do this better
      untyped_def = parent_visitor.untyped_def
      lookup = untyped_def.owner.not_nil!
      if lookup.is_a?(HierarchyType)
        parents = lookup.base_type.parents
      else
        parents = lookup.parents
      end

      if parents && parents.length > 0
        parents_length = parents.length
        parents.each_with_index do |parent, i|
          if i == parents_length - 1 || parent.lookup_first_def(untyped_def.name, block)
            return lookup_matches_in(parent, scope, untyped_def.name)
          end
        end
      end

      nil
    end

    def recalculate_lib_call(obj_type)
      old_target_defs = @target_defs

      untyped_def = obj_type.lookup_first_def(name, false) #or
      raise "undefined fun '#{name}' for #{obj_type}" unless untyped_def

      check_args_length_match obj_type, untyped_def
      check_lib_out_args untyped_def
      return unless obj_and_args_types_set?

      check_fun_args_types_match obj_type, untyped_def

      untyped_defs = [untyped_def]
      @target_defs = untyped_defs

      self.unbind_from old_target_defs if old_target_defs
      self.bind_to untyped_defs
    end

    def check_lib_out_args(untyped_def)
      untyped_def.args.each_with_index do |arg, i|
        call_arg = self.args[i]
        if call_arg.out?
          arg_type = arg.type
          if arg_type.is_a?(PointerInstanceType)
            var = parent_visitor.lookup_var_or_instance_var(call_arg)
            var.bind_to Var.new("out", arg_type.element_type)
            call_arg.bind_to var
            parent_visitor.bind_meta_var(call_arg)
          else
            call_arg.raise "argument \##{i + 1} to #{untyped_def.owner}.#{untyped_def.name} cannot be passed as 'out' because it is not a pointer"
          end
        end
      end
    end

    def on_new_subclass
      # @types_signature = nil
      recalculate
    end

    def lookup_macro
      in_macro_target &.lookup_macro(name, args.length)
    end

    def in_macro_target
      node_scope = scope
      node_scope = node_scope.metaclass unless node_scope.metaclass?

      macros = yield node_scope
      if !macros && node_scope.metaclass? && node_scope.instance_type.module?
        macros = yield mod.object.metaclass
      end
      macros ||= yield mod
      macros
    end

    def match_block_arg(match)
      yield_vars = nil

      # TODO: check this 'yields > 0', in the past just checking yieldness (without > 0)
      # led to a compiler crash, maybe this is fixed now.
      if (block_arg = match.def.block_arg) && (((yields = match.def.yields) && yields > 0) || match.def.uses_block_arg)
        block = @block.not_nil!
        ident_lookup = MatchTypeLookup.new(match)

        if inputs = block_arg.fun.inputs
          yield_vars = [] of Var
          inputs.each_with_index do |input, i|
            type = lookup_node_type(ident_lookup, input)
            type = type.hierarchy_type
            yield_vars << Var.new("var#{i}", type)
          end
          block.args.each_with_index do |arg, i|
            var = yield_vars[i]?
            arg.bind_to(var || mod.nil_var)
          end
        else
          block.args.each &.bind_to(mod.nil_var)
        end

        if match.def.uses_block_arg
          # Automatically convert block to function pointer
          if yield_vars
            fun_args = yield_vars.map_with_index do |var, i|
              arg = block.args[i]?
              if arg
                Arg.new_with_type(arg.name, var.type)
              else
                Arg.new_with_type(mod.new_temp_var_name, var.type)
              end
            end
          else
            fun_args = [] of Arg
          end

          # But first check if the call has a block_arg
          if call_block_arg = self.block_arg
            # Check input types
            call_block_arg_types = (call_block_arg.type as FunInstanceType).arg_types
            if yield_vars
              if yield_vars.length != call_block_arg_types.length
                raise "wrong number of block argument's arguments (#{call_block_arg_types.length} for #{yield_vars.length})"
              end

              i = 1
              yield_vars.zip(call_block_arg_types) do |yield_var, call_block_arg_type|
                if yield_var.type != call_block_arg_type
                  raise "expected block argument's argument ##{i} to be #{yield_var.type}, not #{call_block_arg_type}"
                end
                i += 1
              end
            elsif call_block_arg_types.length != 0
              raise "wrong number of block argument's arguments (#{call_block_arg_types.length} for 0)"
            end

            fun_literal = call_block_arg
          else
            if block.args.length > fun_args.length
              raise "wrong number of block arguments (#{block.args.length} for #{fun_args.length})"
            end

            fun_def = Def.new("->", fun_args, block.body)
            fun_literal = FunLiteral.new(fun_def)

            unless block_arg.fun.output
              fun_literal.force_void = true
            end

            fun_literal.accept parent_visitor
          end

          block.fun_literal = fun_literal

          fun_literal_type = fun_literal.type?
          if fun_literal_type
            if output = block_arg.fun.output
              block_type = (fun_literal_type as FunInstanceType).return_type
              type_lookup = match.type_lookup as MatchesLookup
              matched = type_lookup.match_arg(block_type, output, match.owner, type_lookup, match.free_vars)
              unless matched
                raise "expected block to return #{output}, not #{block_type}"
              end
            end
          else
            raise "cant' deduce type of block"
          end
        else
          block.accept parent_visitor

          if output = block_arg.fun.output
            raise "can't infer block type" unless block.body.type?

            block_type = block.body.type
            type_lookup = match.type_lookup as MatchesLookup
            matched = type_lookup.match_arg(block_type, output, match.owner, type_lookup, match.free_vars)
            unless matched
              if output.is_a?(Self)
                raise "expected block to return #{match.owner}, not #{block_type}"
              else
                raise "expected block to return #{output}, not #{block_type}"
              end
            end
            block.body.freeze_type = true
          end
        end
      end

      yield_vars
    end

    def lookup_node_type(visitor, node)
      node.accept visitor
      visitor.type
    end

    class MatchTypeLookup < TypeLookup
      def initialize(@match)
        super(match.type_lookup)
      end

      def visit(node : Path)
        if node.names.length == 1 && @match.free_vars
          if type = @match.free_vars[node.names.first]?
            @type = type
            return
          end
        end

        super
      end

      def visit(node : Self)
        @type = @match.owner
        false
      end
    end

    def bubbling_exception
      begin
        yield
      rescue ex : Crystal::Exception
        if obj = @obj
          raise "instantiating '#{obj.type}##{name}(#{args.map(&.type).join ", "})'", ex
        else
          raise "instantiating '#{name}(#{args.map(&.type).join ", "})'", ex
        end
      end
    end

    def check_args_length_match(obj_type, untyped_def : External)
      call_args_count = args.length
      all_args_count = untyped_def.args.length

      if untyped_def.varargs && call_args_count >= all_args_count
        return
      end

      required_args_count = untyped_def.args.count { |arg| !arg.default_value }

      return if required_args_count <= call_args_count && call_args_count <= all_args_count

      raise "wrong number of arguments for '#{full_name(obj_type)}' (#{args.length} for #{untyped_def.args.length})"
    end

    def check_args_length_match(obj_type, untyped_def : Def)
      raise "Bug: shouldn't check args length for Def here"
    end

    def check_fun_args_types_match(obj_type, typed_def)
      typed_def.args.each_with_index do |typed_def_arg, i|
        expected_type = typed_def_arg.type
        self_arg = self.args[i]
        actual_type = self_arg.type
        actual_type = mod.pointer_of(actual_type) if self.args[i].out?
        unless actual_type.compatible_with?(expected_type) || actual_type.is_implicitly_converted_in_c_to?(expected_type)
          implicit_call = try_to_unsafe(self_arg) do |ex|
            if ex.message.not_nil!.includes?("undefined method 'to_unsafe'")
              arg_name = typed_def_arg.name.length > 0 ? "'#{typed_def_arg.name}'" : "##{i + 1}"
              self_arg.raise "argument #{arg_name} of '#{full_name(obj_type)}' must be #{expected_type}, not #{actual_type}"
            else
              self_arg.raise ex.message, ex
            end
          end
          implicit_call_type = implicit_call.type?
          if implicit_call_type
            if implicit_call_type.compatible_with?(expected_type)
              self.args[i] = implicit_call
            else
              arg_name = typed_def_arg.name.length > 0 ? "'#{typed_def_arg.name}'" : "##{i + 1}"
              self_arg.raise "argument #{arg_name} of '#{full_name(obj_type)}' must be #{expected_type}, not #{actual_type} (nor #{implicit_call_type} returned by '#{actual_type}#to_unsafe')"
            end
          else
            self_arg.raise "tried to convert #{actual_type} to #{expected_type} invoking to_unsafe, but can't deduce its type"
          end
        end
      end

      # Need to call to_unsafe on variadic args too
      if typed_def.varargs
        typed_def.args.length.upto(self.args.length - 1) do |i|
          self_arg = self.args[i]
          self_arg_type = self_arg.type?
          if self_arg_type
            unless self_arg_type.nil_type? || self_arg_type.primitive_like?
              implicit_call = try_to_unsafe(self_arg) do |ex|
                if ex.message.not_nil!.includes?("undefined method 'to_unsafe'")
                  self_arg.raise "argument ##{i + 1} of '#{full_name(obj_type)}' is not a primitive type and no #{self_arg_type}#to_unsafe method found"
                else
                  self_arg.raise ex.message, ex
                end
              end
              implicit_call_type = implicit_call.type?
              if implicit_call_type
                if implicit_call_type.primitive_like?
                  self.args[i] = implicit_call
                else
                  self_arg.raise "converted #{self_arg_type} invoking to_unsafe, but #{implicit_call_type} is not a primitive type"
                end
              else
                self_arg.raise "tried to convert #{self_arg_type} invoking to_unsafe, but can't deduce its type"
              end
            end
          else
            self_arg.raise "can't deduce argument type"
          end
        end
      end
    end

    def try_to_unsafe(self_arg)
      implicit_call = Call.new(self_arg.clone, "to_unsafe")
      begin
        implicit_call.accept parent_visitor
      rescue ex : TypeException
        yield ex
      end
      implicit_call
    end

    def obj_and_args_types_set?
      obj = @obj
      block_arg = @block_arg
      args.all?(&.type?) && (obj ? obj.type? : true) && (block_arg ? block_arg.type? : true)
    end

    def raise_matches_not_found(owner : CStructType, def_name, matches = nil)
      raise_struct_or_union_field_not_found owner, def_name
    end

    def raise_matches_not_found(owner : CUnionType, def_name, matches = nil)
      raise_struct_or_union_field_not_found owner, def_name
    end

    def raise_struct_or_union_field_not_found(owner, def_name)
      if def_name.ends_with?('=')
        def_name = def_name[0 .. -2]
      end

      var = owner.vars[def_name]?
      if var
        args[0].raise "field '#{def_name}' of #{owner.type_desc} #{owner} has type #{var.type}, not #{args[0].type}"
      else
        raise "#{owner.type_desc} #{owner} has no field '#{def_name}'"
      end
    end

    def raise_matches_not_found(owner, def_name, matches = nil)
      # Special case: Foo+:Class#new
      if owner.is_a?(HierarchyMetaclassType) && def_name == "new"
        raise_matches_not_found_for_hierarchy_metaclass_new owner
      end

      defs = owner.lookup_defs(def_name)
      obj = @obj
      if defs.empty?
        check_macro_wrong_number_of_arguments(def_name)

        owner_trace = find_owner_trace(obj, owner) if obj
        similar_name = owner.lookup_similar_def_name(def_name, self.args.length, block)

        error_msg = String.build do |msg|
          if obj && owner != @mod
            msg << "undefined method '#{def_name}' for #{owner}"
          elsif args.length > 0 || has_parenthesis
            msg << "undefined method '#{def_name}'"
          else
            similar_name = parent_visitor.lookup_similar_var_name(def_name) unless similar_name
            msg << "undefined local variable or method '#{def_name}'"
          end
          msg << " \e[1;33m(did you mean '#{similar_name}'?)\e[0m" if similar_name

          # Check if it's an instance variable that was never assigned a value
          if obj.is_a?(InstanceVar)
            scope = scope as InstanceVarContainer
            ivar = scope.lookup_instance_var(obj.name)
            deps = ivar.dependencies?
            if deps && deps.length == 1 && deps[0].same?(mod.nil_var)
              similar_name = scope.lookup_similar_instance_var_name(ivar.name)
              if similar_name
                msg << " \e[1;33m(#{ivar.name} was never assigned a value, did you mean #{similar_name}?)\e[0m"
              else
                msg << " \e[1;33m(#{ivar.name} was never assigned a value)\e[0m"
              end
            end
          end
        end
        raise error_msg, owner_trace
      end

      defs_matching_args_length = defs.select { |a_def| a_def.args.length == self.args.length }
      if defs_matching_args_length.empty?
        all_arguments_lengths = defs.map(&.args.length).uniq!
        raise "wrong number of arguments for '#{full_name(owner, def_name)}' (#{args.length} for #{all_arguments_lengths.join ", "})"
      end

      if defs_matching_args_length.length > 0
        if block && defs_matching_args_length.all? { |a_def| !a_def.yields }
          raise "'#{full_name(owner, def_name)}' is not expected to be invoked with a block, but a block was given"
        elsif !block && defs_matching_args_length.all?(&.yields)
          raise "'#{full_name(owner, def_name)}' is expected to be invoked with a block, but no block was given"
        end
      end

      if args.length == 1 && args.first.type.includes_type?(mod.nil)
        owner_trace = find_owner_trace(args.first, mod.nil)
      end

      arg_names = [] of Array(String)

      message = String.build do |msg|
        msg << "no overload matches '#{full_name(owner, def_name)}'"
        msg << " with types #{args.map(&.type).join ", "}" if args.length > 0
        msg << "\n"
        msg << "Overloads are:"
        defs.each do |a_def|
          arg_names.push a_def.args.map(&.name)

          msg << "\n - #{full_name(owner, def_name)}("
          a_def.args.each_with_index do |arg, i|
            msg << ", " if i > 0
            msg << arg.name
            if arg_type = arg.type?
              msg << " : "
              msg << arg_type
            elsif res = arg.restriction
              msg << " : "
              if owner.is_a?(GenericClassInstanceType) && res.is_a?(Path) && res.names.length == 1
                if type_var = owner.type_vars[res.names[0]]?
                  msg << type_var.type
                else
                  msg << res
                end
              else
                msg << res
              end
            end
          end

          msg << ", &block" if a_def.yields
          msg << ")"
        end

        if matches
          cover = matches.cover
          if cover.is_a?(Cover)
            missing = cover.missing
            uniq_arg_names = arg_names.uniq!
            uniq_arg_names = uniq_arg_names.length == 1 ? uniq_arg_names.first : nil
            unless missing.empty?
              msg << "\nCouldn't find overloads for these types:"
              missing.each_with_index do |missing_types|
                if uniq_arg_names
                  msg << "\n - #{full_name(owner, def_name)}(#{missing_types.map_with_index { |missing_type, i| "#{uniq_arg_names[i]} : #{missing_type}" }.join ", "}"
                else
                  msg << "\n - #{full_name(owner, def_name)}(#{missing_types.join ", "}"
                end
                msg << ", &block" if block
                msg << ")"
              end
            end
          end
        end
      end

      raise message, owner_trace
    end

    def raise_matches_not_found_for_hierarchy_metaclass_new(owner)
      arg_types = args.map &.type

      owner.each_concrete_type do |concrete_type|
        defs = concrete_type.instance_type.lookup_defs_with_modules("initialize")
        defs = defs.select { |a_def| a_def.args.length != args.length }
        unless defs.empty?
          all_arguments_lengths = Set(Int32).new
          defs.each { |a_def| all_arguments_lengths << a_def.args.length }
          raise "wrong number of arguments for '#{concrete_type.instance_type}#initialize' (#{args.length} for #{all_arguments_lengths.join ", "})"
        end
      end
    end

    def check_macro_wrong_number_of_arguments(def_name)
      macros = in_macro_target &.lookup_macros(def_name)
      if macros
        all_arguments_lengths = Set(Int32).new
        macros.each do |macro|
          min_length = macro.args.index(&.default_value) || macro.args.length
          min_length.upto(macro.args.length) do |args_length|
            all_arguments_lengths << args_length
          end
        end

        raise "wrong number of arguments for macro '#{def_name}' (#{args.length} for #{all_arguments_lengths.join ", "})"
      end
    end

    def full_name(owner, def_name = name)
      owner.is_a?(Program) ? name : "#{owner}##{def_name}"
    end

    def define_new(scope, arg_types)
      instance_type = scope.instance_type

      if instance_type.is_a?(HierarchyType)
        matches = define_new_recursive(instance_type.base_type, arg_types)
        return Matches.new(matches, scope)
      end

      # First check if this type has any initialize
      initializers = instance_type.lookup_defs_with_modules("initialize")

      # If there are no initialize at all, use parent's initialize
      if initializers.empty?
        matches = instance_type.lookup_matches("initialize", arg_types, block)
      else
        # Otherwise, use this type initializers
        matches = instance_type.lookup_matches_with_modules("initialize", arg_types, block)
      end

      if matches.empty?
        # We first need to check if there aren't any "new" methods in the class
        defs = scope.lookup_defs("new")
        if defs.any? { |a_def| a_def.args.length > 0 }
          Matches.new([] of Match, false)
        else
          define_new_without_initialize(scope, arg_types)
        end
      else
        Call.define_new_with_initialize(scope, arg_types, matches)
      end
    end

    def define_new_without_initialize(scope, arg_types)
      defs = scope.instance_type.lookup_defs("initialize")
      if defs.length > 0
        raise_matches_not_found scope.instance_type, "initialize"
      end

      if defs.length == 0 && arg_types.length > 0
        raise "wrong number of arguments for '#{full_name(scope.instance_type)}' (#{self.args.length} for 0)"
      end

      # This creates:
      #
      #    x = allocate
      #    GC.add_finalizer x
      #    x
      var = Var.new("x")
      alloc = Call.new(nil, "allocate")
      assign = Assign.new(var, alloc)
      call_gc = Call.new(Path.new(["GC"], true), "add_finalizer", [var] of ASTNode)

      exps = Array(ASTNode).new(3)
      exps << assign
      exps << call_gc unless scope.instance_type.struct?
      exps << var

      match_def = Def.new("new", [] of Arg, exps)
      match = Match.new(scope, match_def, scope, arg_types)

      scope.add_def match_def

      Matches.new([match], true)
    end

    def self.define_new_with_initialize(scope, arg_types, matches)
      instance_type = scope.instance_type
      instance_type = instance_type.generic_class if instance_type.is_a?(GenericClassInstanceType)

      ms = matches.map do |match|
        if instance_type.is_a?(GenericClassType)
          generic_type_args = Array(ASTNode).new(instance_type.type_vars.length)
          instance_type.type_vars.each do |type_var|
            generic_type_args << Path.new([type_var])
          end
          new_generic = Generic.new(Path.new([instance_type.name]), generic_type_args)
          alloc = Call.new(new_generic, "allocate")
        else
          alloc = Call.new(nil, "allocate")
        end

        # This creates:
        #
        #    x = allocate
        #    GC.add_finalizer x
        #    x.initialize ..., &block
        #    x
        var = Var.new("x")
        new_vars = Array(ASTNode).new(arg_types.length)
        arg_types.each_with_index do |dummy, i|
          new_vars.push Var.new("arg#{i}")
        end

        new_args = Array(Arg).new(arg_types.length)
        arg_types.each_with_index do |dummy, i|
          arg = Arg.new("arg#{i}")
          arg.restriction = match.def.args[i]?.try &.restriction
          new_args.push arg
        end

        assign = Assign.new(var, alloc)
        call_gc = Call.new(Path.new(["GC"], true), "add_finalizer", [var] of ASTNode)
        init = Call.new(var, "initialize", new_vars)


        exps = Array(ASTNode).new(4)
        exps << assign
        exps << call_gc unless instance_type.struct?
        exps << init
        exps << var

        match_def = Def.new("new", new_args, exps)

        # Forward block argument if any
        if match.def.uses_block_arg
          block_arg = match.def.block_arg.not_nil!
          init.block_arg = Var.new(block_arg.name)
          match_def.block_arg = block_arg.clone
          match_def.uses_block_arg = true
        end

        new_match = Match.new(scope, match_def, match.type_lookup, match.arg_types, match.free_vars)

        scope.add_def match_def

        new_match
      end
      Matches.new(ms, true)
    end

    def define_new_recursive(owner, arg_types, matches = [] of Match)
      unless owner.abstract
        owner_matches = define_new(owner.metaclass, arg_types)
        matches.concat owner_matches.matches
      end

      owner.subclasses.each do |subclass|
        subclass_matches = define_new_recursive(subclass, arg_types)
        matches.concat subclass_matches
      end

      matches
    end

    def prepare_typed_def_with_args(untyped_def, owner, self_type, arg_types)
      args_start_index = 0

      typed_def = untyped_def.clone
      typed_def.owner = owner

      if body = typed_def.body
        typed_def.bind_to body
      end

      args = MetaVars.new

      if self_type.is_a?(Type)
        args["self"] = MetaVar.new("self", self_type)
      end

      0.upto(self.args.length - 1) do |index|
        arg = typed_def.args[index]
        type = arg_types[args_start_index + index]
        var = MetaVar.new(arg.name, type)
        var.location = arg.location
        var.bind_to(var)
        args[arg.name] = var
        arg.type = type
      end

      fun_literal = @block.try &.fun_literal
      if fun_literal
        block_arg = untyped_def.block_arg.not_nil!
        var = MetaVar.new(block_arg.name, fun_literal.type)
        args[block_arg.name] = var

        typed_def.block_arg.not_nil!.type = fun_literal.type
      end

      {typed_def, args}
    end
  end
end
