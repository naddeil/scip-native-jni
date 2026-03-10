#!/usr/bin/env bash
set -euo pipefail

WORK="$GITHUB_WORKSPACE"
PREFIX="$WORK/deps_static"
SCIP_BUILD="$WORK/scipoptsuite/build"
OUT="$WORK/out"
CORES=$(nproc)
SCIP_MAJOR_MINOR=$(echo "$SCIPOPTSUITE_VERSION" | cut -d. -f1-2)

# Verifica che JSCIPOpt per questa versione sia disponibile
if [ ! -f "$WORK/resources/JSCIPOpt-${SCIPOPTSUITE_VERSION}.zip" ]; then
  echo "Errore: JSCIPOpt-${SCIPOPTSUITE_VERSION}.zip non trovato in resources/"
  echo "Versioni disponibili:"
  for f in "$WORK/resources"/JSCIPOpt-*.zip; do [ -f "$f" ] && basename "$f"; done
  exit 1
fi

mkdir -p "$PREFIX" "$PREFIX/include" "$PREFIX/lib" "$OUT"

# ============================================================
# Tuning flags
# ============================================================
ARCH_FLAGS="-march=x86-64-v2"
OPT_FLAGS="-O3 -fPIC $ARCH_FLAGS"
VIS_FLAGS="-fvisibility=hidden"
VIS_FLAGS_CXX="-fvisibility=hidden -fvisibility-inlines-hidden"
LTO_FLAG="-flto=auto"

# ============================================================
# 0. Prerequisiti (Amazon Linux 2023)
# ============================================================
dnf remove -y java-17-amazon-corretto* 2>/dev/null || true
dnf install -y --allowerasing \
  gcc gcc-c++ gcc-gfortran make cmake wget curl git unzip zip which \
  tar xz bzip2 patch diffutils pkgconfig m4 perl \
  java-11-amazon-corretto-devel maven.noarch patchelf swig python3 glibc-static libstdc++-static
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac))))


# ============================================================
# 1-2. Dipendenze (skip se cachate)
# ============================================================
if [ "${DEPS_CACHED:-}" != "true" ]; then

DEPS_FILE="$WORK/.github/workflows/scripts/deps-versions-${SCIPOPTSUITE_VERSION}.env"
if [ ! -f "$DEPS_FILE" ]; then
  echo "Errore: File dipendenze $DEPS_FILE non trovato"
  exit 1
fi
source "$DEPS_FILE"

cd "$WORK"
mkdir -p staticdepsinstall && cd staticdepsinstall

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin:$PATH"
ln -sf /usr/bin/curl /usr/local/bin/curl 2>/dev/null || true
ln -sf /usr/bin/wget /usr/local/bin/wget 2>/dev/null || true

# -----------------------------------------------------------
# GMP
# -----------------------------------------------------------
echo ">>> GMP ${GMP_VERSION}"
curl -sLO "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VERSION}.tar.xz"
tar xf "gmp-${GMP_VERSION}.tar.xz" && cd "gmp-${GMP_VERSION}"
CFLAGS="$OPT_FLAGS" CPPFLAGS="-DPIC" ./configure --prefix="$PREFIX" --with-pic --disable-shared > /dev/null 2>&1
make -s -j"$CORES" > /dev/null 2>&1 && make -s install > /dev/null 2>&1 && cd ..
echo "    OK: $(ls -lh "$PREFIX/lib/libgmp.a" | awk '{print $5}')"

# -----------------------------------------------------------
# Boost
# -----------------------------------------------------------
echo ">>> Boost ${BOOST_VERSION}"
BOOST_UNDERSCORE=$(echo "$BOOST_VERSION" | tr '.' '_')
curl -sLO "https://archives.boost.io/release/${BOOST_VERSION}/source/boost_${BOOST_UNDERSCORE}.tar.bz2"
tar xf "boost_${BOOST_UNDERSCORE}.tar.bz2" && cd "boost_${BOOST_UNDERSCORE}"
./bootstrap.sh --with-libraries=program_options,serialization,regex,random,iostreams --prefix="$PREFIX" > /dev/null 2>&1
./b2 -j"$CORES" -d0 link=static runtime-link=static cxxflags="$OPT_FLAGS" install > /dev/null 2>&1 && cd ..
echo "    OK"

