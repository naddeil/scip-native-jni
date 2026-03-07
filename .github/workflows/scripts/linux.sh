#!/usr/bin/env bash
set -euo pipefail

WORK="$GITHUB_WORKSPACE"
PREFIX="$WORK/deps_static"
SCIP_BUILD="$WORK/scipoptsuite/build"
OUT="$WORK/out"
CORES=$(nproc)
SCIP_MAJOR_MINOR=$(echo "$SCIPOPTSUITE_VERSION" | cut -d. -f1-2)

mkdir -p "$PREFIX" "$PREFIX/include" "$PREFIX/lib" "$OUT"

# ============================================================
# 0. Prerequisiti (Amazon Linux 2023)
# ============================================================
dnf install -y --allowerasing \
  gcc gcc-c++ gcc-gfortran make cmake wget curl git unzip zip which \
  tar xz bzip2 patch diffutils pkgconfig m4 perl \
  java-11-amazon-corretto-devel maven.noarch patchelf swig python3 \
  libgfortran libquadmath libstdc++
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac))))


# ============================================================
# 1-2. Dipendenze (skip se cachate)
# ============================================================
if [ "${DEPS_CACHED:-}" != "true" ]; then

source "$WORK/.github/workflows/scripts/deps-versions.env"

cd "$WORK"
mkdir -p staticdepsinstall && cd staticdepsinstall

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:$PATH"

# -----------------------------------------------------------
# GMP, MPFR, Boost
#   - GMP for rational arithmetic in ZIMPL, SoPlex, SCIP, and PaPILO,
#   - Boost multiprecision library for rationals in SCIP (and PaPILO, if linked),
#   - MPFR for approximating rationals with floating-point numbers in SCIP
# -----------------------------------------------------------

curl -LO "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VERSION}.tar.xz"
tar xf "gmp-${GMP_VERSION}.tar.xz" && cd "gmp-${GMP_VERSION}"
CFLAGS="-O3 -fPIC" ./configure --prefix="$PREFIX" --disable-shared --enable-static
make -s -j"$CORES" && make -s install && cd ..

# Boost
BOOST_UNDERSCORE=$(echo "$BOOST_VERSION" | tr '.' '_')
curl -LO "https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${BOOST_UNDERSCORE}.tar.bz2"
tar xf "boost_${BOOST_UNDERSCORE}.tar.bz2" && cd "boost_${BOOST_UNDERSCORE}"
./bootstrap.sh --with-libraries=program_options,serialization,regex,random,iostreams --prefix="$PREFIX"
./b2 -j"$CORES" -d0 link=static runtime-link=static cxxflags="-fPIC -O3" install && cd ..

# OpenBLAS
COMPILE_OB="${COMPILE_OB:-false}"
if [ "$COMPILE_OB" = "true" ]; then
  wget -q "https://github.com/OpenMathLib/OpenBLAS/releases/download/v${OPENBLAS_VERSION}/OpenBLAS-${OPENBLAS_VERSION}.zip"
  unzip -q "OpenBLAS-${OPENBLAS_VERSION}.zip" && mv "OpenBLAS-${OPENBLAS_VERSION}" OpenBLAS && cd OpenBLAS
  unset CFLAGS CXXFLAGS LDFLAGS 2>/dev/null || true
  make -s -j"$CORES" NO_SHARED=1 DYNAMIC_ARCH=1 USE_OPENMP=0 CC=/usr/bin/gcc FC=/usr/bin/gfortran
  make -s PREFIX="$PREFIX" NO_SHARED=1 install
  cd ..
