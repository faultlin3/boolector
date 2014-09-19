# Boolector: Satisfiablity Modulo Theories (SMT) solver.
#
# Copyright (C) 2013-2014 Mathias Preiner.
#
# All rights reserved.
#
# This file is part of Boolector.
# See COPYING for more information on using this software.
#

cimport btorapi
from libc.stdlib cimport malloc, free
from libc.stdio cimport stdout, FILE, fopen, fclose
import math, os

g_tunable_options = {"rewrite_level", "rewrite_level_pbr",
                     "beta_reduce_all", "probe_beta_reduce_all",
                     "pbra_lod_limit", "pbra_sat_limit", "pbra_ops_factor",
                     "dual_prop", "just", "ucopt", "lazy_synthesize",
                     "eliminate_slices"}

# TODO: uniform code style
# TODO: exception checks

class _BoolectorException(Exception):
    def __init__(self, msg):
        self.msg = msg

    def __str__(self):
        return "[pybtor] {}".format(self.msg)

# utility functions

cdef btorapi.BoolectorNode* _c_node(x):
    assert(isinstance(x, _BoolectorNode))
    return (<_BoolectorNode> x)._c_node

cdef _BoolectorBVNode _const_to_node(btor, x, int width=1):
    if isinstance(x, int):
        if x > 0 and int(math.log(x, 2)) + 1 > width:
            raise _BoolectorException(
                      "Value of constant {} exceeds bit width of {}".format(
                          x, width))
        return btor.Int(x, width)
    elif isinstance(x, bool):
        if x:
            return btor.TRUE()
        else:
            return btor.FALSE()
    elif isinstance(x, _BoolectorNode):
        return x
    else:
        raise _BoolectorException(
                  "Cannot convert type '{}' to bit vector".format(type(x)))
cdef class _ChPtr:
    cdef char * _c_str
    cdef bytes _py_str
    def __init__(self, str string):
        cdef bytes b_str
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
        if (<_BoolectorBVNode> x).Width() != (<_BoolectorBVNode> y).Width():
            raise _BoolectorException(
                      "Both operands must have the same bit width")
        return x, y
    elif not (isinstance(x, _BoolectorBVNode) or
              isinstance(y, _BoolectorBVNode)):
        raise _BoolectorException("At least one of the operands must be of "\
                                 "type '_BoolectorBVNode'") 
    if isinstance(x, _BoolectorBVNode):
        btor = (<_BoolectorBVNode> x).btor
        width = (<_BoolectorBVNode> x).Width()
    else:
        assert(isinstance(y, _BoolectorBVNode))
        btor = (<_BoolectorBVNode> y).btor
        width = (<_BoolectorBVNode> y).Width()

    x = _const_to_node(btor, x, width)
    y = _const_to_node(btor, y, width)
    return x, y

cdef int _get_argument_width(_BoolectorFunNode fun, int pos):
    if fun._params:
        return (<_BoolectorNode> fun._params[pos]).Width()
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
    if not _is_power2(a.Width()):
        raise _BoolectorException(
                  "Bit width of operand 'a' must be a power of 2")
    if int(math.log(a.Width(), 2)) != b.Width():
        raise _BoolectorException(
                  "Bit width of operand 'b' must be equal to "\
                  "log2(bit width of a)") 

def _check_precond_slice(_BoolectorBVNode a, int upper, int lower):
        if upper >= a.Width():
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
    cdef btorapi.Btor* _c_btor
    cdef btorapi.BoolectorSort* _c_sort

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

# option wrapper class

cdef class _BoolectorOpt:
    cdef Boolector btor
    cdef const btorapi.BtorOpt* _c_opt

    def __init__(self, Boolector boolector):
        self.btor = boolector

    property internal:
        def __get__(self):
            return self._c_opt.internal == 1

    property shrt:
        def __get__(self):
            return _to_str(self._c_opt.shrt)

    property lng:
        def __get__(self):
            return _to_str(self._c_opt.lng)

    property desc:
        def __get__(self):
            return _to_str(self._c_opt.desc)

    property val:
        def __get__(self):
            return self._c_opt.val

    property dflt:
        def __get__(self):
            return self._c_opt.dflt

    property min:
        def __get__(self):
            return self._c_opt.min

    property max:
        def __get__(self):
            return self._c_opt.max

    property tunable:
        def __get__(self):
            return self.lng in g_tunable_options

    def __str__(self):
        return "{}, {}, [{}, {}], default: {}".format(self.lng, self.tunable,
                                                      self.min, self.max,
                                                      self.dflt)
# wrapper classes for BoolectorNode

