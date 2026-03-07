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
dnf install -y --allowerasing \
  gcc gcc-c++ gcc-gfortran make cmake wget curl git unzip zip which \
  tar xz bzip2 patch diffutils pkgconfig m4 perl \
  java-11-amazon-corretto-devel maven.noarch patchelf swig python3 \
  java-11-amazon-corretto-headful \
  hwloc-devel hwloc
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac))))


# ============================================================
# 1-2. Dipendenze (skip se cachate)
# ============================================================
if [ "${DEPS_CACHED:-}" != "true" ]; then

cd "$WORK"
mkdir -p staticdepsinstall && cd staticdepsinstall

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:$PATH"

ln -sf /usr/bin/curl /usr/local/bin/curl 2>/dev/null || true
ln -sf /usr/bin/wget /usr/local/bin/wget 2>/dev/null || true


# -----------------------------------------------------------
# GMP, MPFR, Boost
# -----------------------------------------------------------

curl -LO https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz
tar xf gmp-6.3.0.tar.xz && cd gmp-6.3.0
CFLAGS="-O3 -fPIC" ./configure --prefix="$PREFIX"
make -s -j"$CORES" && make -s install && cd ..

curl -LO https://www.mpfr.org/mpfr-current/mpfr-4.2.2.tar.xz
tar xf mpfr-4.2.2.tar.xz && cd mpfr-4.2.2
CFLAGS="-O3 -fPIC" ./configure --prefix="$PREFIX" --with-gmp="$PREFIX"
make -s -j"$CORES" && make -s install && cd ..

curl -LO https://archives.boost.io/release/1.85.0/source/boost_1_85_0.tar.bz2
tar xf boost_1_85_0.tar.bz2 && cd boost_1_85_0
./bootstrap.sh --with-libraries=program_options,serialization,regex,random,iostreams --prefix="$PREFIX"
./b2 -j"$CORES" -d0 link=static runtime-link=static cxxflags="-fPIC -O3" install && cd ..

# -----------------------------------------------------------
# OpenBLAS — BLAS + LAPACK + LAPACKE ottimizzati
# -----------------------------------------------------------
wget -q https://github.com/OpenMathLib/OpenBLAS/releases/download/v0.3.30/OpenBLAS-0.3.30.zip
unzip -q OpenBLAS-0.3.30.zip && mv OpenBLAS-0.3.30 OpenBLAS && cd OpenBLAS
unset CFLAGS CXXFLAGS LDFLAGS LIBRARY_PATH LD_LIBRARY_PATH CPATH PKG_CONFIG_PATH 2>/dev/null || true
make -s -j"$CORES" NO_SHARED=0 DYNAMIC_ARCH=1 USE_OPENMP=0 CC=/usr/bin/gcc FC=/usr/bin/gfortran
make -s PREFIX="$PREFIX" install
ln -sf "$PREFIX/lib/libopenblas.so" "$PREFIX/lib/libblas.so"
ln -sf "$PREFIX/lib/libopenblas.so" "$PREFIX/lib/liblapack.so"
cd ..

# -----------------------------------------------------------
# METIS 5.1.1 — ordinamento matrice sparsa
# Migliora MUMPS sui problemi con matrici sparse
# -----------------------------------------------------------
# cd "$WORK/staticdepsinstall"

# wget -q https://github.com/KarypisLab/GKlib/archive/refs/tags/METIS-v5.1.1-DistDGL-0.5.tar.gz
# tar -xf METIS-v5.1.1-DistDGL-0.5.tar.gz
# GKLIB_SRC="$WORK/staticdepsinstall/GKlib-METIS-v5.1.1-DistDGL-0.5"
# cd GKlib-METIS-v5.1.1-DistDGL-0.5
# sed -i 's/^CONFIG_FLAGS =/CONFIG_FLAGS = -DCMAKE_POLICY_VERSION_MINIMUM=3.5/' Makefile
# make config prefix="$GKLIB_SRC"
# make -j"$CORES" && make install
# cd ..

# wget -q https://github.com/KarypisLab/METIS/archive/refs/tags/v5.1.1-DistDGL-v0.5.tar.gz
# tar -xf v5.1.1-DistDGL-v0.5.tar.gz
# cd METIS-5.1.1-DistDGL-v0.5
# sed -i 's/^CONFIG_FLAGS =/CONFIG_FLAGS = -DCMAKE_POLICY_VERSION_MINIMUM=3.5/' Makefile
# make config prefix="$PREFIX" gklib_path="$GKLIB_SRC"
# make -j"$CORES" && make install
# cd ..

# METIS_CFLAGS="-I$PREFIX/include"
# METIS_LFLAGS="-L$PREFIX/lib -lmetis -lm"

# -----------------------------------------------------------
# IPOPT via coinbrew
# coinbrew fetch: scarica Ipopt + ThirdParty-Mumps + ThirdParty-ASL in automatico
# coinbrew build: compila tutto in sequenza, propaga --with-metis-* anche a
#   ThirdParty-Mumps (non serve buildare MUMPS separatamente — evita conflitti dir)
# Solver inclusi nella build: MUMPS (no SPRAL, MKL Pardiso ecc.)
# sIpopt is build in single-precision disabilitiamo
# -----------------------------------------------------------
cd "$WORK/staticdepsinstall"

