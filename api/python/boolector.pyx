# Boolector: Satisfiablity Modulo Theories (SMT) solver.
#
# Copyright (C) 2013-2014 Mathias Preiner.
# Copyright (C) 2014 Aina Niemetz.
#
# All rights reserved.
#
# This file is part of Boolector.
# See COPYING for more information on using this software.
#

cimport btorapi
from libc.stdlib cimport malloc, free
from libc.stdio cimport stdout, FILE, fopen, fclose
from cpython cimport bool
import math, os

g_tunable_options = {"rewrite_level", "rewrite_level_pbr",
                     "beta_reduce_all", "probe_beta_reduce_all",
                     "pbra_lod_limit", "pbra_sat_limit", "pbra_ops_factor",
                     "dual_prop", "just", "ucopt", "lazy_synthesize",
                     "eliminate_slices"}

class _BoolectorException(Exception):
    def __init__(self, msg):
        self.msg = msg

    def __str__(self):
        return "[pybtor] {}".format(self.msg)

# utility functions

cdef btorapi.BoolectorNode * _c_node(x):
    assert(isinstance(x, _BoolectorNode))
    return (<_BoolectorNode> x)._c_node

cdef class _ChPtr:
    cdef char * _c_str
    cdef bytes _py_str
    def __init__(self, str string):
        if string is None:
            self._py_str = None
            self._c_str = NULL
        else:
            self._py_str = string.encode()
            self._c_str = self._py_str

cdef str _to_str(const char * string):
    if string is NULL:
        return None
    cdef bytes py_str = string
    return py_str.decode()

def _is_power2(int num):
    return num != 0 and (num & (num - 1)) == 0

cdef _to_node(x, y):
    if isinstance(x, _BoolectorBVNode) and isinstance(y, _BoolectorBVNode):
        if (<_BoolectorBVNode> x).width != (<_BoolectorBVNode> y).width:
            raise _BoolectorException(
                      "Both operands must have the same bit width")
        return x, y
    elif not (isinstance(x, _BoolectorBVNode) or
              isinstance(y, _BoolectorBVNode)):
        raise _BoolectorException("At least one of the operands must be of "\
                                 "type '_BoolectorBVNode'") 
    if isinstance(x, _BoolectorBVNode):
        btor = (<_BoolectorBVNode> x).btor
        width = (<_BoolectorBVNode> x).width
    else:
        assert(isinstance(y, _BoolectorBVNode))
        btor = (<_BoolectorBVNode> y).btor
        width = (<_BoolectorBVNode> y).width

    x = btor.Const(x, width)
    y = btor.Const(y, width)
    return x, y

cdef int _get_argument_width(_BoolectorFunNode fun, int pos):
    if fun._params:
        return (<_BoolectorNode> fun._params[pos]).width
    else:
        assert(fun._sort)
        assert(fun._sort._domain)
        sort = fun._sort._domain[pos]
        if isinstance(sort, _BoolectorBoolSort):
            return 1
        else:
            assert(isinstance(sort, _BoolectorBitVecSort))
            return (<_BoolectorBitVecSort> sort)._width

def _check_precond_shift(_BoolectorBVNode a, _BoolectorBVNode b):
    if not _is_power2(a.width):
        raise _BoolectorException(
                  "Bit width of operand 'a' must be a power of 2")
    if int(math.log(a.width, 2)) != b.width:
        raise _BoolectorException(
                  "Bit width of operand 'b' must be equal to "\
                  "log2(bit width of a)") 

def _check_precond_slice(_BoolectorBVNode a, int upper, int lower):
        if upper >= a.width:
            raise _BoolectorException(
                      "Upper limit of slice must be lower than the bit width "\
                      "of the bit vector")
        if lower < 0 or lower > upper:
            raise _BoolectorException("Lower limit must be within the bounds "\
                                      "of [upper:0]")

def _check_precond_cond(cond, a, b):
    if isinstance(cond, int) and (cond > 1 or cond < 0):
        raise _BoolectorException(
                  "'cond' needs to either boolean or an integer of 0 or 1")
    if not (isinstance(a, _BoolectorBVNode) or
            isinstance(b, _BoolectorBVNode)) and \
       not (isinstance(a, _BoolectorArrayNode) and
            isinstance(b, _BoolectorArrayNode)):
        raise _BoolectorException(
                  "At least one of the operands must be a bit vector")

# sort wrapper classes

cdef class _BoolectorSort:
    cdef Boolector btor
    cdef btorapi.Btor * _c_btor
    cdef btorapi.BoolectorSort * _c_sort

    def __init__(self, Boolector boolector):
        self.btor = boolector

    def __dealloc__(self):
        assert(self._c_sort is not NULL)
        btorapi.boolector_release_sort(self.btor._c_btor, self._c_sort)

cdef class _BoolectorFunSort(_BoolectorSort):
    cdef list _domain
    cdef _BoolectorSort _codomain

cdef class _BoolectorBitVecSort(_BoolectorSort):
    cdef int _width

cdef class _BoolectorBoolSort(_BoolectorSort):
    pass

# option wrapper classes

cdef class _BoolectorOptions:
    cdef Boolector btor
    cdef _BoolectorOpt __cur

    def __init__(self, Boolector btor):
        self.btor = btor
        self.__cur = _BoolectorOpt(btor,
                         _to_str(btorapi.boolector_first_opt(btor._c_btor)))

    def __iter__(self):
        return self

    def __next__(self):
        if self.__cur is None:
            raise StopIteration
        next = self.__cur
        name = _to_str(btorapi.boolector_next_opt(self.btor._c_btor,
                                                  next.__chptr._c_str))
        if name is None:
            self.__cur = None
        else:
            self.__cur = _BoolectorOpt(self.btor, name)
        return next


cdef class _BoolectorOpt:
    cdef Boolector btor
    cdef _ChPtr __chptr
    cdef str name

    def __init__(self, Boolector boolector, str name):
        self.btor = boolector
        self.name = name
        self.__chptr = _ChPtr(name)

    def __richcmp__(_BoolectorOpt opt0, _BoolectorOpt opt1, opcode):
        if opcode == 2:
            return opt0.name == opt1.name
        elif opcode == 3:
            return opt0.name != opt1.name
        else:
            raise _BoolectorException("Opcode '{}' not implemented for "\
                                     "__richcmp__".format(opcode))

    property shrt:
        def __get__(self):
            return _to_str(btorapi.boolector_get_opt_shrt(self.btor._c_btor,
                                                          self.__chptr._c_str))

    property lng:
        def __get__(self):
            return self.name

    property desc:
        def __get__(self):
            return _to_str(btorapi.boolector_get_opt_desc(self.btor._c_btor,
                                                          self.__chptr._c_str))

    property val:
        def __get__(self):
            return btorapi.boolector_get_opt_val(self.btor._c_btor,
                                                 self.__chptr._c_str)

    property dflt:
        def __get__(self):
            return btorapi.boolector_get_opt_dflt(self.btor._c_btor,
                                                  self.__chptr._c_str)

    property min:
        def __get__(self):
            return btorapi.boolector_get_opt_min(self.btor._c_btor,
                                                 self.__chptr._c_str)

    property max:
        def __get__(self):
            return btorapi.boolector_get_opt_max(self.btor._c_btor,
                                                 self.__chptr._c_str)

    property tunable:
        def __get__(self):
            return self.lng in g_tunable_options

    def __str__(self):
        return "{}, [{}, {}], default: {}".format(self.lng,
                                                      self.min, self.max,
                                                      self.dflt)
