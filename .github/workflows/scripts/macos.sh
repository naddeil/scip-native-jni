#!/usr/bin/env bash
set -euo pipefail

WORK="$GITHUB_WORKSPACE"
PREFIX="$WORK/deps_static"
SCIP_BUILD="$WORK/scipoptsuite/build"
OUT="$WORK/out"
CORES=$(sysctl -n hw.logicalcpu)
SCIP_MAJOR_MINOR=$(echo "$SCIPOPTSUITE_VERSION" | cut -d. -f1-2)

if [ "${STATIC:-false}" = "true" ]; then
  SHARED_FLAG=OFF; BUILD_SHARED=OFF
else
  SHARED_FLAG=ON; BUILD_SHARED=ON
fi

mkdir -p "$PREFIX" "$PREFIX/include" "$PREFIX/lib" "$OUT"

# ============================================================
# 0. Prerequisiti brew
# ============================================================
brew update
brew install gcc bison boost pkg-config wget cmake maven

export CC="$(brew --prefix)/bin/gcc-$(brew list --versions gcc | awk '{print $2}' | cut -d. -f1)"
export CXX="${CC/gcc-/g++-}"
export FC="$(brew --prefix)/bin/gfortran-$(brew list --versions gcc | awk '{print $2}' | cut -d. -f1)"
export CMAKE_IGNORE_PREFIX_PATH=/opt/homebrew

# ============================================================
# 1-2. Dipendenze (skip se cachate)
# ============================================================
if [ "${DEPS_CACHED:-}" != "true" ]; then

cd "$WORK"
mkdir -p staticdepsinstall && cd staticdepsinstall

curl -LO https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.xz
tar xf zlib-1.3.1.tar.xz && cd zlib-1.3.1
CFLAGS="-O3 -fPIC" ./configure --static --prefix="$PREFIX"
make -j"$CORES" && make install && cd ..

curl -LO https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz
tar xf gmp-6.3.0.tar.xz && cd gmp-6.3.0
CFLAGS="-O3 -fPIC" ./configure --disable-shared --enable-static --prefix="$PREFIX"
make -j"$CORES" && make install && cd ..

curl -LO https://www.mpfr.org/mpfr-current/mpfr-4.2.2.tar.xz
tar xf mpfr-4.2.2.tar.xz && cd mpfr-4.2.2
CFLAGS="-O3 -fPIC" ./configure --disable-shared --enable-static --prefix="$PREFIX" --with-gmp="$PREFIX"
make -j"$CORES" && make install && cd ..

curl -LO https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.bz2
tar xf boost_1_85_0.tar.bz2 && cd boost_1_85_0
./bootstrap.sh --with-libraries=program_options,serialization,regex,random,iostreams --prefix="$PREFIX"
./b2 -j"$CORES" link=static runtime-link=static cxxflags="-fPIC" install && cd ..

curl -L -o coinbrew https://raw.githubusercontent.com/coin-or/coinbrew/master/coinbrew
chmod +x coinbrew
./coinbrew fetch Ipopt --no-prompt
./coinbrew build Ipopt --prefix="$PREFIX" --no-prompt \
  --with-lapack-lflags="-framework Accelerate" \
  --with-blas-lflags="-framework Accelerate" \
  --disable-shared --enable-static \
  ADD_CFLAGS="-fPIC" ADD_CXXFLAGS="-fPIC" ADD_FFLAGS="-fPIC"

echo "Dipendenze compilate."
else
  echo "Dipendenze cachate, skip compilazione."
fi

# ============================================================
# 3. Download e compila SCIP
# ============================================================
cd "$WORK"
curl -LO "https://www.scipopt.org/download/release/scipoptsuite-${SCIPOPTSUITE_VERSION}.tgz"
tar -xzf "scipoptsuite-${SCIPOPTSUITE_VERSION}.tgz"
mv "scipoptsuite-${SCIPOPTSUITE_VERSION}" scipoptsuite

