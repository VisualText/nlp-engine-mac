#!/usr/bin/env bash
#
# compile-analyzer.sh — Compile an NLP++ analyzer into the native shared
# libraries that the -COMPILED engine dlopens at runtime.
#
# Usage:
#   scripts/compile-analyzer.sh [--kb-only] <analyzer-dir> <input-file>
#
# Example:
#   scripts/compile-analyzer.sh data/rfb data/rfb/input/text.txt
#   scripts/compile-analyzer.sh --kb-only data/rfb data/rfb/input/text.txt
#
# Produces (default, full-analyzer mode):
#   <analyzer-dir>/bin/run.dylib
#   <analyzer-dir>/bin/runu.dylib
#   <analyzer-dir>/bin/kb.dylib
#   <analyzer-dir>/bin/kbu.dylib
#
# Produces (--kb-only):
#   <analyzer-dir>/bin/kb.dylib
#   <analyzer-dir>/bin/kbu.dylib
#
# How it fits into the runtime (engine v3.1.45+, which switched the macOS
# load path from .so to .dylib in NLP-ENGINE-517):
#   - `nlp -COMPILE` emits the analyzer C++ trees under
#     <analyzer-dir>/run/ and <analyzer-dir>/kb/ (or just kb/ for
#     -COMPILEKB when --kb-only).
#   - This script wraps those trees with an auto-generated StdAfx.h and
#     builds them into a single SHARED library via cmake.
#   - The resulting library exports both `run_analyzer(Parse*)` and
#     `kb_setup(void*)` — engine codegen emits both.
#   - The library is staged into <analyzer-dir>/bin/ under every name
#     the engine's load_compiled() (lite/nlp.cpp:1242) and consh's KB
#     loader (cs/libconsh/cg.cpp:168) look for on macOS.
#
# Architecture note: the bundled nlp.exe is arm64 (Apple Silicon) only,
# so the .dylib is built for arm64 as well. Intel Macs are not
# supported via this script (use the cloud-compile path for x86_64).
#
# Linker handling mirrors what nlp-compile-service's emit-cmake.sh does
# for the cloud build path, adapted for ld64:
#   - -DLINUX: the engine's public headers gate Windows-only constructs
#     on `#ifndef LINUX`; macOS uses the LINUX branch (then the engine
#     itself distinguishes APPLE inside that branch — see
#     NLP-ENGINE-517).
#   - PREFIX "": cmake's default `lib` prefix on SHARED targets is
#     suppressed so the output filename is <name>.dylib, matching what
#     the engine and extension look for on disk.
#   - -Wl,-force_load,<archive> per ICU archive: virtual-class typeinfo
#     (e.g. icu::ByteSink) must always be linked into the .dylib even
#     if no analyzer code references it directly. Apple's ld doesn't
#     accept --whole-archive; -force_load is the per-archive equivalent.
#   - ld64 re-scans static archives by default for cross-archive
#     symbols (libconsh's CG::addWord referenced from liblite, etc.),
#     so no --start-group wrapper is needed here.

set -euo pipefail

KB_ONLY=false
while [ "${1:-}" = "--kb-only" ]; do
  KB_ONLY=true
  shift
done

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 [--kb-only] <analyzer-dir> <input-file>" >&2
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
  exit 1
fi
if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: input file not found: $INPUT_FILE" >&2
  exit 1
fi

export DYLD_LIBRARY_PATH="$REPO_ROOT:${DYLD_LIBRARY_PATH:-}"

if [ "$KB_ONLY" = "true" ]; then
  COMPILE_FLAG="-COMPILEKB"
  TARGET_NAME="nlp_kb"
  SRC_GLOB="kb"
else
  COMPILE_FLAG="-COMPILE"
  TARGET_NAME="nlp_analyzer"
  SRC_GLOB="run|kb"
fi

echo "==> [1/3] nlp.exe $COMPILE_FLAG  (emits .cpp trees under $ANALYZER_DIR/{$SRC_GLOB}/)"
"$NLP_EXE" "$COMPILE_FLAG" -ANA "$ANALYZER_DIR" -WORK "$REPO_ROOT" "$INPUT_FILE"

BUILD_ROOT="$ANALYZER_DIR/.nlp-compile"
SRC_DIR="$BUILD_ROOT/src"
BUILD_DIR="$BUILD_ROOT/build"
rm -rf "$BUILD_ROOT"
mkdir -p "$SRC_DIR"

# Engine-generated .cpp files begin with `#include "StdAfx.h"`; cmake
# also force-includes this file. Same stub the cloud writes.
cat > "$SRC_DIR/StdAfx.h" <<'EOF'
#pragma once
#include "my_tchar.h"
EOF