# wrapper classes for BoolectorNode

cdef class _BoolectorNode:
    cdef Boolector btor
    cdef btorapi.Btor * _c_btor
    cdef btorapi.BoolectorNode * _c_node

    def __init__(self, Boolector boolector):
        self.btor = boolector

    def __dealloc__(self):
        assert(self._c_node is not NULL)
        btorapi.boolector_release(self.btor._c_btor, self._c_node)

    def __richcmp__(_BoolectorNode x, _BoolectorNode y, opcode):
        if opcode == 2:
            return x.btor.Eq(x, y)
        elif opcode == 3:
            return x.btor.Ne(x, y)
        else:
            raise _BoolectorException("Opcode '{}' not implemented for "\
                                     "__richcmp__".format(opcode))

    property symbol:
        """ The symbol of a Boolector node.

            A node's symbol is used as a simple means of identfication,
            either when printing a model via 
            :func:`~boolector.Boolector.Print_model`,
            or generating file dumps via 
            :func:`~boolector.Boolector.Dump`.
        """
        def __get__(self):
            return _to_str(btorapi.boolector_get_symbol(self.btor._c_btor,
                                                        self._c_node))

        def __set__(self, str symbol):
            btorapi.boolector_set_symbol(self.btor._c_btor, self._c_node,
                                         _ChPtr(symbol)._c_str)

    property width:
        """ The bit width of a Boolector node.

            If the node is an array,
            this indicates the bit width of the array elements.
        """
        def __get__(self):
            return btorapi.boolector_get_width(self.btor._c_btor, self._c_node)

    property assignment:
        """ The assignment of a Boolector node.

            May be queried only after a preceding call to
            :func:`~boolector.Boolector.Sat` returned 
            :data:`~boolector.Boolector.SAT`.

            If the queried node is a bit vector, its assignment is 
            represented as string.
            If it is an array, its assignment is represented as a list
            of tuples ``(index, value)``.
            If it is a function, its assignment is represented as a list
            of tuples ``(arg_0, ..., arg_n, value)``.

        """
        def __get__(self):
            cdef char ** c_str_i
            cdef char ** c_str_v
            cdef int size
            cdef const char * c_str
            cdef bytes py_str

            if isinstance(self, _BoolectorFunNode) or \
               isinstance(self, _BoolectorArrayNode):
                if isinstance(self, _BoolectorArrayNode):
                    btorapi.boolector_array_assignment(
                        self.btor._c_btor, self._c_node, &c_str_i, &c_str_v,
                        &size) 
                else:
                    btorapi.boolector_uf_assignment(
                        self.btor._c_btor, self._c_node, &c_str_i, &c_str_v,
                        &size) 
                model = []
                if size > 0:
                    for i in range(size):
                        # TODO @mathias
                        # split index in case of functions
                        index = _to_str(c_str_i[i])
                        value = _to_str(c_str_v[i])
                        model.append((index, value))
                    if isinstance(self, _BoolectorArrayNode):
                        btorapi.boolector_free_array_assignment(
                            self.btor._c_btor, c_str_i, c_str_v, size) 
                    else:
                        btorapi.boolector_free_uf_assignment(
                            self.btor._c_btor, c_str_i, c_str_v, size) 
                return model
            else:
                c_str = \
                    btorapi.boolector_bv_assignment(self.btor._c_btor,
                                                       self._c_node)
                value = _to_str(c_str)
                btorapi.boolector_free_bv_assignment(self.btor._c_btor, c_str)
                return value

    def Dump(self, format = "btor", outfile = None):
        """ Dump (format = "btor", outfile)

            Dump node to output file.

            :param format: A file format identifier string (use "btor" for BTOR_, "smt1" for `SMT-LIB v1`_, and "smt2" for `SMT-LIB v2`_).
            :type format: str
            :param outile: Output file name (default: stdout).
            :type format: str.
            
        """
        cdef FILE * c_file

        if outfile is None:
            c_file = stdout
        else:
            if os.path.isfile(outfile):
                raise _BoolectorException(
                        "Outfile '{}' already exists".format(outfile)) 
            elif os.path.isdir(outfile):
                raise _BoolectorException(
                        "Outfile '{}' is a directory".format(outfile)) 
            c_file = fopen(_ChPtr(outfile)._c_str, "w")

        if format.lower() == "btor":
            btorapi.boolector_dump_btor_node(self.btor._c_btor, c_file,
                                             self._c_node)
        elif format.lower() == "smt1":
            btorapi.boolector_dump_smt1_node(self.btor._c_btor, c_file,
                                             self._c_node)
        elif format.lower() == "smt2":
            btorapi.boolector_dump_smt2_node(self.btor._c_btor, c_file,
                                             self._c_node)
        else:
            raise _BoolectorException("Invalid dump format '{}'".format(format)) 
        if outfile is not None:
            fclose(c_file)

cdef class _BoolectorBVNode(_BoolectorNode):

    property bits:
        def __get__(self):
            if not self.__is_const():
                raise _BoolectorException("Given node is not a constant")
            return _to_str(btorapi.boolector_get_bits(self.btor._c_btor,
                                                      self._c_node))
    def __is_const(self):
        return btorapi.boolector_is_const(self.btor._c_btor, self._c_node) == 1

    def __richcmp__(x, y, opcode):
        x, y = _to_node(x, y)
        b = (<_BoolectorBVNode> x).btor
        if opcode == 0:
            return b.Ult(x, y)
        elif opcode == 1:
            return b.Ulte(x, y)
        elif opcode == 2:
            return b.Eq(x, y)
        elif opcode == 3:
            return b.Ne(x, y)
        elif opcode == 4:
            return b.Ugt(x, y)
        elif opcode == 5:
            return b.Ugte(x, y)
        else:
            raise _BoolectorException("Opcode '{}' not implemented for "\
                                     "__richcmp__".format(opcode))

    def __neg__(self):
        return self.btor.Neg(self)

    def __invert__(self):
        return self.btor.Not(self)

    def __add__(x, y):
        x, y = _to_node(x, y)
        return (<_BoolectorBVNode> x).btor.Add(x, y)

    def __sub__(x, y):
        x, y = _to_node(x, y)
        return (<_BoolectorBVNode> x).btor.Sub(x, y)

    def __mul__(x, y):
        x, y = _to_node(x, y)
        return (<_BoolectorBVNode> x).btor.Mul(x, y)

    def __truediv__(x, y):
        x, y = _to_node(x, y)
        return (<_BoolectorBVNode> x).btor.Udiv(x, y)

    def __mod__(x, y):
        x, y = _to_node(x, y)
        return (<_BoolectorBVNode> x).btor.Urem(x, y)

    def __lshift__(_BoolectorBVNode x, y):
        return x.btor.Sll(x, y)

    def __rshift__(_BoolectorBVNode x, y):
        return x.btor.Srl(x, y)

    def __and__(x, y):
        x, y = _to_node(x, y)
        return (<_BoolectorBVNode> x).btor.And(x, y)

    def __or__(x, y):
        x, y = _to_node(x, y)
        return (<_BoolectorBVNode> x).btor.Or(x, y)

    def __xor__(x, y):
        x, y = _to_node(x, y)
        return (<_BoolectorBVNode> x).btor.Xor(x, y)

    def __getitem__(self, x):
        # Use python slice notation for bit vector slicing
        if isinstance(x, slice):
            upper = x.start
            lower = x.stop
            if x.step is not None:
                raise _BoolectorException(
                          "Step of 'slice' not suppored on bit vectors")
            if upper is None:
                upper = self.width - 1
            if lower is None:
                lower = 0
            if not isinstance(upper, int):
                raise _BoolectorException(
                          "Upper limit of slice must be an integer")
            if not isinstance(lower, int):
                raise _BoolectorException(
                          "Lower limit of slice must be an integer")
            return self.btor.Slice(self, upper, lower)
        # Extract single bit
        elif isinstance(x, int):
            return self.btor.Slice(self, x, x)
        else:
            raise _BoolectorException("Expected 'int' or 'slice'")


