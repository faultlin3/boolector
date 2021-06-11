#!/usr/bin/env bash

# Boolector: Satisfiablity Modulo Theories (SMT) solver.
#
# Copyright (C) 2007-2021 by the authors listed in the AUTHORS file.
#
# This file is part of Boolector.
# See COPYING for more information on using this software.
#

set -e -o pipefail
source "$(dirname "$0")/setup-utils.sh"

MALLOB_DIR=${DEPS_DIR}/mallob

#rm -rf ${MALLOB_DIR}

#REPO="domschrei/mallob-ipasir-bridge"
#COMMIT="9678566b63fdeda71f873ec7aa5c2cdaabfc4225"
#download_github "$REPO" "$COMMIT" "$MALLOB_DIR"

cd "$MALLOB_DIR"

# make MALLOB_BASE_DIRECTORY='\"/home/christian/Projects/SAT/mallob\"'
make MALLOB_BASE_DIRECTORY='\"/tmp\"'
#g++ -g -DMALLOB_BASE_DIRECTORY='"/home/christian/Projects/SAT/mallob"' -c -std=c++17 src/mallob_ipasir.cpp -Isrc
#ar rvs libipasirmallob.a mallob_ipasir.a

# g++ -g -fPIC -shared -o libipasirmallob.so -DMALLOB_BASE_DIRECTORY='"/home/christian/Projects/SAT/mallob"' -c src/mallob_ipasir.cpp -Isrc

install_lib libipasirmallob.a
install_include src/ipasir.h
install_include src/json.hpp
install_include src/mallob_ipasir.hpp
