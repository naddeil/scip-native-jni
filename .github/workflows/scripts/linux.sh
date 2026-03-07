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
  java-11-amazon-corretto-devel maven.noarch patchelf swig python3
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac))))


# ============================================================
# 1-2. Dipendenze (skip se cachate)
# ============================================================
if [ "${DEPS_CACHED:-}" != "true" ]; then

# Carica versioni dipendenze
source "$WORK/.github/workflows/scripts/deps-versions.env"

cd "$WORK"
mkdir -p staticdepsinstall && cd staticdepsinstall

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:$PATH"

ln -sf /usr/bin/curl /usr/local/bin/curl 2>/dev/null || true
ln -sf /usr/bin/wget /usr/local/bin/wget 2>/dev/null || true


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

# curl -LO "https://www.mpfr.org/mpfr-current/mpfr-${MPFR_VERSION}.tar.xz"
# tar xf "mpfr-${MPFR_VERSION}.tar.xz" && cd "mpfr-${MPFR_VERSION}"
# CFLAGS="-O3 -fPIC" ./configure --prefix="$PREFIX" --with-gmp="$PREFIX" --disable-shared --enable-static
# make -s -j"$CORES" && make -s install && cd ..

BOOST_UNDERSCORE=$(echo "$BOOST_VERSION" | tr '.' '_')
curl -LO "https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${BOOST_UNDERSCORE}.tar.bz2"
tar xf "boost_${BOOST_UNDERSCORE}.tar.bz2" && cd "boost_${BOOST_UNDERSCORE}"
./bootstrap.sh --with-libraries=program_options,serialization,regex,random,iostreams --prefix="$PREFIX"
./b2 -j"$CORES" -d0 link=static runtime-link=static cxxflags="-fPIC -O3" install && cd ..

# -----------------------------------------------------------
# libgfortran.a + libquadmath.a statiche con -fPIC
# Le versioni di sistema (libgfortran-static) non hanno -fPIC,
# quindi ricompiliamo GCC target libraries con --with-pic.
# -----------------------------------------------------------
echo ">>> Build libgfortran.a + libquadmath.a con -fPIC (GCC ${GCC_VERSION}) …"
FORTRAN_BUILD="$WORK/staticdepsinstall/gcc-fortran-pic"
mkdir -p "$FORTRAN_BUILD" && cd "$FORTRAN_BUILD"
wget -q "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz"
tar xf "gcc-${GCC_VERSION}.tar.xz"
cd "gcc-${GCC_VERSION}"
./contrib/download_prerequisites

mkdir -p "$FORTRAN_BUILD/build" && cd "$FORTRAN_BUILD/build"
"$FORTRAN_BUILD/gcc-${GCC_VERSION}/configure" \
  --prefix="$PREFIX" \
  --enable-languages=c,fortran \
  --disable-bootstrap \
  --disable-multilib \
  --disable-shared \
  --enable-static \
  --with-pic \
  --disable-libsanitizer \
  --disable-libgomp \
  --disable-libvtv \
  --disable-libatomic \
  --disable-libstdcxx \
  --disable-libssp \
  --disable-libcc1 \
  --disable-libitm \
  --without-isl

make -s -j"$CORES" all-gcc
make -s -j"$CORES" all-target-libquadmath
make -s -j"$CORES" all-target-libgfortran
make install-target-libquadmath
make install-target-libgfortran
find "$PREFIX" -name '*.so*' -delete 2>/dev/null || true

# Copia le .a in $PREFIX/lib per uniformità (GCC le installa in lib/gcc/...)
find "$PREFIX" -name 'libgfortran.a' -exec cp {} "$PREFIX/lib/" \;
find "$PREFIX" -name 'libquadmath.a' -exec cp {} "$PREFIX/lib/" \;

echo ">>> Verifica PIC libgfortran/libquadmath:"
for LIB in libquadmath.a libgfortran.a; do
  P=$(find "$PREFIX" -name "$LIB" -print -quit)
  echo "  $LIB → $P ($(ls -lh "$P" | awk '{print $5}'))"