wget -q https://raw.githubusercontent.com/coin-or/coinbrew/master/coinbrew
chmod u+x coinbrew

export CFLAGS="-O3 -fPIC"
export CXXFLAGS="-O3 -fPIC"
export FFLAGS="-O3 -fPIC"

./coinbrew fetch Ipopt --no-prompt

./coinbrew build Ipopt \
  --prefix="$PREFIX" \
  --no-prompt \
  --verbosity=3 \
  --enable-shared=yes \
  --enable-static=no \
  --enable-sipopt=no \
  --with-lapack-lflags="-L$PREFIX/lib -lopenblas"
  # --with-metis-cflags="$METIS_CFLAGS" \
  # --with-metis-lflags="$METIS_LFLAGS" \

if [ "${TESTS:-OFF}" = "ON" ]; then
  ./coinbrew test Ipopt --no-prompt || true
fi

./coinbrew install Ipopt --no-prompt

echo "Dipendenze compilate."

# ============================================================
# 3. Download e compila SCIP
# ============================================================
cd "$WORK"
curl -LO "https://www.scipopt.org/download/release/scipoptsuite-${SCIPOPTSUITE_VERSION}.tgz"
tar -xzf "scipoptsuite-${SCIPOPTSUITE_VERSION}.tgz"
mv "scipoptsuite-${SCIPOPTSUITE_VERSION}" scipoptsuite

cd "$WORK/scipoptsuite"
rm -rf build && mkdir -p build && cd build

# NOTA IMPORTANTE da CMakeLists.txt riga 914:
#   if(IPOPT_FOUND) → set(LAPACK off)
# Quando IPOPT è trovato, SCIP forza internamente LAPACK=off, ignorando qualsiasi
# -DLAPACK=on passato da fuori. IPOPT porta già la propria dipendenza BLAS/LAPACK
# (via Mumps) nel suo .pc file — SCIP non ha bisogno di linkarla separatamente.
cmake .. \
  -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$WORK/scip_shared" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_C_FLAGS="-O3 -fPIC" \
  -DCMAKE_CXX_FLAGS="-O3 -fPIC -DCPPAD_MAX_NUM_THREADS=1024" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DSHARED=$SHARED_FLAG \
  -DBUILD_SHARED_LIBS=$BUILD_SHARED \
  -DREADLINE=off \
  -DGMP=on \
  -DGMP_DIR="$PREFIX" \
  -DZIMPL=off \
  -DLPS=spx \
  -DSOPLEX_DIR="../soplex" \
  -DIPOPT=on \
  -DTBB=off \
  -DIPOPT_DIR="$PREFIX" \
  -DFILTERSQP=off \
  -DWORHP=off \
  -DBOOST_ROOT="$PREFIX" \
  -DLTO=on \
  -DPAPILO=on \
  -DZLIB=off \
  -DTHREADSAFE=on \
  -DTPI=none

make -s -j"$CORES" && make -s install

# ============================================================
# 4. Compila JSCIPOpt (versione modificata con package it.prometeia.jscip)
# ============================================================
cd "$WORK"
unzip -q resources/JSCIPOpt.zip
cd JSCIPOpt
rm -f src/*cxx src/*h 2>/dev/null || true
rm -rf build && mkdir build && cd build
cmake .. -DSCIP_DIR="$SCIP_BUILD" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
make -s

# ============================================================
# 5. Genera output (cp -L per dereferenziare symlink)
# ============================================================
cd "$WORK"
rm -rf "$OUT"/*

cp "$WORK/JSCIPOpt/build/Release/scip.jar" "$OUT/"
cp -L "$WORK/JSCIPOpt/build/Release/libjscip.so" "$OUT/"
cp -L "$WORK/scipoptsuite/build/lib/libscip.so" "$OUT/libscip.so.${SCIP_MAJOR_MINOR}"

# Dipendenze runtime dal prefix custom
# libopenblas.so copre sia BLAS che LAPACK per tutti i consumer.
for lib in libmpfr.so libopenblas.so libgmp.so libipopt.so; do
  [ -f "$PREFIX/lib/$lib" ] && cp -L "$PREFIX/lib/$lib" "$OUT/" || true
done
cp -L "$PREFIX/lib/libcoinmumps.so" "$OUT/" 2>/dev/null || true


# Librerie di sistema
for syslib in libgcc_s.so.1 libgfortran.so.5 libstdc++.so.6 libquadmath.so.0 libc.so.6 libm.so.6; do
  FOUND=$(find /usr/lib64 /lib64 /usr/lib -name "$syslib" 2>/dev/null | head -1) || true
  [ -n "${FOUND:-}" ] && cp -L "$FOUND" "$OUT/" || true
done

# Rinomina con soname (solo lib con soname convenzionale noto)
cd "$OUT"
[ -f libmpfr.so ]      && mv libmpfr.so      libmpfr.so.6
[ -f libopenblas.so ]  && mv libopenblas.so  libopenblas.so.0
[ -f libgmp.so ]       && mv libgmp.so       libgmp.so.10
[ -f libipopt.so ]     && mv libipopt.so     libipopt.so.3
[ -f libcoinmumps.so ] && mv libcoinmumps.so libcoinmumps.so.3

# Fix rpath — $ORIGIN permette di caricare le dipendenze dalla stessa cartella
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
        print('OK')
    except OSError as e:
        print(f'ERRORE: {e}')
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