cdef class _BoolectorArrayNode(_BoolectorNode):
    # TODO: allow slices on arrays
    #       array[2:4] -> memcpy from index 2 to 4 
    #       array[:] -> copy whole array
    def __getitem__(self, index):
        return self.btor.Read(self, index)

    property index_width:
        def __get__(self):
            return btorapi.boolector_get_index_width(self.btor._c_btor,
                       self._c_node)


cdef class _BoolectorFunNode(_BoolectorNode):
    cdef list _params
    cdef _BoolectorFunSort _sort

    def __call__(self, *args):
        return self.btor.Apply(list(args), self)

    property arity:
        def __get__(self):
            return \
                btorapi.boolector_get_fun_arity(self.btor._c_btor, self._c_node)


cdef class _BoolectorParamNode(_BoolectorBVNode):
    pass

# wrapper class for Boolector itself

cdef class Boolector:
    """
    The class representing a Boolector instance.
    """
    cdef btorapi.Btor * _c_btor

    UNKNOWN = 0
    SAT = 10
    UNSAT = 20
    PARSE_ERROR = 1

    def __init__(self, Boolector parent = None):
        if parent is None:
            self._c_btor = btorapi.boolector_new()
        else:
            self._c_btor = btorapi.boolector_clone(parent._c_btor)
        if self._c_btor is NULL:
            raise MemoryError()

    def __dealloc__(self):
        if self._c_btor is not NULL:
            btorapi.boolector_delete(self._c_btor)

    # Boolector API functions (general)

    def Assert(self, _BoolectorNode n):
        """ Assert(n)

            Add a constraint. 
            
            Use this function to assert node ``n``.
            Added constraints can not be removed.

            :param n: Bit vector expression with bit width 1.
            :type n:  :class:`~boolector._BoolectorNode`
        """
        if n.width > 1:
            raise _BoolectorException("Asserted term must be of bit width one")
        btorapi.boolector_assert(self._c_btor, n._c_node)

    def Assume(self, _BoolectorNode n):
        """ Assume(n)

            Add an assumption.
            
            Use this function to assume node ``n``.
            You must enable Boolector's incremental usage via 
            :func:`~boolector.Boolector.Set_opt` before you can add
            assumptions.
            In contrast to assertions added via 
            :func:`~boolector.Boolector.Assert`, assumptions
            are discarded after each call to :func:`~boolector.Boolector.Sat`.
            Assumptions and assertions are logicall combined via Boolean
            *and*. 
            Assumption handling in Boolector is analogous to assumptions
            in MiniSAT.

            :param n: Bit vector expression with bit width 1.
            :type n:  :class:`~boolector._BoolectorNode`
        """
        if n.width > 1:
            raise _BoolectorException("Assumed termed must be of bit width one")
        btorapi.boolector_assume(self._c_btor, n._c_node)

    def Failed(self, _BoolectorNode n):
        """ Failed(n)

            Determine if assumption ``n`` is a failed assumption.

            Failed assumptions are those assumptions, that force an
            input formula to become unsatisfiable.
            Failed assumptions handling in Boolector is analogous to 
            failed assumptions in MiniSAT.

            See :func:`~boolector.Boolector.Assume`.

            :param n: Bit vector expression with bit width 1.
            :type n:  :class:`~boolector._BoolectorNode`
            :return:  1 if assumption is failed, and 0 otherwise.
            :rtype:   int
        """
        if n.width > 1:
            raise _BoolectorException("Term must be of bit width one")
        return btorapi.boolector_failed(self._c_btor, n._c_node) == 1

    def Sat(self, int lod_limit = -1, int sat_limit = -1):
        """ Sat (lod_limit = -1, sat_limit = -1)

            Solve an input formula.

            An input formula is defined by constraints added via
            :func:`~boolector.Boolector.Assert`.
            You can guide the search for a solution to an input formula by
            making assumptions via :func:`~boolector.Boolector.Assume`.
            Note that assertions and assumptions are combined via Boolean
            *and*.

            If you want to call this function multiple times, you must
            enable Boolector's incremental usage mode via 
            :func:`~boolector.Boolector.Set_opt`.
            Otherwise, this function may only be called once.

            You can limit the search by the number of lemmas generated
            (``lod_limit``) and the number of conflicts encountered by
            the underlying SAT solver (``sat_limit``).

            See :data:`~boolector._BoolectorNode.assignment`. 

            :param lod_limit: Limit for Lemmas on Demand (-1: unlimited).
            :type lod_limit:  int
            :param sat_limit: Conflict limit for the SAT solver (-1: unlimited).
            :type sat_limit:  int
            :return: :data:`~boolector.Boolector.SAT` if the input formula is satisfiable (under possibly given assumptions), :data:`~boolector.Boolector.UNSAT` if it is unsatisfiable, and :data:`~boolector.Boolector.UNKNOWN` if the instance could not be solved within given limits.

        """
        if lod_limit > 0 or sat_limit > 0:
            return btorapi.boolector_limited_sat(self._c_btor, lod_limit,
                                                 sat_limit)
        return btorapi.boolector_sat(self._c_btor)

    def Simplify(self):
        """ Simplify()

            Simplify current input formula.

            Note that each call to :func:`~boolector.Boolector.Sat` 
            simplifies the input formula as a preprocessing step.

            :return: :data:`~boolector.Boolector.SAT` if the input formula was simplified to true, :data:`~boolector.Boolector.UNSAT` if it was simplified to false, and :data:`~boolector.Boolector.UNKNOWN`, otherwise.
        """
        return btorapi.boolector_simplify(self._c_btor)

    def Clone(self):
        """ Clone()

            Clone an instance of Boolector.

            The resulting Boolector instance is an exact (but disjunct)
            copy of its parent instance.
            Consequently, in a clone and its parent, nodes with the same
            id correspond to each other.
            Use :func:`~boolector.Boolector.Match` to match
            corresponding nodes.

            :return: The exact (but disjunct) copy of a Boolector instance.
            :rtype: :class:`~boolector.Boolector`

        """
        return Boolector(self)

    # BoolectorNode methods
    def Match(self, _BoolectorNode n):
        """ Match(n)

            Retrieve the node matching given node ``n`` by id.

            This is intended to be used for handling expressions of a 
            cloned instance (see :func:`~boolector.Boolector.Clone`).

            :param n: Boolector node.
            :type n:  :class:`~boolector._BoolectorNode`
            :return:  The Boolector node that matches given node ``n`` by id.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        node_type = type(n)
        r = node_type(self)
        (<_BoolectorNode> r)._c_node = \
            btorapi.boolector_match_node(self._c_btor, n._c_node)
        if (<_BoolectorNode> r)._c_node is NULL:
            raise _BoolectorException("Could not match given node 'n'")
        return r

    # Boolector options
    def Set_opt(self, str opt, int value):
        """ Set_opt(opt, value).

            Set option.

            List of available options:

            * **model_gen**

              | Enable (``value``: 1 or 2) or disable (``value``: 0) generation of a model for satisfiable instances. 
              | There are two modes for model generation: 

              * generate model for asserted expressions only (``value``: 1)
              * generate model for all expressions (``value``: 2).

            * **incremental**

              | Enable (``value``: 1) incremental mode.
              | Note that incremental usage turns off some optimization techniques. Disabling incremental usage is currently not supported.

            * **incremental_all**

              | Enable (``value``: 1) or disable (``value``: 0) incremental solving of all formulas when parsin an input file.
              | Note that currently, incremental mode while parsing an input file is only supported for `SMT-LIB v1`_ input.

            * **incremental_in_depth**

              | Set incremental in-depth mode width (``value``: int) when parsing an input file.
              | Note that currently, incremental mode while parsing an input file is only supported for `SMT-LIB v1`_ input.  

            * **incremental_look_ahead**

              | Set incremental look_ahead mode width (``value``: int) when parsing an input file.
              | Note that currently, incremental mode while parsing an input file is only supported for `SMT-LIB v1`_ input.
               
            * **incremental_interval**

              | Set incremental interval mode width (``value``: int) when parsing an input file.
              | Note that currently, incremental mode while parsing an input file is only supported for `SMT-LIB v1`_ input.

            * **input_format**
              
              | Force input file format (``value``: `BTOR <http://fmv.jku.at/papers/BrummayerBiereLonsing-BPR08.pdf>`_: -1, `SMT-LIB v1 <http://smtlib.cs.uiowa.edu/papers/format-v1.2-r06.08.30.pdf>`_: 1, `SMT-LIB v2 <http://smtlib.cs.uiowa.edu/papers/smt-lib-reference-v2.0-r12.09.09.pdf>`_: 2) when parsing an input file.
              | If unspecified, Boolector automatically detects the input file format while parsing.

            * **output_number_format**

              | Force output number format (``value``: binary: 0, hexadecimal: 1, decimal: 2):
              | Boolector uses binary by default.

            * **output_format**
          
              | Force output file format (``value``: BTOR_: -1, `SMT-LIB v1`_: 1, `SMT-LIB v2`_: 2).
              | Boolector uses BTOR_ by default.

            * **rewrite_level**

              | Set the rewrite level (``value``: 0-3) of the rewriting engine.
              | Boolector uses rewrite level 3 by default, rewrite levels are classified as follows:

              * 0: no rewriting
              * 1: term level rewriting
              * 2: more simplification techniques
              * 3: full rewriting/simplification

              | Do not alter the rewrite level of the rewriting engine after creating expressions.

            * **rewrite_level_pbr**

              | Set the rewrite level (``value``: 0-3) for partial beta reduction.
              | Boolector uses rewrite level 1 by default. Rewrite levels are classified as above.

            * **beta_reduce_all**
              
              Enable (``value``: 1) or disable (``value``: 0) the eager
              elimination of lambda expressions via beta reduction.

            * **probe_beta_reduce_all**

              Enable (``value``: 1) or disable (``value``: 0) probing of
              *beta_reduce_all* until a given lemmas on demand
              (*pbr_lod_limit*) or SAT conflicts limit (*pbra_sat_limit*).

            * **pbra_lod_limit**

              Set lemmas on demand limit for *probe_beta_reduce_all*.

            * **pbra_sat_limit**

              Set SAT conflicts limit for *probe_beta_reduce_all*.

            * **pbra_ops_factor**

              Set factor by which the size of the beta reduced formula may be
              greater than the original formula (for *probe_beta_reduce_all*).

            * **dual_prop**

              Enable (``value``: 1) or disable (``value``: 0) dual propagation
              optimization.

            * **just**

              Enable (``value``: 1) or disable (``value``: 0) justification
              optimization.
              
            * **ucopt**

              Enable (``value``: 1) or disable (``value``: 0) unconstrained
              optimization.

            * **lazy_synthesize**

              Enable (``value``: 1) or disable (``value``: 0) lazy synthesis of
              bit vector expressions.

            * **eliminate_slices**

              Enable (``value``: 1) or disable (``value``: 0) slice elimination
              on bit vector variables.

            * **pretty_print**

              Enable (``value``: 1) or disable (``value``: 0) pretty printing
              when dumping.

            * **verbosity**

              Set the level of verbosity.

            :param opt:   Option name.
            :type opt:    str
            :param value: Option value.
            :type value:  int
        """
        btorapi.boolector_set_opt(self._c_btor, _ChPtr(opt)._c_str, value)

    def Get_opt(self, str opt):
    # TODO docstring
        return _BoolectorOpt(self, opt)

    def Options(self):
    # TODO docstring
        return _BoolectorOptions(self)

    def Set_sat_solver(self, str solver, str optstr = None, int nofork = 0):
    # TODO docstring
        solver = solver.strip().lower()
        if solver == "lingeling":
            btorapi.boolector_set_sat_solver_lingeling(self._c_btor,
                                                       _ChPtr(optstr)._c_str,
                                                       nofork)
        else:
            btorapi.boolector_set_sat_solver(self._c_btor,
                                             _ChPtr(solver)._c_str)

    def Set_msg_prefix(self, str prefix):
        """ Set_msg_prefix(prefix)

            Set a verbosity message prefix.

            :param prefix: Prefix string.
            :type prefix: str
        """
        btorapi.boolector_set_msg_prefix(self._c_btor, _ChPtr(prefix)._c_str)

    def Print_model(self, outfile = None):
        """ Print_model(outfile = None)
  
            Print model to output file.

            This function prints the model for all inputs to output file
            ``outfile``.

            :param outfile: Output file name (default: stdout).
            :type outfile:  str
        """
        cdef FILE * c_file

        if outfile is None:
            c_file = stdout
        else:
            if os.path.isfile(outfile):
                raise _BoolectorException(
                        "Outfile '{}' already exists".format(outfile)) 
            elif os.path.isdir(outfile):
                raise _BoolectorException(
                        "Outfile '{}' is a directory".format(outfile)) 
            c_file = fopen(_ChPtr(outfile)._c_str, "w")

        btorapi.boolector_print_model(self._c_btor, c_file)

        if outfile is not None:
            fclose(c_file)

    def Parse(self, str file):
        """ Parse(file)

            Parse input file.

            Input file format may be either BTOR_, `SMT-LIB v1`_, or
            `SMT-LIB v2`_, the file type is detected automatically.

            :param file: Input file name.
            :type file:  str
            :return: A tuple (result, status, error_msg), where return value ``result`` indicates an error (:data:`~boolector.Boolector.PARSE_ERROR`) if any, and else denotes the satisfiability result (:data:`~boolector.Boolector.SAT` or :data:`~boolector.Boolector.UNSAT`) in the incremental case, and :data:`~boolector.Boolector.UNKNOWN` otherwise. Return value ``status`` indicates a (known) status (:data:`~boolector.Boolector.SAT` or :data:`~boolector.Boolector.UNSAT`) as specified in the input file. In case of an error, an explanation of that error is stored in ``error_msg``.
        """
        cdef FILE * c_file
        cdef int res
        cdef char * err_msg
        cdef int status

        if not os.path.isfile(file):
            raise _BoolectorException("File '{}' does not exist".format(file))

        c_file = fopen(_ChPtr(file)._c_str, "r")
        res = btorapi.boolector_parse(self._c_btor, c_file, _ChPtr(file)._c_str,
                                      &err_msg, &status)
        fclose(c_file)
        return (res, status, _to_str(err_msg))

    def Dump(self, format = "btor", outfile = None):
        """ Dump(format = "btor", outfile = None)

            Dump input formula to output file.

            :param format: A file format identifier string (use "btor" for BTOR_, "smt1" for `SMT-LIB v1`_, and "smt2" for `SMT-LIB v2`_).
            :type format: str
            :param outile: Output file name (default: stdout).
            :type format: str.

        """
        cdef FILE * c_file

        if outfile is None:
            c_file = stdout
        else:
            if os.path.isfile(outfile):
                raise _BoolectorException(
                        "Outfile '{}' already exists".format(outfile)) 
            elif os.path.isdir(outfile):
                raise _BoolectorException(
                        "Outfile '{}' is a directory".format(outfile)) 
            c_file = fopen(_ChPtr(outfile)._c_str, "w")

        if format.lower() == "btor":
            btorapi.boolector_dump_btor(self._c_btor, c_file)
        elif format.lower() == "smt1":
            btorapi.boolector_dump_smt1(self._c_btor, c_file)
        elif format.lower() == "smt2":
            btorapi.boolector_dump_smt2(self._c_btor, c_file)
        else:
            raise _BoolectorException("Invalid dump format '{}'".format(format)) 
        if outfile is not None:
            fclose(c_file)

    # Boolector nodes

    def Const(self, c, int width = 1):
        """ Const(c, width = 1)
        
            Create a bit vector constant of value ``c`` and bit width ``width``.

            :param c: Value of the constant.
            :type  c: int, bool, str, _BoolectorNode
            :param width: Bit width of the constant.
            :type width:  int
            :return: A bit vector constant of value ``c`` and bit width ``width``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        cdef _BoolectorBVNode r
        if isinstance(c, int):
            if c != 0 and c.bit_length() > width:
                raise _BoolectorException(
                          "Value of constant {} (bit width {}) exceeds bit "\
                          "width of {}".format(c, c.bit_length(), width))
            const_str = "{{0:0>{}b}}".format(width).format(abs(c))
            r = _BoolectorBVNode(self)
            r._c_node = \
                btorapi.boolector_const(self._c_btor, _ChPtr(const_str)._c_str)
            if c < 0:
                r = -r
            return r
        elif isinstance(c, bool):
            r = _BoolectorBVNode(self)
            if c:
                r._c_node = btorapi.boolector_true(self._c_btor)
            else:
                r._c_node = btorapi.boolector_false(self._c_btor)
            return r
        elif isinstance(c, str):
            try:
                int(c, 2)
            except ValueError:
                raise _BoolectorException("Given constant string is not in"\
                                          "binary format")
            r = _BoolectorBVNode(self)
            r._c_node = \
                btorapi.boolector_const(self._c_btor, _ChPtr(c)._c_str)
            return r
        elif isinstance(c, _BoolectorNode):
            return c 
        else:
            raise _BoolectorException(
                      "Cannot convert type '{}' to bit vector".format(
                          type(c)))

    def Var(self, int width, str symbol = None):
        """ Var(width, symbol = None)

            Create a bit vector variable with bit width ``width``.

            Note that in contrast to composite expressions, which are 
            maintained uniquely w.r.t. to their kind, inputs (and consequently,
            bit width), variables are not.
            Hence, each call to this function returns a fresh bit vector
            variable.

            A variable's symbol is used as a simple means of identfication,
            either when printing a model via 
            :func:`~boolector.Boolector.Print_model`,
            or generating file dumps via 
            :func:`~boolector.Boolector.Dump`.
            Note that a symbol must be unique but may be None in case that no
            symbol should be assigned.
            
            :param width: Bit width of the variable.
            :type width: int
            :param symbol: Symbol of the variable.
            :type symbol: str
            :return: A bit vector variable with bit width ``width``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_var(self._c_btor, width,
                                          _ChPtr(symbol)._c_str)
        return r

    def Param(self, int width, str symbol = None):
        """ Param(width, symbol = None)

            Create a function parameter with bit width ``width``.

            This kind of node is used to create parameterized expressions,
            which in turn are used to create functions.
            Once a parameter is bound to a function, it cannot be reused in
            other functions.

            See :func:`~boolector.Boolector.Fun`, 
            :func:`~boolector.Boolector.Apply`.
            
            :param width: Bit width of the function parameter.
            :type width: int
            :param symbol: Symbol of the function parameter.
            :type symbol: str
            :return: A function parameter with bit width ``width``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        r = _BoolectorParamNode(self)
        r._c_node = btorapi.boolector_param(self._c_btor, width,
                                            _ChPtr(symbol)._c_str)
        return r

    def Array(self, int elem_width, int index_width, str symbol = None):
        """ Array(elem_width, index_width, symbol = None)

            Create a one-dimensional bit vector array variable of size
            2** ``index_width`` with elements of bit width ``elem_width``.

            Note that in contrast to composite expressions, which are 
            maintained uniquely w.r.t. to their kind, inputs (and consequently,
            bit width), array variables are not.
            Hence, each call to this function returns a fresh bit vector
            array variable.

            An array variable's symbol is used as a simple means of
            identfication, either when printing a model via 
            :func:`~boolector.Boolector.Print_model`,
            or generating file dumps via 
            :func:`~boolector.Boolector.Dump`.
            Note that a symbol must be unique but may be None in case that no
            symbol should be assigned.
            
            :param width: Bit width of the variable.
            :type width: int
            :param symbol: Symbol of the variable.
            :type symbol: str
            :return: An array variable of size 2** ``index_width`` with elements of bit width ``elem_width``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        r = _BoolectorArrayNode(self)
        r._c_node = btorapi.boolector_array(self._c_btor, elem_width,
                                            index_width, _ChPtr(symbol)._c_str)
        return r

    # Unary operators

    def Not(self, _BoolectorBVNode n):
        """ Not(n)

            Create the one's complement of bit vector node ``n``.

            :param n: A bit vector node.
            :type n:  :class:`~boolector._BoolectorNode`
            :return:  The one's complement of bit vector node ``n``.
            :rtype:  :class:`~boolector._BoolectorNode`
        """
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_not(self._c_btor, n._c_node)
        return r

    def Neg(self, _BoolectorBVNode n):
        """ Neg(n)

            Create the two's complement of bit vector node ``n``.

            :param n: A bit vector node.
            :type n:  :class:`~boolector._BoolectorNode`
            :return:  The two's complement of bit vector node ``n``.
            :rtype: :class:`~boolector._BoolectorNode`
            """
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_neg(self._c_btor, n._c_node)
        return r

    def Redor(self, _BoolectorBVNode n):
        """ Redor(n)

            Create an *or* reduction of node ``n``.

            All bits of node ``n`` are combined by an Boolean *or*.

            :param n: A bit vector node.
            :type n:  :class:`~boolector._BoolectorNode`
            :return:  The *or* reduction of node ``n``.
            :rtype: :class:`~boolector._BoolectorNode`
            """
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_redor(self._c_btor, n._c_node)
        return r

    def Redxor(self, _BoolectorBVNode n):
        """ Redxor(n)

            Create an *xor* reduction of node ``n``.

            All bits of node ``n`` are combined by an Boolean *xor*.

            :param n: A bit vector node.
            :type n:  :class:`~boolector._BoolectorNode`
            :return:  The *xor* reduction of node ``n``.
            :rtype: :class:`~boolector._BoolectorNode`
            """
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_redxor(self._c_btor, n._c_node)
        return r

    def Redand(self, _BoolectorBVNode n):
        """ Redand(n)

            Create an *and* reduction of node ``n``.

            All bits of node ``n`` are combined by an Boolean *and*.

            :param n: A bit vector node.
            :type n:  :class:`~boolector._BoolectorNode`
            :return:  The *and* reduction of node ``n``.
            :rtype: :class:`~boolector._BoolectorNode`
            """
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_redand(self._c_btor, n._c_node)
        return r

    def Slice(self, _BoolectorBVNode n, int upper, int lower):
        """ Slice(n, upper, lower)

            Create a bit vector slice of node ``n`` from index ``uppper``
            to index ``lower``.

            :param n: A bit vector node.
            :type n:  :class:`~boolector._BoolectorNode`
            :param upper: Upper index, which must be greater than or equal to zero, and less than the bit width of node ``n``.
            :type upper: int
            :param lower: Lower index, which must be greater than or equal to zero, and less than or equal to ``upper``.
            :type lower: int
            :return: A Bit vector with bit width ``upper`` - ``lower`` + 1.
            :rtype: :class:`~boolector._BoolectorNode`
            """
        _check_precond_slice(n, upper, lower)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_slice(self._c_btor, n._c_node,
                                            upper, lower)
        return r
                                                                
    def Uext(self, _BoolectorBVNode n, int width):
        """ Uext(n, width)

            Create unsigned extension.

            Bit vector node ``n`` is padded with ``width`` zeroes.

            :param n: A bit vector node.
            :type n:  :class:`~boolector._BoolectorNode`
            :param width: Number of zeros to pad.
            :type width: int
            :return: A bit vector extended by ``width`` zeroes.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_uext(self._c_btor, n._c_node, width)
        return r

    def Sext(self, _BoolectorBVNode n, int width):
        """ Sext(n, width)

            Create signed extension.

            Bit vector node ``n`` is padded with ``width`` bits, where the 
            padded value depends on the value of the most significant bit
            of node ``n``.

            :param n: A bit vector node.
            :type n:  :class:`~boolector._BoolectorNode`
            :param width: Number of bits to pad.
            :type width: int
            :return: A bit vector extended by ``width`` bits.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_sext(self._c_btor, n._c_node, width)
        return r

    def Inc(self, _BoolectorBVNode n):
        """ Inc(n)

            Create a bit vector expression that increments bit vector ``n``
            by one.

            :param n: A bit vector node.
            :type n:  :class:`~boolector._BoolectorNode`
            :return: A bit vector with the same bit width as ``n``, incremented by one.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_inc(self._c_btor, n._c_node)
        return r

    def Dec(self, _BoolectorBVNode n):
        """ Dec(n)

            Create a bit vector expression that decrements bit vector ``n``
            by one.

            :param n: A bit vector node.
            :type n:  :class:`~boolector._BoolectorNode`
            :return: A bit vector with the same bit width as ``n``, decremented by one.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_dec(self._c_btor, n._c_node)
        return r

    # Binary operators

    def Implies(self, a, b):
        """ Implies(a, b)
          
            Create a Boolean implication.

            Parameters ``a`` and ``b`` must have bit width one.

            :param a: Bit vector node representing the premise.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Bit vector node representing the conclusion.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A Boolean implication ``a`` => ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_implies(self._c_btor,
                                              _c_node(a), _c_node(b))
        return r

    def Iff(self, a, b):
        """ Iff(a, b)
          
            Create a Boolean equivalence.

            Parameters ``a`` and ``b`` must have bit width one.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A Boolean equivalence ``a`` <=> ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_iff(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Xor(self, a, b):
        """ Xor(a, b)
          
            Create a bit vector *xor*.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_xor(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Xnor(self, a, b):
        """ Xnor(a, b)
          
            Create a bit vector *xnor*.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_xnor(self._c_btor, _c_node(a), _c_node(b))
        return r

    def And(self, a, b):
        """ And(a, b)
          
            Create a bit vector *and*.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_and(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Nand(self, a, b):
        """ Nand(a, b)
          
            Create a bit vector *nand*.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_nand(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Or(self, a, b):
        """ Or(a, b)
          
            Create a bit vector *or*.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_or(self._c_btor,
                                         _c_node(a), _c_node(b))
        return r

    def Nor(self, a, b):
        """ Nor(a, b)
          
            Create a bit vector *nor*.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_nor(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Eq(self, a, b):
        """ Eq(a, b)
          
            Create a bit vector or array equality.

            Parameters ``a`` and ``b`` are either bit vectors with the same bit
            width, or arrays of the same type.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_eq(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Ne(self, a, b):
        """ Ne(a, b)
          
            Create a bit vector or array inequality.

            Parameters ``a`` and ``b`` are either bit vectors with the same bit
            width, or arrays of the same type.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_ne(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Add(self, a, b):
        """ Add(a, b)
          
            Create a bit vector addition.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_add(self._c_btor, _c_node(a),
                                          _c_node(b))
        return r

    def Uaddo(self, a, b):
        """ Uaddo(a, b)
          
            Create an unsigned  bit vector addition overflow detection.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one, which indicates if the addition of ``a`` and ``b`` overflows in case both operands are treated as unsigned.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_uaddo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Saddo(self, a, b):
        """ Saddo(a, b)
          
            Create an signed  bit vector addition overflow detection.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one, which indicates if the addition of ``a`` and ``b`` overflows in case both operands are treated as signed.
            :rtype: :class:`~boolector._BoolectorNode`
            """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_saddo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Mul(self, a, b):
        """ Mul(a, b)
          
            Create a bit vector multiplication.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_mul(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Umulo(self, a, b):
        """ Umulo(a, b)
          
            Create an unsigned  bit vector multiplication overflow detection.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one, which indicates if the multiplication of ``a`` and ``b`` overflows in case both operands are treated as unsigned.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_umulo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Smulo(self, a, b):
        """ Smulo(a, b)
          
            Create an signed  bit vector multiplication overflow detection.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one, which indicates if the multiplication of ``a`` and ``b`` overflows in case both operands are treated as signed.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_smulo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Ult(self, a, b):
        """ Ult(a, b)
          
            Create an unsigned less than.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_ult(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Slt(self, a, b):
        """ Slt(a, b)
          
            Create an signed less than.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_slt(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Ulte(self, a, b):
        """ Ulte(a, b)
          
            Create an unsigned less than or equal.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_ulte(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Slte(self, a, b):
        """ Slte(a, b)
          
            Create an signed less than or equal.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_slte(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Ugt(self, a, b):
        """ Ugt(a, b)
          
            Create an unsigned greater than.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_ugt(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Sgt(self, a, b):
        """ Sgt(a, b)
          
            Create an signed greater than.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_sgt(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Ugte(self, a, b):
        """ Ugte(a, b)
          
            Create an unsigned greater than or equal.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_ugte(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Sgte(self, a, b):
        """ Sgte(a, b)
          
            Create an signed greater than or equal.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_sgte(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Sll(self, _BoolectorBVNode a, b):
        """ Sll(a, b)
          
            Create a logical shift left.

            Given bit vector node ``b``, the value it represents is the 
            number of zeroes shifted into node ``a`` from the right.

            :param a: First bit vector operand where the bit width is a power of two and greater than 1.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand with bit width log2 of the bit width of ``a``..
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        b = self.Const(b, math.ceil(math.log(a.width, 2)))
        _check_precond_shift(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_sll(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Srl(self, _BoolectorBVNode a, b):
        """ Srl(a, b)
          
            Create a logical shift right.

            Given bit vector node ``b``, the value it represents is the 
            number of zeroes shifted into node ``a`` from the left.

            :param a: First bit vector operand where the bit width is a power of two and greater than 1.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand with bit width log2 of the bit width of ``a``..
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        b = self.Const(b, math.ceil(math.log(a.width, 2)))
        _check_precond_shift(a, b)
        _check_precond_shift(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_srl(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Sra(self, _BoolectorBVNode a, b):
        """ Sra(a, b)
          
            Create an arithmetic shift right.

            Analogously to :func:`~boolector.Boolector.Srl`, but whether
            zeroes or ones are shifted in depends on the most significant
            bit of node ``a``.

            :param a: First bit vector operand where the bit width is a power of two and greater than 1.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand with bit width log2 of the bit width of ``a``..
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        b = self.Const(b, math.ceil(math.log(a.width, 2)))
        _check_precond_shift(a, b)
        _check_precond_shift(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_sra(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Rol(self, _BoolectorBVNode a, b):
        """ Rol(a, b)
          
            Create a rotate left.

            Given bit vector node ``b``, the value it represents is the 
            number of bits by which node ``a`` is rotated to the left.

            :param a: First bit vector operand where the bit width is a power of two and greater than 1.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand with bit width log2 of the bit width of ``a``..
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        b = self.Const(b, math.ceil(math.log(a.width, 2)))
        _check_precond_shift(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_rol(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Ror(self, _BoolectorBVNode a, b):
        """ Ror(a, b)
          
            Create a rotate right.

            Given bit vector node ``b``, the value it represents is the 
            number of bits by which node ``a`` is rotated to the right.

            :param a: First bit vector operand where the bit width is a power of two and greater than 1.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand with bit width log2 of the bit width of ``a``..
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        b = self.Const(b, math.ceil(math.log(a.width, 2)))
        _check_precond_shift(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_ror(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Sub(self, a, b):
        """ Sub(a, b)
          
            Create a bit vector subtraction.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_sub(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Usubo(self, a, b):
        """ Usubo(a, b)
          
            Create an unsigned  bit vector subtraction overflow detection.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one, which indicates if the subtraction of ``a`` and ``b`` overflows in case both operands are treated as unsigned.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_usubo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Ssubo(self, a, b):
        """ Ssubo(a, b)
          
            Create a signed  bit vector subtraction overflow detection.

            Parameters ``a`` and ``b`` must have the same bit width.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one, which indicates if the subtraction of ``a`` and ``b`` overflows in case both operands are treated as signed.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_ssubo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Udiv(self, a, b):
        """ Udiv(a, b)
          
            Create an unsigned  bit vector division.

            Parameters ``a`` and ``b`` must have the same bit width.
            If ``a`` is 0, the division's result is -1.

            Note that this behavior (division by zero returns -1) does not
            exactly comply with the SMT-LIB v1 and v2 standards, where division
            by zero is handled as an uninterpreted function.
            Our semantics are motivated by real circuits where division by zero
            cannot be uninterpreted and consequently returns a result.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_udiv(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Sdiv(self, a, b):
        """ Sdiv(a, b)
          
            Create a signed  bit vector division.

            Parameters ``a`` and ``b`` must have the same bit width.
            
            Note that signed division is expressed by means of unsigned
            division, where either node is normalized in case that its 
            sign bit is 1. 
            If the sign bits of ``a`` and ``b`` do not match, two's complement
            is performed on the result of the previous unsigned division.
            Hence, the behavior in case of a division by zero depends on
            :func:`~boolector.Boolector.Udiv`.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_sdiv(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Sdivo(self, a, b):
        """ Sdivo(a, b)
          
            Create a signed  bit vector division overflow detection.

            Parameters ``a`` and ``b`` must have the same bit width.
            An overflow can occur, if ``a`` represents INT_MIN and ``b``
            represents -1.

            Note that unsigned bit vector division does not overflow.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bit width one, which indicates if the division of ``a`` and ``b`` overflows in case both operands are treated as signed.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_sdivo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Urem(self, a, b):
        """ Urem(a, b)
          
            Create an unsigned remainder.

            Parameters ``a`` and ``b`` must have the same bit width.
            If ``b`` is 0, the result of the unsigned remainder is ``a``.
            
            As in :func:`~boolector.Boolector.Udiv`, the behavior if ``b``
            is 0 does not exactly comply to the SMT-LIB v1 and v2 standards,
            where the result ist handled as uninterpreted function.
            Our semantics are motivated by real circuits, where result 
            can not be uninterpreted.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_urem(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Srem(self, a, b):
        """ Srem(a, b)
          
            Create a signed remainder.

            Parameters ``a`` and ``b`` must have the same bit width.
            If ``b`` is 0, the result of the unsigned remainder is ``a``.
            
            Analogously to :func:`~boolector.Boolector.Sdiv`, the signed
            remainder is expressed by means of the unsigned remainder,
            where either node is normalized in case that its sign bit is 1. 
            Hence, in case that ``b`` is zero, the result depends on
            :func:`~boolector.Boolector.Urem`.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_srem(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Smod(self, a, b):
        """ Smod(a, b)
          
            Create a signed remainder where its sign matches the sign of the
            divisor.

            Parameters ``a`` and ``b`` must have the same bit width.
            
            If ``b`` is zero, the result depends on 
            :func:`~boolector.Boolector.Urem`.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bit width as ``a`` and ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_smod(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Concat(self, _BoolectorBVNode a, _BoolectorBVNode b):
        """ Concat(a,b)
          
            Create the concatenation of two bit vectors.

            :param a: First bit vector operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Second bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with bitwidth ``bit width of a + bit width of b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_concat(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Read(self, _BoolectorArrayNode a, b):

        """ Read(a,b)
          
            Create a read on array ``a`` at position ``b``.

            :param a: Array operand.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Bit vector operand.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  A bit vector node with the same bitwidth as the elements of array ``a``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        b = self.Const(b, a.index_width)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_read(self._c_btor, _c_node(a), _c_node(b))
        return r

    # Ternary operators

    def Write(self, _BoolectorArrayNode array, index, value):
        """ Write(array,index, value)
          
            Create a read on array ``array`` at position ``index`` with value
            ``value``.

            The array is updated at exactly one position, all other elements
            remain unchanged.
            The bit width of ``index`` must be the same as the bit width of 
            the indices of ``array``.
            The bit width of ``value`` must be the same as the bit width of
            the elements of ``array``.

            :param array: Array operand.
            :type array:  :class:`~boolector._BoolectorNode`
            :param index: Bit vector index.
            :type index:  :class:`~boolector._BoolectorNode`
            :param value: Bit vector value.
            :type value:  :class:`~boolector._BoolectorNode`
            :return:  An array where the value at ``index`` has been updated with ``value``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        index = self.Const(index, array.index_width)
        value = self.Const(value, array.width)

        r = _BoolectorArrayNode(self)
        r._c_node = \
            btorapi.boolector_write(self._c_btor, array._c_node,
                                    _c_node(index), _c_node(value))
        return r

    def Cond(self, cond, a, b):
        """ Cond(cond, a, b)
          
            Create an if-then-else.
            
            If condition ``cond`` is true, then ``a`` is returned, else ``b``
            is returned.
            Nodes ``a`` and ``b`` must be either both arrays or both bit
            vectors.

            :param cond: Bit vector condition with bit width one.
            :type cond:  :class:`~boolector._BoolectorNode`
            :param a: Array or bit vector operand representing the *then* case.
            :type a:  :class:`~boolector._BoolectorNode`
            :param b: Array or bit vector operand representing the *else* case.
            :type b:  :class:`~boolector._BoolectorNode`
            :return:  Either ``a`` or ``b``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        _check_precond_cond(cond, a, b)
        cond = self.Const(cond, width=1)
        if isinstance(a, _BoolectorBVNode) or isinstance(b, _BoolectorBVNode):
            r = _BoolectorBVNode(self)
            a, b = _to_node(a, b)
        else:
            assert(isinstance(a, _BoolectorArrayNode))
            assert(isinstance(b, _BoolectorArrayNode))
            r = _BoolectorArrayNode(self)
        r._c_node = \
            btorapi.boolector_cond(self._c_btor, _c_node(cond), _c_node(a),
                                      _c_node(b))
        return r

    # Functions

    def Fun(self, list params, _BoolectorBVNode body):
        """ Fun(params, body)
          
            Create a function with function body ``body``, parameterized
            over ``params``.
            
            This kind of node is similar to macros in the `SMT-LIB v2`_
            standard.
            Note that as soon as a parameter is bound to a function, it can
            not be reused in other functions. 
            Call a function via :func:`~boolector.Boolector.Apply`.

            See :func:`~boolector.Boolector.Param`,
            :func:`~boolector.Boolector.Apply`.

            :param params: A list of function parameters.
            :type cond:  :class:`~boolector._BoolectorNode`
            :param body: Function body parameterized over ``params``.
            :type body:  :class:`~boolector._BoolectorNode`
            :return:  A function over parameterized expression ``body``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        cdef int paramc = len(params)
        cdef btorapi.BoolectorNode ** c_params = \
            <btorapi.BoolectorNode **> \
                malloc(paramc * sizeof(btorapi.BoolectorNode *))

        # copy params into array
        for i in range(paramc):
            if not isinstance(params[i], _BoolectorParamNode):
                raise _BoolectorException(
                          "Operand at position {} is not a parameter".format(i))
            c_params[i] = _c_node(params[i])

        r = _BoolectorFunNode(self)
        r._params = params
        r._c_node = \
            btorapi.boolector_fun(self._c_btor, c_params, paramc, body._c_node)
        free(c_params)
        return r

    def UF(self, _BoolectorSort sort, str symbol = None):
        """ UF(sort, symbol)
          
            Create an uninterpreted function with sort ``sort`` and symbol
            ``symbol``.
            
            Note that in contrast to composite expressions, which are 
            maintained uniquely w.r.t. to their kind, inputs (and consequently,
            bit width), uninterpreted functions are not.
            Hence, each call to this function returns a fresh uninterpreted
            function.

            An uninterpreted function's symbol is used as a simple means of 
            identfication, either when printing a model via 
            :func:`~boolector.Boolector.Print_model`,
            or generating file dumps via 
            :func:`~boolector.Boolector.Dump`.
            Note that a symbol must be unique but may be None in case that no
            symbol should be assigned.

            See :func:`~boolector.Boolector.Apply`,
            :func:`~boolector.Boolector.FunSort`.

            :param sort: Sort of the uninterpreted function.
            :type sort:  _BoolectorSort
            :param symbol: Name of the uninterpreted function. 
            :type symbol: str
            :return:  A function over parameterized expression ``body``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        if not isinstance(sort, _BoolectorFunSort):
            raise _BoolectorException(
                     "Sort must be of sort '_BoolectorFunSort'")
        r = _BoolectorFunNode(self)
        r._sort = sort
        r._c_node = btorapi.boolector_uf(self._c_btor, sort._c_sort,
                                         _ChPtr(symbol)._c_str)
        return r


    def Apply(self, list args, _BoolectorFunNode fun):
        """ Apply(args,fun)
          
            Create a function application on function ``fun`` with arguments
            ``args``.
            
            See :func:`~boolector.Boolector.Fun`,
            :func:`~boolector.Boolector.UF`.

            :param args: A list of arguments to be applied.
            :type args: list
            :param fun: Function to apply arguments ``args`` to.
            :type fun:  :class:`~boolector._BoolectorNode`
            :return:  A function application on function ``fun`` with arguments ``args``.
            :rtype: :class:`~boolector._BoolectorNode`
        """
        cdef int argc = len(args)
        cdef btorapi.BoolectorNode ** c_args = \
            <btorapi.BoolectorNode **> \
	      malloc(argc * sizeof(btorapi.BoolectorNode *))

        # copy arguments into array
        arg_nodes = []
        for i in range(argc):
            a = args[i]
            if not isinstance(a, _BoolectorNode):
                if not (isinstance(a, int) or isinstance(a, bool)):
                    raise _BoolectorException(
                              "Invalid type of argument {}".format(i))
                a = self.Const(a, _get_argument_width(fun, i))
            assert(isinstance(a, _BoolectorNode))
            arg_nodes.append(a)

        for i in range(len(arg_nodes)):
            c_args[i] = _c_node(arg_nodes[i])

        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_apply(self._c_btor, c_args, argc, fun._c_node)
        free(c_args)
        return r

    # Sorts

    def BoolSort(self):
        """ BoolSort()
          
            Create Boolean sort.
            
            Currently, sorts in Boolector are used for uninterpreted functions,
            only.

            See :func:`~boolector.Boolector.UF`.

            :return:  Sort of type Boolean.
            :rtype: :class:`~boolector._BoolectorSort`
        """
        r = _BoolectorBoolSort(self)
        r._c_sort = btorapi.boolector_bool_sort(self._c_btor)
        return r

    def BitVecSort(self, int width):
        """ BitVecSort(width)
          
            Create bit vector sort of bit width ``width``.
            
            Currently, sorts in Boolector are used for uninterpreted functions,
            only.

            See :func:`~boolector.Boolector.UF`.

            :param width: Bit width.
            :type width: int
            :return:  Bit vector sort of bit width ``width``.
            :rtype: :class:`~boolector._BoolectorSort`
        """
        r = _BoolectorBitVecSort(self)
        r._width = width
        r._c_sort = btorapi.boolector_bitvec_sort(self._c_btor, width)
        return r

    def FunSort(self, list domain, _BoolectorSort codomain):
        """ FunSort(domain, codomain)
          
            Create function sort.
            
            Currently, sorts in Boolector are used for uninterpreted functions,
            only.

            See :func:`~boolector.Boolector.UF`.

            :param domain: A list of all the function arguments' sorts.
            :type width: list
            :param codomain: The sort of the function's return value.
            :return:  Function sort, which maps ``domain`` to ``codomain``.
            :rtype: :class:`~boolector._BoolectorSort`
          """
        cdef int arity = len(domain)
        cdef btorapi.BoolectorSort ** c_domain = \
            <btorapi.BoolectorSort **> \
                malloc(arity * sizeof(btorapi.BoolectorSort *))

        for i in range(arity):
            if not isinstance(domain[i], _BoolectorSort):
                raise _BoolectorException("Function domain contains non-sort "\
                                          "objects")
            c_domain[i] = (<_BoolectorSort> domain[i])._c_sort

        r = _BoolectorFunSort(self)
        r._domain = domain
        r._codomain = codomain
        r._c_sort = btorapi.boolector_fun_sort(
                        self._c_btor, c_domain, arity, codomain._c_sort)
        return r
