#!/usr/bin/env bash
set -euo pipefail

WORK="$GITHUB_WORKSPACE"
PREFIX="$WORK/deps_static"
SCIP_BUILD="$WORK/scipoptsuite/build"
OUT="$WORK/out"
CORES=$(nproc)
SCIP_MAJOR_MINOR=$(echo "$SCIPOPTSUITE_VERSION" | cut -d. -f1-2)

if [ "${STATIC:-false}" = "true" ]; then
  SHARED_FLAG=OFF; BUILD_SHARED=OFF
else
  SHARED_FLAG=ON; BUILD_SHARED=ON
fi

mkdir -p "$PREFIX" "$PREFIX/include" "$PREFIX/lib" "$OUT"

# ============================================================
# 0. Prerequisiti (Amazon Linux 2023)
# ============================================================
dnf install -y \
  gcc gcc-c++ gcc-gfortran make cmake wget curl git unzip zip \
  tar xz bzip2 patch diffutils pkgconfig m4 perl \
  java-11-amazon-corretto-devel maven.noarch patchelf swig python3
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac))))


# ============================================================
# 1-2. Dipendenze (skip se cachate)
# ============================================================
if [ "${DEPS_CACHED:-}" != "true" ]; then

cd "$WORK"
mkdir -p staticdepsinstall && cd staticdepsinstall

wget -q https://raw.githubusercontent.com/coin-or/coinbrew/master/coinbrew
chmod u+x coinbrew
./coinbrew fetch Ipopt --no-prompt
export CFLAGS="-O3 -fPIC"
export CXXFLAGS="-O3 -fPIC"
export FFLAGS="-O3 -fPIC"
./coinbrew build Ipopt --prefix="$PREFIX" --no-prompt --test --verbosity=3 \
  --with-lapack-lflags="-L$PREFIX/lib -llapack -lblas"

curl -LO https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.xz
tar xf zlib-1.3.1.tar.xz && cd zlib-1.3.1
CFLAGS="-O3 -fPIC" ./configure --static --prefix="$PREFIX"
make -j"$CORES" && make install && cd ..

curl -LO https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz
tar xf gmp-6.3.0.tar.xz && cd gmp-6.3.0
CFLAGS="-O3 -fPIC" ./configure --prefix="$PREFIX"
make -j"$CORES" && make install && cd ..

curl -LO https://www.mpfr.org/mpfr-current/mpfr-4.2.2.tar.xz
tar xf mpfr-4.2.2.tar.xz && cd mpfr-4.2.2
CFLAGS="-O3 -fPIC" ./configure --prefix="$PREFIX" --with-gmp="$PREFIX"
make -j"$CORES" && make install && cd ..

curl -LO https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.bz2
tar xf boost_1_85_0.tar.bz2 && cd boost_1_85_0
./bootstrap.sh --with-libraries=program_options,serialization,regex,random,iostreams --prefix="$PREFIX"
./b2 -j"$CORES" link=static runtime-link=static cxxflags="-fPIC -O3" install && cd ..

wget -q https://github.com/OpenMathLib/OpenBLAS/releases/download/v0.3.30/OpenBLAS-0.3.30.zip
unzip -q OpenBLAS-0.3.30.zip && mv OpenBLAS-0.3.30 OpenBLAS && cd OpenBLAS
unset CFLAGS CXXFLAGS LDFLAGS LIBRARY_PATH LD_LIBRARY_PATH CPATH PKG_CONFIG_PATH 2>/dev/null || true
make -j"$CORES" NO_SHARED=0 DYNAMIC_ARCH=1 USE_OPENMP=0 CC=/usr/bin/gcc FC=/usr/bin/gfortran
make PREFIX="$PREFIX" install && cd ..

wget -q https://github.com/Reference-LAPACK/lapack/archive/refs/tags/v3.12.1.zip
unzip -q v3.12.1.zip && mv lapack-* lapack && cd lapack
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DBUILD_SHARED_LIBS=ON -DLAPACKE=ON \
  -DBLAS_LIBRARIES="$PREFIX/lib/libopenblas.so" -DLAPACK_LIBRARIES="$PREFIX/lib/libopenblas.so"