cdef class _BoolectorNode:
    cdef Boolector btor
    cdef btorapi.Btor* _c_btor
    cdef btorapi.BoolectorNode* _c_node

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

    def Dump(self, format="btor", outfile = ""):
        if format.lower() == "btor":
            btorapi.boolector_dump_btor_node(self.btor._c_btor, stdout,
                                             self._c_node)
        elif format.lower() == "smt1":
            btorapi.boolector_dump_smt1_node(self.btor._c_btor, stdout,
                                             self._c_node)
        elif format.lower() == "smt2":
            btorapi.boolector_dump_smt2_node(self.btor._c_btor, stdout,
                                             self._c_node)
        else:
            raise _BoolectorException("Invalid dump format '{}'".format(format)) 

    def Symbol(self):
        return _to_str(btorapi.boolector_get_symbol(self.btor._c_btor,
                                                    self._c_node))

    def Assignment(self):
        cdef char** c_str_i
        cdef char** c_str_v
        cdef int size
        cdef const char* c_str
        cdef bytes py_str

        if isinstance(self, _BoolectorFunNode) or \
           isinstance(self, _BoolectorArrayNode):
            btorapi.boolector_array_assignment(self.btor._c_btor,
                                               self._c_node,
                                               &c_str_i, &c_str_v, &size) 
            model = []
            if size > 0:
                for i in range(size):
                    index = _to_str(c_str_i[i])
                    value = _to_str(c_str_v[i])
                    model.append((index, value))
                btorapi.boolector_free_array_assignment(self.btor._c_btor,
                                                        c_str_i, c_str_v, size) 
            return model
        else:
            c_str = \
                btorapi.boolector_bv_assignment(self.btor._c_btor,
                                                   self._c_node)
            value = _to_str(c_str)
            btorapi.boolector_free_bv_assignment(self.btor._c_btor, c_str)
            return value 

    def Width(self):
        return btorapi.boolector_get_width(self.btor._c_btor, self._c_node)


cdef class _BoolectorBVNode(_BoolectorNode):
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

#    def __div__(x, y):
#        x, y = _to_node(x, y)
#        return (<_BoolectorBVNode> x).btor.Udiv(x, y)

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
                upper = self.Width() - 1
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
            raise _BoolectorException("Expected 'int' or 'slice'.")
            

cdef class _BoolectorArrayNode(_BoolectorNode):
    # TODO: allow slices on arrays
    #       array[2:4] -> memcpy from index 2 to 4 
    #       array[:] -> copy whole array
    def __getitem__(self, index):
        return self.btor.Read(self, index)

    def Index_width(self):
        return btorapi.boolector_get_index_width(self.btor._c_btor,
                   self._c_node)


cdef class _BoolectorFunNode(_BoolectorNode):
    cdef list _params
    cdef _BoolectorFunSort _sort

    def __call__(self, *args):
        return self.btor.Apply(list(args), self)

    def Arity(self):
        return \
            btorapi.boolector_get_fun_arity(self.btor._c_btor, self._c_node)

cdef class _BoolectorParamNode(_BoolectorBVNode):
    pass

# wrapper class for Boolector itself