# -----------------------------------------------------------
# libgfortran.a + libquadmath.a statiche con -fPIC
# -----------------------------------------------------------
echo ">>> libgfortran.a + libquadmath.a (GCC ${GCC_VERSION})"
FORTRAN_BUILD="$WORK/staticdepsinstall/gcc-fortran-pic"
mkdir -p "$FORTRAN_BUILD" && cd "$FORTRAN_BUILD"
wget -q "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz"
tar xf "gcc-${GCC_VERSION}.tar.xz"
cd "gcc-${GCC_VERSION}"
./contrib/download_prerequisites > /dev/null 2>&1

mkdir -p "$FORTRAN_BUILD/build" && cd "$FORTRAN_BUILD/build"
"$FORTRAN_BUILD/gcc-${GCC_VERSION}/configure" \
  --prefix="$PREFIX" \
  --enable-languages=c,fortran \
  --disable-bootstrap --disable-multilib --disable-shared --enable-static --with-pic \
  --disable-libsanitizer --disable-libgomp --disable-libvtv --disable-libatomic \
  --disable-libstdcxx --disable-libssp --disable-libcc1 --disable-libitm \
  --without-isl > /dev/null 2>&1

make -s -j"$CORES" all-gcc                > /dev/null 2>&1
make -s -j"$CORES" all-target-libquadmath > /dev/null 2>&1
make -s -j"$CORES" all-target-libgfortran > /dev/null 2>&1
make -s install-target-libquadmath        > /dev/null 2>&1
make -s install-target-libgfortran        > /dev/null 2>&1
find "$PREFIX" -name '*.so*' -delete 2>/dev/null || true

find "$PREFIX" -name 'libgfortran.a' -exec cp {} "$PREFIX/lib/" \;
find "$PREFIX" -name 'libquadmath.a' -exec cp {} "$PREFIX/lib/" \;

GCC_LIB_DIR=$(dirname "$(gfortran -print-libgcc-file-name)")
ln -sf "$PREFIX/lib/libgfortran.a" "$GCC_LIB_DIR/libgfortran.a"
ln -sf "$PREFIX/lib/libquadmath.a" "$GCC_LIB_DIR/libquadmath.a"
rm -f "$GCC_LIB_DIR"/libgfortran.so* /usr/lib64/libgfortran.so* /usr/lib/libgfortran.so* 2>/dev/null || true
rm -f "$GCC_LIB_DIR"/libquadmath.so* /usr/lib64/libquadmath.so* /usr/lib/libquadmath.so* 2>/dev/null || true

for LIB in libgfortran.a libquadmath.a; do
  P=$(find "$PREFIX/lib" -name "$LIB" -print -quit)
  echo "    $LIB $(ls -lh "$P" | awk '{print $5}')"
done

cd "$WORK/staticdepsinstall"

# -----------------------------------------------------------
# OpenBLAS
# -----------------------------------------------------------
echo ">>> OpenBLAS ${OPENBLAS_VERSION} (DYNAMIC_ARCH=1)"
wget -q "https://github.com/OpenMathLib/OpenBLAS/releases/download/v${OPENBLAS_VERSION}/OpenBLAS-${OPENBLAS_VERSION}.zip"
unzip -q "OpenBLAS-${OPENBLAS_VERSION}.zip" && mv "OpenBLAS-${OPENBLAS_VERSION}" OpenBLAS && cd OpenBLAS
unset CFLAGS CXXFLAGS LDFLAGS LIBRARY_PATH LD_LIBRARY_PATH CPATH PKG_CONFIG_PATH 2>/dev/null || true
make -s -j"$CORES" NO_SHARED=1 DYNAMIC_ARCH=1 USE_OPENMP=0 CC=/usr/bin/gcc FC=/usr/bin/gfortran > /dev/null 2>&1
make -s PREFIX="$PREFIX" NO_SHARED=1 install > /dev/null 2>&1
cd ..

