#!/usr/bin/env bash
#
# compile-analyzer.sh — Compile an NLP++ analyzer's KB into the native shared
# library that the EMBEDED_KB-enabled engine dlopens at -COMPILED time.
#
# Usage:
#   scripts/compile-analyzer.sh <analyzer-dir> <input-file>
#
# Example:
#   scripts/compile-analyzer.sh data/rfb data/rfb/input/text.txt
#
# Produces: <analyzer-dir>/bin/kb.dylib
#
# How it fits into the runtime:
#   - `nlp -COMPILE` emits Cc_code.cpp + the Sym*.cpp / Con*.cpp / Ptr*.cpp /
#     St*.cpp KB tables under <analyzer-dir>/kb/. (ana_gen was removed from
#     upstream around 1999, so there is no run.dylib equivalent — the engine
#     falls back to interpreted execution for the analyzer rules.)
#   - This script wraps those generated tables together with a one-line
#     kb_setup() shim, builds them into a SHARED library, and drops it at
#     <analyzer-dir>/bin/kb.dylib (the hardcoded path the engine dlopens).
#   - Only kb_setup is exported (-fvisibility=hidden everywhere else) so the
#     ABI surface mirrors the Windows export model.
#
# Architecture note: the bundled nlp.exe is arm64 (Apple Silicon) only, so the
# .dylib is built for arm64 as well. Intel Macs are not supported.

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <analyzer-dir> <input-file>" >&2
  exit 64
fi

ANALYZER_ARG="$1"
INPUT_FILE="$2"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANALYZER_DIR="$(cd "$ANALYZER_ARG" && pwd)"

NLP_EXE="$REPO_ROOT/nlp.exe"
COMPILE_LIBS="$REPO_ROOT/compile-libs"

if [ ! -x "$NLP_EXE" ]; then
  echo "ERROR: nlp.exe not found or not executable at $NLP_EXE" >&2
  exit 1
fi
if [ ! -d "$COMPILE_LIBS/include" ] || [ ! -d "$COMPILE_LIBS/lib" ]; then
  echo "ERROR: compile libraries not found at $COMPILE_LIBS" >&2
  echo "Expected: compile-libs/{include,lib}" >&2
  echo "(The workflow .github/workflows/nlp-engine-build.yml drops these in" >&2
  echo " place. Trigger it once upstream attaches nlpengine-compile-libs-macos.zip" >&2
  echo " to the release.)" >&2
  exit 1
fi
if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: input file not found: $INPUT_FILE" >&2
  exit 1
fi

export DYLD_LIBRARY_PATH="$REPO_ROOT:${DYLD_LIBRARY_PATH:-}"

echo "==> [1/3] nlp.exe -COMPILE  (emits Cc_code.cpp + Sym*/Con*/Ptr*/St*.cpp under $ANALYZER_DIR/kb)"
"$NLP_EXE" -COMPILE -ANA "$ANALYZER_DIR" -WORK "$REPO_ROOT" "$INPUT_FILE"

BUILD_ROOT="$ANALYZER_DIR/.nlp-compile"
SRC_DIR="$BUILD_ROOT/src"
BUILD_DIR="$BUILD_ROOT/build"
rm -rf "$BUILD_ROOT"
mkdir -p "$SRC_DIR"

# Generated engine sources include "StdAfx.h" by convention.
cat > "$SRC_DIR/StdAfx.h" <<'EOF'
#pragma once
#include "my_tchar.h"
EOF

# Sole exported symbol: kb_setup. The engine resolves it via dlsym after
# dlopening bin/kb.dylib and calls it with the CG (concept graph) instance.
cat > "$SRC_DIR/kb_setup.cpp" <<'EOF'
#include "Cc_code.h"

extern "C" __attribute__((visibility("default")))
bool kb_setup(void *cg) {
    return cc_ini(cg);
}
EOF

echo "==> [2/3] Generate CMakeLists.txt"
cat > "$SRC_DIR/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.16)
project(nlp_kb_library LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_OSX_ARCHITECTURES arm64)

# Hide every symbol by default; kb_setup is opted back in explicitly via
# __attribute__((visibility("default"))) in kb_setup.cpp.
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

# Drop the artifact at <analyzer-dir>/bin/kb.dylib (engine's hardcoded path).
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "$ANALYZER_DIR/bin")

file(GLOB GENERATED_CPP "$ANALYZER_DIR/kb/*.cpp")
if(NOT GENERATED_CPP)
  message(FATAL_ERROR "No generated .cpp files found under $ANALYZER_DIR/kb/ — did -COMPILE succeed?")
endif()

add_library(nlp_kb SHARED \${GENERATED_CPP} "$SRC_DIR/kb_setup.cpp")

# Force the on-disk filename to "kb.dylib" (no "lib" prefix) so dlopen finds
# it at the engine's hardcoded path.
set_target_properties(nlp_kb PROPERTIES
  OUTPUT_NAME "kb"
  PREFIX ""
)

target_include_directories(nlp_kb PRIVATE
  "$SRC_DIR"
  "$ANALYZER_DIR"
  "$ANALYZER_DIR/kb"
  "$COMPILE_LIBS/include/Api"
  "$COMPILE_LIBS/include/cs"
)

target_compile_options(nlp_kb PRIVATE -include StdAfx.h)
target_link_directories(nlp_kb PRIVATE "$COMPILE_LIBS/lib")

# Engine static libs (link order matters: prim is base; others depend on it).
# ICU link order is also significant: i18n -> uc -> data.
target_link_libraries(nlp_kb PRIVATE
  prim kbm consh words lite
  icui18n icuuc icudata
)

find_library(DL_LIBRARY dl)
if(DL_LIBRARY)
  target_link_libraries(nlp_kb PRIVATE \${DL_LIBRARY})
endif()
EOF

echo "==> [3/3] cmake configure + build (Release)"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" --config Release

OUT="$ANALYZER_DIR/bin/kb.dylib"
if [ -f "$OUT" ]; then
  echo
  echo "Built: $OUT"
  echo "Run:   $NLP_EXE -COMPILED -ANA $ANALYZER_DIR -WORK $REPO_ROOT $INPUT_FILE"
else
  echo "ERROR: expected output $OUT was not produced" >&2
  exit 1
fi
