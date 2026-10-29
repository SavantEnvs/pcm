#!/usr/bin/env bash
#
# mayhem/build.sh — build Intel PCM's libFuzzer harnesses (tests/*-fuzz.cpp), their standalone
# reproducers, and the unit-test runners that mayhem/test.sh executes.
#
# Both build trees live under `build/`, which upstream's .gitignore covers, so `git clean -ffdX`
# removes them (SPEC §6.2 item 16). Dependencies (libsimdjson, libssl, googletest) come from apt
# packages installed by mayhem/Dockerfile — nothing is fetched here, so the re-run is air-gapped.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT=/mayhem

# 1) Sanitized libpcm.a (the code the harnesses fuzz). -gdwarf-3 comes last so it wins over any -g.
cmake -S . -B build/fuzz -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DPCM_BUILD_EXECUTABLES=OFF \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
      -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
cmake --build build/fuzz --target PCM_STATIC -j"$MAYHEM_JOBS"
LIBPCM="$(find build/fuzz -name libpcm.a | head -n1)"

# 2) Harnesses: each fuzz TU #includes the tool's .cpp, so it is compiled here, not via CMake.
HFLAGS="-std=c++17 -O1 -DPCM_USE_PERF -Wno-unknown-pragmas -fPIE -fno-delete-null-pointer-checks"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/standalone_main.o

build_harness() { # <name> <source> [extra compile/link flags...]
  local name="$1" src="$2"; shift 2
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $HFLAGS "$@" $LIB_FUZZING_ENGINE "$src" build/lsan_off.o \
       "$LIBPCM" -lpthread -o "$OUT/$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $HFLAGS "$@" "$src" build/standalone_main.o build/lsan_off.o \
       "$LIBPCM" -lpthread -o "$OUT/$name-standalone"
}

build_harness urltest-fuzz tests/urltest-fuzz.cpp
build_harness sensor-http-fuzz mayhem/harnesses/sensor_http_fuzz.cpp -DUSE_SSL=1 -lssl -lcrypto
build_harness opcode-events-fuzz mayhem/harnesses/opcode_events_fuzz.cpp -Isrc \
              src/pcm-iio-pmu.cpp src/pcm-iio-topology.cpp

# 3) Unit tests (project's NORMAL flags; test.sh only runs them).
cmake -S . -B build/tests -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DPCM_BUILD_EXECUTABLES=OFF \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build/tests --target PCM_STATIC -j"$MAYHEM_JOBS"
TLIBPCM="$(find build/tests -name libpcm.a | head -n1)"
mkdir -p build/tests/utests
cp src/opCode-6-174.txt build/tests/utests/
for t in lspci pcm-iio read-number pcm-sensor-server-overflow pcm-sensor-server-content-length pcm-sensor-server-header-limits; do
  extra=""
  case "$t" in
    lspci)    extra="src/lspci.cpp" ;;
    pcm-iio)  extra="src/pcm-iio-pmu.cpp src/pcm-iio-topology.cpp" ;;
  esac
  # shellcheck disable=SC2086
  $CXX -std=c++17 -O2 $COVERAGE_FLAGS -DPCM_USE_PERF -Isrc "tests/utests/$t-utest.cpp" $extra \
       "$TLIBPCM" -lgmock_main -lgmock -lgtest -lpthread -o "build/tests/utests/$t-utest"
done