if [ ! -f "$PREFIX/lib/libopenblas.a" ]; then
  OB_LIB=$(find "$PREFIX" -name 'libopenblas*.a' -print -quit)
  if [ -n "$OB_LIB" ]; then
    ln -sf "$OB_LIB" "$PREFIX/lib/libopenblas.a"
  else
    echo "ERRORE: nessuna libopenblas*.a!" && exit 1
  fi
fi
echo "    OK: $(ls -lh "$PREFIX/lib/libopenblas.a" | awk '{print $5}')"

BLAS_LAPACK_LFLAGS="-L$PREFIX/lib -lopenblas -lgfortran -lquadmath -lm"

# -----------------------------------------------------------
# GKlib + METIS
# -----------------------------------------------------------
echo ">>> GKlib + METIS"
cd "$WORK/staticdepsinstall"

wget -q "https://github.com/KarypisLab/GKlib/archive/refs/tags/METIS-v5.1.1-DistDGL-0.5.tar.gz"
tar xf "METIS-v5.1.1-DistDGL-0.5.tar.gz"
cd "GKlib-METIS-v5.1.1-DistDGL-0.5"
sed -i 's/^CONFIG_FLAGS =/CONFIG_FLAGS = -DCMAKE_POLICY_VERSION_MINIMUM=3.5/' Makefile
make config prefix="$PREFIX" cc=/usr/bin/gcc "CFLAGS=$OPT_FLAGS" > /dev/null 2>&1
make -j"$CORES" > /dev/null 2>&1 && make install > /dev/null 2>&1
cd ..

wget -q "https://github.com/KarypisLab/METIS/archive/refs/tags/v5.1.1-DistDGL-v0.5.tar.gz"
tar xf "v5.1.1-DistDGL-v0.5.tar.gz"
cd "METIS-5.1.1-DistDGL-v0.5"
sed -i 's/^CONFIG_FLAGS =/CONFIG_FLAGS = -DCMAKE_POLICY_VERSION_MINIMUM=3.5/' Makefile
make config prefix="$PREFIX" gklib_path="$WORK/staticdepsinstall/GKlib-METIS-v5.1.1-DistDGL-0.5" cc=/usr/bin/gcc "CFLAGS=$OPT_FLAGS" > /dev/null 2>&1
make -j"$CORES" > /dev/null 2>&1 && make install > /dev/null 2>&1
cd ..
echo "    OK: $(ls -lh "$PREFIX/lib/libmetis.a" | awk '{print $5}')"

# -----------------------------------------------------------
# ThirdParty-Mumps
# -----------------------------------------------------------
echo ">>> ThirdParty-Mumps"
cd "$WORK/staticdepsinstall"
git clone -q https://github.com/coin-or-tools/ThirdParty-Mumps.git
cd ThirdParty-Mumps
./get.Mumps > /dev/null 2>&1
./configure \
  --prefix="$PREFIX" --enable-shared=no --enable-static=yes --with-pic \
  CFLAGS="$OPT_FLAGS" FCFLAGS="$OPT_FLAGS" CXXFLAGS="$OPT_FLAGS" \
  --with-metis-cflags="-I$PREFIX/include" \
  --with-metis-lflags="-L$PREFIX/lib -lmetis -lm" \
  --with-lapack-lflags="$BLAS_LAPACK_LFLAGS" > /dev/null 2>&1
make -j"$CORES" > /dev/null 2>&1 && make install > /dev/null 2>&1
cd ..
echo "    OK: $(ls -lh "$PREFIX/lib/libcoinmumps.a" | awk '{print $5}')"

# -----------------------------------------------------------
# Ipopt
# -----------------------------------------------------------
echo ">>> Ipopt ${IPOPT_VERSION}"
cd "$WORK/staticdepsinstall"
wget -q "https://github.com/coin-or/Ipopt/archive/refs/tags/releases/${IPOPT_VERSION}.zip" -O "ipopt-${IPOPT_VERSION}.zip"
unzip -q "ipopt-${IPOPT_VERSION}.zip"
cd "Ipopt-releases-${IPOPT_VERSION}"
mkdir -p build && cd build