else
  dnf install -y openblas-static openblas-devel
  cp -a /usr/include/openblas/* "$PREFIX/include/" 2>/dev/null || true
  find /usr/lib64 /usr/lib -name "libopenblas*.a" -exec cp {} "$PREFIX/lib/" \; 2>/dev/null || true
fi

# -----------------------------------------------------------
# IPOPT via coinbrew
#   - coinbrew fetch: scarica Ipopt + ThirdParty-Mumps + ThirdParty-ASL in automatico
#   - coinbrew build: compila tutto in sequenza, propaga --with-metis-* anche a
#   - ThirdParty-Mumps (non serve buildare MUMPS separatamente — evita conflitti dir)
#   - mesti
# Solver inclusi nella build: MUMPS no SPRAL, MKL Pardiso ecc. abbiamo problemi piccoli, sono superfluli. 
# L'unico forse utile sarebbe MA27 (ma non potremmo usarlo in teoria, è pubblico ma non permesso per utilizzo commerciale)
# - sIpopt: build in single-precision lo disabilitiamo
# -----------------------------------------------------------

cd "$WORK/staticdepsinstall"
wget -q https://raw.githubusercontent.com/coin-or/coinbrew/master/coinbrew
chmod u+x coinbrew

export CFLAGS="-O3 -fPIC"
export CXXFLAGS="-O3 -fPIC"
export FFLAGS="-O3 -fPIC"
export LC_ALL=C


./coinbrew fetch Ipopt --no-prompt

./coinbrew build Ipopt \
  --prefix="$PREFIX" \
  --no-prompt \
  --verbosity=1 \
  --static \
  --with-blas-lflags="-L$PREFIX/lib -l:libopenblas.a -lgfortran -lquadmath -lm" \
  --with-lapack-lflags="-L$PREFIX/lib -l:libopenblas.a -lgfortran -lquadmath -lm"

./coinbrew install Ipopt --no-prompt

echo "Dipendenze compilate."
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

# NOTA IMPORTANTE da CMakeLists.txt riga 914:
#   if(IPOPT_FOUND) → set(LAPACK off)
# Quando IPOPT è trovato, SCIP forza internamente LAPACK=off, ignorando qualsiasi
# -DLAPACK=on passato da fuori. IPOPT porta già la propria dipendenza BLAS/LAPACK
# (via Mumps) quindi SCIP non ha bisogno di linkarla separatamente.

cmake .. \
  -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$WORK/scip_shared" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_C_FLAGS="-O3 -fPIC" \
  -DCMAKE_CXX_FLAGS="-O3 -fPIC -DCPPAD_MAX_NUM_THREADS=1024" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DSHARED=ON \
  -DBUILD_SHARED_LIBS=ON \
  -DREADLINE=off \
  -DGMP=on \
  -DSTATIC_GMP=on \
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
  -DPAPILO=on \
  -DZLIB=off \
  -DTHREADSAFE=on \
  -DLTO=off \
  -DTPI=tny
  # -DMPFR_LIBRARIES="$PREFIX/lib/libmpfr.a;$PREFIX/lib/libgmp.a" \
# lto potenzialmente migliora ma analizzare bene build (https://hubicka.blogspot.com/2014/04/linktime-optimization-in-gcc-2-firefox.html)

make -s -j"$CORES" && make -s install

# ============================================================
# 4. Compila JSCIPOpt (versione modificata con package it.prometeia.jscip)
# ============================================================
cd "$WORK"
unzip -q resources/JSCIPOpt.zip
cd JSCIPOpt
rm -rf build && mkdir build && cd build
cmake .. -DSCIP_DIR="$SCIP_BUILD" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DJAVA_AWT_LIBRARY=NotNeeded
make -s

# ============================================================
# 5. Genera output (cp -L per dereferenziare symlink)
# ============================================================
cd "$WORK"
rm -rf "$OUT"/*

cp "$WORK/JSCIPOpt/build/Release/scip.jar" "$OUT/"
cp -L "$WORK/JSCIPOpt/build/Release/libjscip.so" "$OUT/"
cp -L "$WORK/scipoptsuite/build/lib/libscip.so" "$OUT/libscip.so.${SCIP_MAJOR_MINOR}"

# --- COPIA DIPENDENZE RUNTIME (Fondamentale per la portabilità) ---
echo "Copia librerie runtime di sistema..."
# Cerchiamo i percorsi reali delle librerie caricate da libscip.so
LIBS_TO_COPY=("libgfortran.so.5" "libquadmath.so.0" "libstdc++.so.6" "libgcc_s.so.1")
for libname in "${LIBS_TO_COPY[@]}"; do
    LIB_PATH=$(ldd "$OUT/libscip.so.${SCIP_MAJOR_MINOR}" | grep "$libname" | awk '{print $3}')
    if [ -f "$LIB_PATH" ]; then
        cp -vL "$LIB_PATH" "$OUT/"
    else
        # Fallback se non risolto da ldd
        cp -vL "/usr/lib64/$libname" "$OUT/" 2>/dev/null || true
    fi
done

# Fix rpath — $ORIGIN permette di cercare le lib nella stessa cartella
cd "$OUT"
for f in *.so*; do
  echo "Patching RPATH for $f"
  patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
done

# ============================================================
# 6. Checker
# ============================================================
echo "=== Verifica caricamento librerie ==="
cd "$WORK"
# Rinominiamo temporaneamente le cartelle di build per simulare un ambiente pulito
mv out out_test
mv deps_static deps_static_hide

python3 -c "
import ctypes, sys, os
libs = ['out_test/libgfortran.so.5', 'out_test/libscip.so.${SCIP_MAJOR_MINOR}', 'out_test/libjscip.so']
for lib in libs:
    path = os.path.abspath(lib)
    print(f'Carico {path}...')
    try:
        ctypes.CDLL(path)
        print('   OK')
    except Exception as e:
        print(f'   ERRORE: {e}')
        sys.exit(1)
"

mv deps_static_hide deps_static
mv out_test out

# Finalizzazione zip
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