cd "$WORK/scipoptsuite"
rm -rf build && mkdir -p build && cd build
cmake .. \
  -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$WORK/scip_shared" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_C_FLAGS="-fPIC" -DCMAKE_CXX_FLAGS="-fPIC" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DSHARED=$SHARED_FLAG -DBUILD_SHARED_LIBS=$BUILD_SHARED \
  -DREADLINE=false -DGMP=true -DGMP_DIR="$PREFIX" -DZIMPL=false \
  -DLAPACK=true -DLPS=spx -DSOPLEX_DIR="../soplex" \
  -DIPOPT=true -DIPOPT_DIR="$PREFIX" \
  -DFILTERSQP=false -DWORHP=false -DBOOST_ROOT="$PREFIX"
make -j"$CORES" && make install

# ============================================================
# 4. Compila JSCIPOpt
# ============================================================
cd "$WORK"
unzip -q resources/JSCIPOpt.zip
cd JSCIPOpt && rm -rf build && mkdir build && cd build
cmake .. -DSCIP_DIR="$SCIP_BUILD" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
make

# ============================================================
# 5. Raddrizzatore + output
# ============================================================
cd "$WORK"
LIBSCIP=$(find "$SCIP_BUILD/lib" -name 'libscip.*.dylib' | head -1)
SCIP_DYLIB="libscip.${SCIP_MAJOR_MINOR}.dylib"

cp "$WORK/JSCIPOpt/build/Release/scip.jar" "$OUT/"
cp "$WORK/JSCIPOpt/build/Release/libjscip.dylib" "$OUT/"
cp -L "$LIBSCIP" "$OUT/$SCIP_DYLIB"

install_name_tool -change "$LIBSCIP" "@loader_path/$SCIP_DYLIB" "$OUT/libjscip.dylib"

# Copia e fix dipendenze non-sistema (con -L per dereferenziare symlink)
DEPENDENCIES=$(otool -L "$OUT/$SCIP_DYLIB" | tail -n +3 | awk '{print $1}' | grep -vE '^(/usr/lib|/System/Library|@)')
for DEP in $DEPENDENCIES; do
  BASENAME=$(basename "$DEP")
  cp -L "$DEP" "$OUT/$BASENAME" 2>/dev/null || true
  install_name_tool -change "$DEP" "@loader_path/$BASENAME" "$OUT/$SCIP_DYLIB"
  # Fix anche dipendenze transitive nelle dylib copiate
  for f in "$OUT"/*.dylib; do
    install_name_tool -change "$DEP" "@loader_path/$BASENAME" "$f" 2>/dev/null || true
  done
done

for f in "$OUT"/*.dylib; do
  install_name_tool -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null || true
done

# ============================================================
# 6. Checker
# ============================================================
echo "=== Verifica dipendenze ==="
otool -L "$OUT/libjscip.dylib"
otool -L "$OUT/$SCIP_DYLIB"

export DYLD_LIBRARY_PATH="$OUT"
python3 -c "
import ctypes, sys
for lib in ['$OUT/libjscip.dylib', '$OUT/$SCIP_DYLIB']:
    print(f'Carico {lib}...')
    try:
        ctypes.CDLL(lib)
        print('✅ OK')
    except OSError as e:
        print(f'❌ {e}')
        sys.exit(1)
"

cd "$WORK"
zip -r out.zip out/
echo "Build macOS completata."

# ============================================================
# 7. Test Java (runTest.sh)
# ============================================================
mvn install:install-file \
  -Dfile="$OUT/scip.jar" \
  -DgroupId=com.test -DartifactId=scip -Dversion=0.0.1 -Dpackaging=jar

cd "$WORK"
unzip -q resources/ipeoptimtest.zip
cd ipeoptimtest
mvn clean compile
MAVEN_OPTS="-Djava.library.path=$OUT" \
  mvn exec:java -Dexec.mainClass="com.prometeia.test.TestIntegrazioneCoptimQuadratico"
cd "$WORK"
rm -rf ipeoptimtest
echo "Test Java completato."