../configure \
  --prefix="$PREFIX" --enable-shared=no --enable-static=yes --with-pic \
  --disable-sipopt --disable-java --without-hsl --without-asl \
  CFLAGS="$OPT_FLAGS" CXXFLAGS="$OPT_FLAGS" FFLAGS="$OPT_FLAGS" \
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
  --with-lapack-lflags="$BLAS_LAPACK_LFLAGS" > /dev/null 2>&1

make -j"$CORES" > /dev/null 2>&1 && make install > /dev/null 2>&1
cd ../..
echo "    OK: $(ls -lh "$PREFIX/lib/libipopt.a" | awk '{print $5}')"

echo ">>> Dipendenze completate."
fi


# ============================================================
# 3. Download e compila SCIP
# ============================================================
cd "$WORK"
tar -xzf "resources/scipoptsuite-${SCIPOPTSUITE_VERSION}.tgz"
mv "scipoptsuite-${SCIPOPTSUITE_VERSION}" scipoptsuite

# -----------------------------------------------------------
# Version script — opera a livello linker, non compiler.
# Anche se CMake sovrascrive -fvisibility=hidden nei CFLAGS,
# il version script forza local: * su tutto tranne i simboli
# esplicitamente elencati. Dà a LTO la stessa informazione di
# non-interposizione, permettendo inline/eliminazione cross-modulo.
# -----------------------------------------------------------
cat > "$WORK/scipoptsuite/libscip.map" << 'MAPEOF'
LIBSCIP {
  global:
    SCIP*;
    SCIPopt*;
    SoPlex*;
    soplex*;
    JNI_*;
    Java_*;
    BMSallocMemory*;
    BMSfreeMemory*;
    BMSreallocMemory*;
  local:
    *;
};
MAPEOF

cd "$WORK/scipoptsuite"
rm -rf build && mkdir -p build && cd build

LIBGFORTRAN_A=$(find "$PREFIX" -name 'libgfortran.a' -print -quit)
LIBQUADMATH_A=$(find "$PREFIX" -name 'libquadmath.a' -print -quit)

cmake .. \
  -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$WORK/scip_shared" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_C_FLAGS="$OPT_FLAGS $VIS_FLAGS" \
  -DCMAKE_CXX_FLAGS="$OPT_FLAGS $VIS_FLAGS_CXX -DCPPAD_MAX_NUM_THREADS=1024" \
  -DCMAKE_C_VISIBILITY_PRESET=hidden \
  -DCMAKE_CXX_VISIBILITY_PRESET=hidden \
  -DCMAKE_VISIBILITY_INLINES_HIDDEN=ON \
  -DCMAKE_EXE_LINKER_FLAGS="-O3 $LTO_FLAG $ARCH_FLAGS -L$PREFIX/lib -Wl,--start-group -lipopt -lcoinmumps -lmetis -lopenblas -lgfortran -lquadmath -Wl,--end-group -lm -lpthread" \
  -DCMAKE_SHARED_LINKER_FLAGS="-O3 $LTO_FLAG $ARCH_FLAGS -L$PREFIX/lib -lmetis -lopenblas -lgfortran -lquadmath -lm -Wl,--version-script=$WORK/scipoptsuite/libscip.map" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DBLAS_LIBRARIES="$PREFIX/lib/libopenblas.a;$PREFIX/lib/libgfortran.a;$PREFIX/lib/libquadmath.a;m" \
  -DLAPACK_LIBRARIES="$PREFIX/lib/libopenblas.a;$PREFIX/lib/libgfortran.a;$PREFIX/lib/libquadmath.a;m" \
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
  -DIPOPT_DIR="$PREFIX" \
  -DIPOPT_LIBRARIES="$PREFIX/lib/libipopt.a;$PREFIX/lib/libcoinmumps.a;$PREFIX/lib/libmetis.a;$PREFIX/lib/libopenblas.a;$PREFIX/lib/libgfortran.a;$PREFIX/lib/libquadmath.a;m" \
  -DTBB=off \
  -DFILTERSQP=off \
  -DMPFR=off \
  -DWORHP=off \
  -DBOOST_ROOT="$PREFIX" \
  -DPAPILO=off \
  -DZLIB=off \
  -DTHREADSAFE=on \
  -DLTO=on \
  -DTPI=tny \
  -DGCG=off \
  -DUG=off