# Engine static libs. ld64 re-scans automatically, so order isn't
# sensitive. ICU is handled via per-archive -force_load below.
ENGINE_LIB_NAMES="prim kbm consh words lite"

if [ "$KB_ONLY" = "true" ]; then
  GLOB_LINES="file(GLOB GENERATED_CPP \"$ANALYZER_DIR/kb/*.cpp\")"
else
  GLOB_LINES="file(GLOB GENERATED_CPP \"$ANALYZER_DIR/run/*.cpp\" \"$ANALYZER_DIR/kb/*.cpp\")"
fi

echo "==> [2/3] Generate CMakeLists.txt"
cat > "$SRC_DIR/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.16)
project(${TARGET_NAME}_library LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_OSX_ARCHITECTURES arm64)

# Engine public headers gate Windows-only constructs on #ifndef LINUX.
# On macOS the LINUX branch is the right one; engine-internal code then
# distinguishes Apple via __APPLE__ (NLP-ENGINE-517).
add_compile_definitions(LINUX)

set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "$ANALYZER_DIR/bin")

$GLOB_LINES
if(NOT GENERATED_CPP)
  message(FATAL_ERROR "No generated .cpp files found — did $COMPILE_FLAG succeed?")
endif()

add_library($TARGET_NAME SHARED \${GENERATED_CPP})

# Suppress cmake's default 'lib' prefix on SHARED targets so the output
# filename matches what the engine's load_compiled() looks for.
set_target_properties($TARGET_NAME PROPERTIES
  OUTPUT_NAME "$TARGET_NAME"
  PREFIX ""
)

target_include_directories($TARGET_NAME PRIVATE
  "$SRC_DIR"
  "$ANALYZER_DIR"
  "$ANALYZER_DIR/run"
  "$ANALYZER_DIR/kb"
  "$COMPILE_LIBS/include/Api"
  "$COMPILE_LIBS/include/cs"
)

target_compile_options($TARGET_NAME PRIVATE -include StdAfx.h)
target_link_directories($TARGET_NAME PRIVATE "$COMPILE_LIBS/lib")

# Engine static libs. ld64 re-scans archives so order isn't sensitive.
target_link_libraries($TARGET_NAME PRIVATE
  $ENGINE_LIB_NAMES
)

# ICU static libs force-loaded so virtual-class typeinfo
# (icu::ByteSink etc.) is always emitted into the .dylib. Without this,
# dlopen fails at runtime with undefined-symbol errors. macOS ld uses
# per-archive -force_load (no group wrapper like GNU ld's
# --whole-archive).
target_link_libraries($TARGET_NAME PRIVATE
  "-Wl,-force_load,$COMPILE_LIBS/lib/libicui18n.a"
  "-Wl,-force_load,$COMPILE_LIBS/lib/libicuuc.a"
  "-Wl,-force_load,$COMPILE_LIBS/lib/libicudata.a"
)
EOF

echo "==> [3/3] cmake configure + build (Release)"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" --config Release

OUT="$ANALYZER_DIR/bin/${TARGET_NAME}.dylib"
if [ ! -f "$OUT" ]; then
  echo "ERROR: expected output $OUT was not produced" >&2
  exit 1
fi

# Stage the built library under every name the engine's load paths look
# for. The "u" variants are the UNICODE build flavour; copying them
# keeps both engine flavours happy without a rebuild.
echo "==> Staging $(basename "$OUT") into $ANALYZER_DIR/bin/"
if [ "$KB_ONLY" = "true" ]; then
  cp -f "$OUT" "$ANALYZER_DIR/bin/kb.dylib"
  cp -f "$OUT" "$ANALYZER_DIR/bin/kbu.dylib"
  STAGED="bin/kb.dylib bin/kbu.dylib"
else
  cp -f "$OUT" "$ANALYZER_DIR/bin/run.dylib"
  cp -f "$OUT" "$ANALYZER_DIR/bin/runu.dylib"
  cp -f "$OUT" "$ANALYZER_DIR/bin/kb.dylib"
  cp -f "$OUT" "$ANALYZER_DIR/bin/kbu.dylib"
  STAGED="bin/run.dylib bin/runu.dylib bin/kb.dylib bin/kbu.dylib"
fi

echo
echo "Built: $OUT"
echo "Staged: $STAGED"
echo "Run:    $NLP_EXE -COMPILED -ANA $ANALYZER_DIR -WORK $REPO_ROOT $INPUT_FILE"