cdef class Boolector:
    cdef btorapi.Btor* _c_btor
    UNKNOWN = 0
    SAT = 10
    UNSAT = 20

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
        if n.Width() > 1:
            raise _BoolectorException("Asserted term must be of bit width one")
        btorapi.boolector_assert(self._c_btor, n._c_node)

    def Assume(self, _BoolectorNode n):
        if n.Width() > 1:
            raise _BoolectorException("Assumed termed must be of bit width one")
        btorapi.boolector_assume(self._c_btor, n._c_node)

    def Failed(self, _BoolectorNode n):
        if n.Width() > 1:
            raise _BoolectorException("Term must be of bit width one")
        return btorapi.boolector_failed(self._c_btor, n._c_node) == 1

    def Simplify(self):
        return btorapi.boolector_simplify(self._c_btor)

    def Sat(self, int lod_limit = -1, int sat_limit = -1):
        if lod_limit > 0 or sat_limit > 0:
            return btorapi.boolector_limited_sat(self._c_btor, lod_limit,
                                                 sat_limit)
        return btorapi.boolector_sat(self._c_btor)

    def Clone(self):
        return Boolector(self)

    # Boolector options
    def Set_opt(self, str opt, int value):
        btorapi.boolector_set_opt(self._c_btor, _ChPtr(opt)._c_str, value)

    def Get_opt(self, str opt):
        r = _BoolectorOpt(self)
        r._c_opt = btorapi.boolector_get_opt(self._c_btor, _ChPtr(opt)._c_str)
        return r

    def Options(self):
        opts = []
        cdef const btorapi.BtorOpt* c_opt
        cdef const btorapi.BtorOpt* c_last_opt
        c_opt = btorapi.boolector_first_opt(self._c_btor)
        c_last_opt = btorapi.boolector_last_opt(self._c_btor)
        while c_opt != c_last_opt:
            o = _BoolectorOpt(self)
            o._c_opt = c_opt
            if not o.internal:
                opts.append(o)
            c_opt = btorapi.boolector_next_opt(self._c_btor, c_opt)
        return opts

    def Set_sat_solver(self, str solver, str optstr=None, int nofork=0):
        solver = solver.strip().lower()
        if solver == "lingeling":
            btorapi.boolector_set_sat_solver_lingeling(self._c_btor,
                                                       _ChPtr(optstr)._c_str,
                                                       nofork)
        else:
            btorapi.boolector_set_sat_solver(self._c_btor,
                                             _ChPtr(solver)._c_str)

    def Set_msg_prefix(self, str prefix):
        btorapi.boolector_set_msg_prefix(self._c_btor, _ChPtr(prefix)._c_str)

    def Print_model(self, outfile=None):
        cdef FILE* c_file

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
        cdef FILE* c_file
        cdef int res
        cdef char* err_msg
        cdef int status

        if not os.path.isfile(file):
            raise _BoolectorException("File '{}' does not exist".format(file))

        c_file = fopen(_ChPtr(file)._c_str, "r")
        res = btorapi.boolector_parse(self._c_btor, c_file, _ChPtr(file)._c_str,
                                      &err_msg, &status)
        fclose(c_file)
        return (res, status, _to_str(err_msg))

    def Dump(self, format = "btor", outfile=None):
        cdef FILE* c_file

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

    def Const(self, str bits):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_const(self._c_btor, _ChPtr(bits)._c_str)
        return r

    def Zero(self, int width):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_zero(self._c_btor, width)
        return r

    def Ones(self, int width):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_ones(self._c_btor, width)
        return r

    def TRUE(self):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_true(self._c_btor)
        return r

    def FALSE(self):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_false(self._c_btor)
        return r

    def One(self, int width):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_one(self._c_btor, width)
        return r

    def Uint(self, unsigned int i, int width):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_unsigned_int(self._c_btor, i, width)
        return r

    def Int(self, int i, int width):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_int(self._c_btor, i, width)
        return r

    def Var(self, int width, str symbol=None):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_var(self._c_btor, width,
                                          _ChPtr(symbol)._c_str)
        return r

    def Param(self, int width, str symbol=None):
        r = _BoolectorParamNode(self)
        r._c_node = btorapi.boolector_param(self._c_btor, width,
                                            _ChPtr(symbol)._c_str)
        return r

    def Array(self, int elem_width, int index_width, str symbol=None):
        r = _BoolectorArrayNode(self)
        r._c_node = btorapi.boolector_array(self._c_btor, elem_width,
                                            index_width, _ChPtr(symbol)._c_str)
        return r

    # Unary operators

    def Not(self, _BoolectorBVNode n):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_not(self._c_btor, n._c_node)
        return r

    def Neg(self, _BoolectorBVNode n):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_neg(self._c_btor, n._c_node)
        return r

    def Redor(self, _BoolectorBVNode n):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_redor(self._c_btor, n._c_node)
        return r

    def Redxor(self, _BoolectorBVNode n):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_redxor(self._c_btor, n._c_node)
        return r

    def Redand(self, _BoolectorBVNode n):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_redand(self._c_btor, n._c_node)
        return r

    def Slice(self, _BoolectorBVNode n, int upper, int lower):
        _check_precond_slice(n, upper, lower)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_slice(self._c_btor, n._c_node,
                                                 upper, lower)
        return r
                                                                
    def Uext(self, _BoolectorBVNode n, int width):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_uext(self._c_btor, n._c_node, width)
        return r

    def Sext(self, _BoolectorBVNode n, int width):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_sext(self._c_btor, n._c_node, width)
        return r

    def Inc(self, _BoolectorBVNode n):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_inc(self._c_btor, n._c_node)
        return r

    def Dec(self, _BoolectorBVNode n):
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_dec(self._c_btor, n._c_node)
        return r

    # Binary operators

    def Implies(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_implies(self._c_btor,
                                              _c_node(a), _c_node(b))
        return r

    def Iff(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_iff(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Xor(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_xor(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Xnor(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_xnor(self._c_btor, _c_node(a), _c_node(b))
        return r

    def And(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_and(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Nand(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_nand(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Or(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_or(self._c_btor,
                                         _c_node(a), _c_node(b))
        return r

    def Nor(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_nor(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Eq(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_eq(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Ne(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_ne(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Add(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_add(self._c_btor, _c_node(a),
                                          _c_node(b))
        return r

    def Uaddo(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_uaddo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Saddo(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_saddo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Mul(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_mul(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Umulo(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_umulo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Smulo(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_smulo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Ult(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_ult(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Slt(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_slt(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Ulte(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_ulte(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Slte(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_slte(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Ugt(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_ugt(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Sgt(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_sgt(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Ugte(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_ugte(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Sgte(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_sgte(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Sll(self, _BoolectorBVNode a, b):
        b = _const_to_node(self, b, math.ceil(math.log(a.Width(), 2))) 
        _check_precond_shift(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_sll(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Srl(self, _BoolectorBVNode a, b):
        b = _const_to_node(self, b, math.ceil(math.log(a.Width(), 2))) 
        _check_precond_shift(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_srl(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Sra(self, _BoolectorBVNode a, b):
        b = _const_to_node(self, b, math.ceil(math.log(a.Width(), 2))) 
        _check_precond_shift(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_sra(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Rol(self, _BoolectorBVNode a, b):
        b = _const_to_node(self, b, math.ceil(math.log(a.Width(), 2))) 
        _check_precond_shift(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_rol(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Ror(self, _BoolectorBVNode a, b):
        b = _const_to_node(self, b, math.ceil(math.log(a.Width(), 2))) 
        _check_precond_shift(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_ror(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Sub(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = btorapi.boolector_sub(self._c_btor,
                                          _c_node(a), _c_node(b))
        return r

    def Usubo(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_usubo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Ssubo(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_ssubo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Udiv(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_udiv(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Sdiv(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_sdiv(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Sdivo(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_sdivo(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Urem(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_urem(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Srem(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_srem(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Smod(self, a, b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_smod(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Concat(self, _BoolectorBVNode a, _BoolectorBVNode b):
        a, b = _to_node(a, b)
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_concat(self._c_btor, _c_node(a), _c_node(b))
        return r

    def Read(self, _BoolectorArrayNode a, b):
        b = _const_to_node(self, b, a.Index_width())
        r = _BoolectorBVNode(self)
        r._c_node = \
            btorapi.boolector_read(self._c_btor, _c_node(a), _c_node(b))
        return r

    # Ternary operators

    def Write(self, _BoolectorArrayNode array, index, value):
        index = _const_to_node(self, index, array.Index_width())
        value = _const_to_node(self, value, array.Width())

        r = _BoolectorArrayNode(self)
        r._c_node = \
            btorapi.boolector_write(self._c_btor, array._c_node,
                                    _c_node(index), _c_node(value))
        return r

    def Cond(self, cond, a, b):
        _check_precond_cond(cond, a, b)
        cond = _const_to_node(self, cond, width=1)
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
        cdef int paramc = len(params)
        cdef btorapi.BoolectorNode** c_params = \
            <btorapi.BoolectorNode**> \
                malloc(paramc * sizeof(btorapi.BoolectorNode*))

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

    def UF(self, _BoolectorSort sort, str symbol=None):
        if not isinstance(sort, _BoolectorFunSort):
            raise _BoolectorException(
                     "Sort must be of sort '_BoolectorFunSort'")
        r = _BoolectorFunNode(self)
        r._sort = sort
        r._c_node = btorapi.boolector_uf(self._c_btor, sort._c_sort,
                                         _ChPtr(symbol)._c_str)
        return r

    def Apply(self, list args, _BoolectorFunNode fun):
        cdef int argc = len(args)
        cdef btorapi.BoolectorNode** c_args = \
            <btorapi.BoolectorNode**> \
	      malloc(argc * sizeof(btorapi.BoolectorNode*))

        # copy arguments into array
        arg_nodes = []
        for i in range(argc):
            a = args[i]
            if not isinstance(a, _BoolectorNode):
                if not (isinstance(a, int) or isinstance(a, bool)):
                    raise _BoolectorException(
                              "Invalid type of argument {}".format(i))
                a = _const_to_node(self, a, _get_argument_width(fun, i))
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
        r = _BoolectorBoolSort(self)
        r._c_sort = btorapi.boolector_bool_sort(self._c_btor)
        return r

    def BitVecSort(self, int width):
        r = _BoolectorBitVecSort(self)
        r._width = width
        r._c_sort = btorapi.boolector_bitvec_sort(self._c_btor, width)
        return r

    def ArraySort(self, _BoolectorSort index, _BoolectorSort element):
        r = _BoolectorSort(self)
        r._c_sort = btorapi.boolector_array_sort(
                        self._c_btor, index._c_sort, element._c_sort)
        return r

    def FunSort(self, list domain, _BoolectorSort codomain):
        cdef int arity = len(domain)
        cdef btorapi.BoolectorSort** c_domain = \
            <btorapi.BoolectorSort**> \
                malloc(arity * sizeof(btorapi.BoolectorSort*))

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