# Stampa primi comandi di compilazione per verificare flag
echo ">>> Flag compilazione effettivi:"
make VERBOSE=1 -j1 libscip 2>&1 | grep -m3 -E '/(gcc|g\+\+) ' | sed 's|/.*/scipoptsuite/|.../|g; s| -I[^ ]*||g; s|  *| |g' || true
echo "---"

# Build completa
make -s -j"$CORES" libscip soplex


# ============================================================
# Verifiche post-build
# ============================================================
echo ""
echo ">>> Verifica dipendenze dinamiche:"
if ldd "$WORK/scipoptsuite/build/lib/libscip.so" | grep -qE 'libgfortran|libquadmath'; then
  echo "ERRORE: dipendenze Fortran dinamiche!"
  ldd "$WORK/scipoptsuite/build/lib/libscip.so" | grep -E 'gfortran|quadmath'
  exit 1
fi
echo "OK: libgfortran/libquadmath statiche"

echo ">>> Verifica LTO:"
LTO_SECTIONS=$(readelf -S "$WORK/scipoptsuite/build/lib/libscip.so" 2>/dev/null | grep -c '\.gnu\.lto' || true)
if [ "$LTO_SECTIONS" -gt 0 ]; then
  echo "ATTENZIONE: $LTO_SECTIONS sezioni .gnu.lto residue"
else
  echo "OK: nessuna sezione .gnu.lto residua"
fi

echo ">>> Verifica visibility (version script):"
DYNSYM_COUNT=$(nm -D --defined-only "$WORK/scipoptsuite/build/lib/libscip.so" 2>/dev/null | wc -l)
echo "Simboli dynamic export: $DYNSYM_COUNT"
if [ "$DYNSYM_COUNT" -gt 3000 ]; then
  echo "ERRORE: $DYNSYM_COUNT simboli — version script non attivo?"
  echo "Top 20 non-SCIP:"
  nm -D --defined-only "$WORK/scipoptsuite/build/lib/libscip.so" \
    | grep -v -E ' (SCIP|SCIPopt|SoPlex|soplex|JNI_|Java_|BMS)' | head -20
  # exit 1
fi
echo "OK: $DYNSYM_COUNT simboli"


# ============================================================
# 4. Compila JSCIPOpt
# ============================================================
cd "$WORK"
unzip -q resources/JSCIPOpt-${SCIPOPTSUITE_VERSION}.zip
cd JSCIPOpt
rm -f src/*cxx src/*h 2>/dev/null || true
rm -rf build && mkdir build && cd build
cmake .. -DSCIP_DIR="$SCIP_BUILD" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DJAVA_AWT_LIBRARY=NotNeeded \
  -DCMAKE_C_FLAGS="$OPT_FLAGS" \
  -DCMAKE_CXX_FLAGS="$OPT_FLAGS"
make -s

# ============================================================
# 5. Genera output
# ============================================================
cd "$WORK"
rm -rf "$OUT"/*

cp "$WORK/JSCIPOpt/build/Release/scip.jar" "$OUT/"
cp -L "$WORK/JSCIPOpt/build/Release/libjscip.so" "$OUT/"
cp -L "$WORK/scipoptsuite/build/lib/libscip.so" "$OUT/libscip.so.${SCIP_MAJOR_MINOR}"

cd "$OUT"
for f in *.so*; do
  SIZE_BEFORE=$(stat -c%s "$f")
  strip --strip-unneeded "$f" 2>/dev/null || true
  SIZE_AFTER=$(stat -c%s "$f")
  echo "Strip: $f  $SIZE_BEFORE → $SIZE_AFTER  (-$(( (SIZE_BEFORE - SIZE_AFTER) * 100 / SIZE_BEFORE ))%)"
done

for f in *.so*; do
  patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
done

cd "$WORK"
zip -r out.zip out/

mkdir -p test_package
cp -r out test_package/
cp resources/ipeoptimtest.zip test_package/
zip -r test_package.zip test_package/
rm -rf test_package

echo "Build Linux completata."