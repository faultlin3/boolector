# Boolector: Satisfiablity Modulo Theories (SMT) solver.
#
# Copyright (C) 2007-2021 by the authors listed in the AUTHORS file.
#
# This file is part of Boolector.
# See COPYING for more information on using this software.
#

# Find MallobIpasir
# Mallob_FOUND - found Mallob lib
# Mallob_INCLUDE_DIR - the Mallob include directory
# Mallob_LIBRARIES - Libraries needed to use Mallob

find_path(Mallob_INCLUDE_DIR NAMES ipasir.h mallob_ipasir.hpp json.hpp)
find_library(Mallob_LIBRARIES NAMES ipasirmallob)


include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(Mallob
  DEFAULT_MSG Mallob_INCLUDE_DIR Mallob_LIBRARIES)

mark_as_advanced(Mallob_INCLUDE_DIR Mallob_LIBRARIES)
if(Mallob_LIBRARIES)
  message(STATUS "Found Mallob library: ${Mallob_LIBRARIES}")
endif()