cmake --build build -j"$CORES" && cmake --install build && cd ..


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
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DLAPACK=true -DBLAS_LIBRARIES="$PREFIX/lib/libopenblas.so" \
  -DLAPACK_LIBRARIES="$PREFIX/lib/liblapacke.so" \
  -DCMAKE_C_FLAGS="-O3 -fPIC" -DCMAKE_CXX_FLAGS="-O3 -fPIC" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DSHARED=$SHARED_FLAG -DBUILD_SHARED_LIBS=$BUILD_SHARED \
  -DREADLINE=off -DGMP=true -DGMP_DIR="$PREFIX" -DZIMPL=false \
  -DLPS=spx -DSOPLEX_DIR="../soplex" \
  -DIPOPT=true -DIPOPT_DIR="$PREFIX" \
  -DFILTERSQP=false -DWORHP=false -DBOOST_ROOT="$PREFIX"
make -j"$CORES" && make install

# ============================================================
# 4. Compila JSCIPOpt (versione modificata con package it.prometeia.jscip)
# ============================================================
cd "$WORK"
unzip -q resources/JSCIPOpt.zip
cd JSCIPOpt
rm -f src/*cxx src/*h 2>/dev/null || true
rm -rf build && mkdir build && cd build
cmake .. -DSCIP_DIR="$SCIP_BUILD" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
make

# ============================================================
# 5. Genera output (cp -L per dereferenziare symlink)
# ============================================================
cd "$WORK"
rm -rf "$OUT"/*

cp "$WORK/JSCIPOpt/build/Release/scip.jar" "$OUT/"
cp -L "$WORK/JSCIPOpt/build/Release/libjscip.so" "$OUT/"
cp -L "$WORK/scipoptsuite/build/lib/libscip.so" "$OUT/libscip.so.${SCIP_MAJOR_MINOR}"

# Dipendenze a link time (cp -L per seguire symlink)
for lib in libmpfr.so libopenblas.so liblapacke.so libgmp.so libipopt.so; do
  [ -f "$PREFIX/lib/$lib" ] && cp -L "$PREFIX/lib/$lib" "$OUT/"
done
cp -L "$PREFIX/lib/libcoinmumps.so" "$OUT/" 2>/dev/null || true

# Librerie di sistema
for syslib in libgcc_s.so.1 libgfortran.so.5 libstdc++.so.6 libquadmath.so.0 libc.so.6 libm.so.6 libblas.so.3 liblapack.so.3; do
  FOUND=$(find /usr/lib64 /lib64 /usr/lib -name "$syslib" 2>/dev/null | head -1) || true
  [ -n "${FOUND:-}" ] && cp -L "$FOUND" "$OUT/" || true
done

# Rinomina con soname
cd "$OUT"
[ -f libmpfr.so ] && mv libmpfr.so libmpfr.so.6
[ -f libopenblas.so ] && mv libopenblas.so libopenblas.so.0
[ -f liblapacke.so ] && mv liblapacke.so liblapacke.so.3
[ -f libgmp.so ] && mv libgmp.so libgmp.so.10
[ -f libipopt.so ] && mv libipopt.so libipopt.so.3
[ -f libcoinmumps.so ] && mv libcoinmumps.so libcoinmumps.so.3

# Fix rpath
for f in *.so*; do
  patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
done

# ============================================================
# 6. Checker — verifica rpath rinominando le cartelle sorgente
# ============================================================
echo "=== Verifica rpath ==="
cd "$WORK"
mv out outt
mv deps_static deps_staticc

python3 -c "
import ctypes, sys
for lib in ['outt/libscip.so.${SCIP_MAJOR_MINOR}', 'outt/libjscip.so']:
    print(f'Carico {lib}...')
    try:
        ctypes.CDLL(lib)
        print('✅ OK')
    except OSError as e:
        print(f'❌ {e}')
        sys.exit(1)
"

mv deps_staticc deps_static
mv outt out

cd "$WORK"
zip -r out.zip out/

# Crea test_package.zip
mkdir -p test_package
cp -r out test_package/
cp resources/ipeoptimtest.zip test_package/
zip -r test_package.zip test_package/
rm -rf test_package

echo "Build Linux completata."

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