done

cd "$WORK/staticdepsinstall"

# -----------------------------------------------------------
# OpenBLAS — BLAS + LAPACK + LAPACKE ottimizzati
# Buildiamo noi e non scarichiamo già fatti poichè ci serve DYNAMIC_ARCH=1 per supportare tutte le cpu
# -----------------------------------------------------------
COMPILE_OB="${COMPILE_OB:-false}"
if [ "$COMPILE_OB" = "true" ]; then
  echo ">>> OpenBLAS: compilazione da sorgente (DYNAMIC_ARCH=1) …"
  wget -q "https://github.com/OpenMathLib/OpenBLAS/releases/download/v${OPENBLAS_VERSION}/OpenBLAS-${OPENBLAS_VERSION}.zip"
  unzip -q "OpenBLAS-${OPENBLAS_VERSION}.zip" && mv "OpenBLAS-${OPENBLAS_VERSION}" OpenBLAS && cd OpenBLAS
  unset CFLAGS CXXFLAGS LDFLAGS LIBRARY_PATH LD_LIBRARY_PATH CPATH PKG_CONFIG_PATH 2>/dev/null || true
  make -s -j"$CORES" NO_SHARED=1 DYNAMIC_ARCH=1 USE_OPENMP=0 CC=/usr/bin/gcc FC=/usr/bin/gfortran
  make -s PREFIX="$PREFIX" NO_SHARED=1 install
  cd ..
else
  echo ">>> OpenBLAS: installazione da package manager (dnf) …"
  dnf install -y openblas-static openblas-devel
  # Copia headers e libreria statica nel prefix per uniformità col resto del build
  cp -a /usr/include/openblas/* "$PREFIX/include/" 2>/dev/null \
    || cp -a /usr/include/lapacke*.h /usr/include/cblas*.h /usr/include/f77blas.h \
             /usr/include/openblas_config.h "$PREFIX/include/" 2>/dev/null || true
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

# Rimuoviamo export globali che rompono i test di configurazione di ASL
unset CFLAGS CXXFLAGS FFLAGS LDFLAGS
export LC_ALL=C

./coinbrew fetch Ipopt --no-prompt

# Scarichiamo esplicitamente i sorgenti ASL e Mumps
(cd ThirdParty/Mumps && ./get.Mumps)

# Passiamo i flag come ADDITIONAL_ per non inquinare il 'configure'
./coinbrew build Ipopt \
  --prefix="$PREFIX" \
  --no-prompt \
  --verbosity=1 \
  --static \
  --disable-shared \
  ADDITIONAL_CFLAGS="-O3 -fPIC" \
  ADDITIONAL_CXXFLAGS="-O3 -fPIC" \
  ADDITIONAL_FFLAGS="-O3 -fPIC" \
  --with-blas-lflags="-L$PREFIX/lib -l:libopenblas.a -l:libgfortran.a -l:libquadmath.a -lm" \
  --with-lapack-lflags="-L$PREFIX/lib -l:libopenblas.a -l:libgfortran.a -l:libquadmath.a -lm"

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

# Trova le .a di Fortran compilate con -fPIC
LIBGFORTRAN_A=$(find "$PREFIX" -name 'libgfortran.a' -print -quit)
LIBQUADMATH_A=$(find "$PREFIX" -name 'libquadmath.a' -print -quit)
echo "Fortran static libs: $LIBGFORTRAN_A $LIBQUADMATH_A"

cmake .. \
  -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$WORK/scip_shared" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_C_FLAGS="-O3 -fPIC" \
  -DCMAKE_CXX_FLAGS="-O3 -fPIC -DCPPAD_MAX_NUM_THREADS=1024" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_SHARED_LINKER_FLAGS="$LIBGFORTRAN_A $LIBQUADMATH_A" \
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
rm -f src/*cxx src/*h 2>/dev/null || true
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


# Fix rpath — $ORIGIN permette di caricare le dipendenze dalla stessa cartella
cd "$OUT"
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