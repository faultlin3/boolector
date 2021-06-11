#! /bin/sh
#
# setup-mallob.sh
# Copyright (C) 2021 christian <christian@faultline>
#
# Distributed under terms of the MIT license.
#

set -e -o pipefail
source "$(dirname "$0")/setup-utils.sh"

MALLOB_DIR=${DEPS_DIR}/mallob

rm -rf ${MALLOB_DIR}

REPO="domschrei/mallob-ipasir-bridge"
COMMIT="9678566b63fdeda71f873ec7aa5c2cdaabfc4225"
download_github "$REPO" "$COMMIT" "$MALLOB_DIR"

cd "$MALLOB_DIR"

make
install_lib libipasirmallob.a
install_include src/ipasir.h
install_include src/json.hpp
install_include src/mallob_ipasir.hpp
