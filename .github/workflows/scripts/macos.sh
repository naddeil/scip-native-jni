#!/usr/bin/env bash
set -euo pipefail

WORK="$GITHUB_WORKSPACE"
PREFIX="$WORK/deps_static"
SCIP_BUILD="$WORK/scipoptsuite/build"
OUT="$WORK/out"
CORES=$(sysctl -n hw.logicalcpu)
SCIP_MAJOR_MINOR=$(echo "$SCIPOPTSUITE_VERSION" | cut -d. -f1-2)
PGO_DIR="$WORK/pgo_profiles"

# ============================================================
# Detect architettura
# ============================================================
ARCH="$(uname -m)"   # arm64 oppure x86_64
echo ">>> Build macOS per $ARCH"

# Verifica che JSCIPOpt per questa versione sia disponibile
if [ ! -f "$WORK/resources/JSCIPOpt-${SCIPOPTSUITE_VERSION}.zip" ]; then
  echo "Errore: JSCIPOpt-${SCIPOPTSUITE_VERSION}.zip non trovato in resources/"
  echo "Versioni disponibili:"
  for f in "$WORK/resources"/JSCIPOpt-*.zip; do [ -f "$f" ] && basename "$f"; done
  exit 1
fi

# Verifica risorse PGO
if [ ! -f "$WORK/resources/PROBS.zip" ]; then
  echo "Errore: PROBS.zip non trovato in resources/"
  exit 1
fi
if [ ! -f "$WORK/resources/smoke_test_scip.c" ]; then
  echo "Errore: smoke_test_scip.c non trovato in resources/"
  exit 1
fi

mkdir -p "$PREFIX" "$PREFIX/include" "$PREFIX/lib" "$OUT" "$PGO_DIR"

# ============================================================
# Tuning flags
# ============================================================
# Su ARM64 (Apple Silicon) non esiste -march=x86-64-v2.
# Su x86_64 macOS manteniamo la stessa baseline del build Linux.
# -flto=auto: parallelizza la fase LTRANS usando tutti i core disponibili.
# Nota: macOS ld (ld64) non supporta -Wl,-Bsymbolic-functions né
#   --start-group/--end-group. Questi flag vengono omessi.
if [ "$ARCH" = "x86_64" ]; then
  ARCH_FLAGS="-march=x86-64-v2"
else
  ARCH_FLAGS=""
fi
OPT_FLAGS="-O3 -fPIC $ARCH_FLAGS"
LTO_FLAG="-flto=auto"

# ============================================================
# 0. Prerequisiti (macOS + Homebrew)
# ============================================================
brew update
brew install gcc pkg-config wget git cmake swig maven unzip zip python3 openjdk@11

# GCC da Homebrew (per PGO e LTO nel build SCIP — stessi flag del build Linux)
# NON esportiamo CC/CXX/FC globalmente: le dipendenze (GMP, Boost, ecc.)
# vanno compilate con il compiler di default (clang) che su macOS ARM64
# funziona meglio. GCC serve solo per SCIP (PGO, LTO, Fortran).
GCC_MAJOR=$(brew list --versions gcc | awk '{print $2}' | cut -d. -f1)
BREW_PREFIX="$(brew --prefix)"
GCC_CC="$BREW_PREFIX/bin/gcc-$GCC_MAJOR"
GCC_CXX="$BREW_PREFIX/bin/g++-$GCC_MAJOR"
GCC_FC="$BREW_PREFIX/bin/gfortran-$GCC_MAJOR"

echo ">>> GCC per SCIP: $GCC_CC (GCC $GCC_MAJOR)"

# JAVA_HOME
export JAVA_HOME="$(/usr/libexec/java_home -v 11 2>/dev/null || brew --prefix openjdk@11)"
export PATH="$JAVA_HOME/bin:$PATH"
java --version


# ============================================================
# 1-2. Dipendenze (skip se cachate)
#      NON serve PGO sulle dipendenze: il tempo di solve è
#      dominato da SCIP/SoPlex, non da OpenBLAS/Mumps/Ipopt.
# ============================================================
if [ "${DEPS_CACHED:-}" != "true" ]; then

# Carica versioni dipendenze specifiche per questa versione SCIP
DEPS_FILE="$WORK/.github/workflows/scripts/deps-versions-${SCIPOPTSUITE_VERSION}.env"
if [ ! -f "$DEPS_FILE" ]; then
  echo "Errore: File dipendenze $DEPS_FILE non trovato"
  exit 1
fi
source "$DEPS_FILE"

cd "$WORK"
mkdir -p staticdepsinstall && cd staticdepsinstall

# -----------------------------------------------------------
# GMP
#   - GMP for rational arithmetic in SoPlex, SCIP
# -----------------------------------------------------------
echo ">>> GMP ${GMP_VERSION}"
curl -sLO "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VERSION}.tar.xz"
tar xf "gmp-${GMP_VERSION}.tar.xz" && cd "gmp-${GMP_VERSION}"
CFLAGS="$OPT_FLAGS" CPPFLAGS="-DPIC" ./configure --prefix="$PREFIX" --with-pic --disable-shared > /dev/null 2>&1
make -s -j"$CORES" > /dev/null 2>&1 && make -s install > /dev/null 2>&1 && cd ..
echo "    OK: $(ls -lh "$PREFIX/lib/libgmp.a" | awk '{print $5}')"

# -----------------------------------------------------------
# Boost
#   - Boost multiprecision library for rationals in SCIP/SoPlex
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
# Su macOS compiliamo dal sorgente GCC come su Linux per avere
# .a pulite e controllate. Brew fornisce .dylib ma non .a utilizzabili.
# -----------------------------------------------------------
echo ">>> libgfortran.a + libquadmath.a (GCC ${GCC_VERSION})"
FORTRAN_BUILD="$WORK/staticdepsinstall/gcc-fortran-pic"
mkdir -p "$FORTRAN_BUILD" && cd "$FORTRAN_BUILD"
wget -q "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz"
tar xf "gcc-${GCC_VERSION}.tar.xz"
cd "gcc-${GCC_VERSION}"
./contrib/download_prerequisites > /dev/null 2>&1

mkdir -p "$FORTRAN_BUILD/build" && cd "$FORTRAN_BUILD/build"

# Su macOS usiamo il GCC di brew come host compiler per il bootstrap
"$FORTRAN_BUILD/gcc-${GCC_VERSION}/configure" \
  --prefix="$PREFIX" \
  --enable-languages=c,fortran \
  --disable-bootstrap --disable-multilib --disable-shared --enable-static --with-pic \
  --disable-libsanitizer --disable-libgomp --disable-libvtv --disable-libatomic \
  --disable-libstdcxx --disable-libssp --disable-libcc1 --disable-libitm \
  --with-gmp="$(brew --prefix gmp)" \
  --with-mpfr="$(brew --prefix mpfr)" \
  --with-mpc="$(brew --prefix libmpc)" \
  --with-isl="$(brew --prefix isl)" \
  --with-system-zlib > /dev/null 2>&1

make -s -j"$CORES" all-gcc                > /dev/null 2>&1
make -s -j"$CORES" all-target-libquadmath > /dev/null 2>&1
make -s -j"$CORES" all-target-libgfortran > /dev/null 2>&1
make -s install-target-libquadmath        > /dev/null 2>&1
make -s install-target-libgfortran        > /dev/null 2>&1
# Rimuovi eventuali .dylib — vogliamo solo le .a
find "$PREFIX" -name '*.dylib' -path '*/libgfortran*' -delete 2>/dev/null || true
find "$PREFIX" -name '*.dylib' -path '*/libquadmath*' -delete 2>/dev/null || true

# Copia le .a in $PREFIX/lib per uniformità (GCC le installa in lib/gcc/...)
find "$PREFIX" -name 'libgfortran.a' -exec cp {} "$PREFIX/lib/" \;
find "$PREFIX" -name 'libquadmath.a' -exec cp {} "$PREFIX/lib/" \;

for LIB in libgfortran.a libquadmath.a; do
  P=$(find "$PREFIX/lib" -name "$LIB" -print -quit)
  echo "    $LIB $(ls -lh "$P" | awk '{print $5}')"
done

cd "$WORK/staticdepsinstall"

# -----------------------------------------------------------
# OpenBLAS — BLAS + LAPACK + LAPACKE ottimizzati
# -----------------------------------------------------------
echo ">>> OpenBLAS ${OPENBLAS_VERSION}"
wget -q "https://github.com/OpenMathLib/OpenBLAS/releases/download/v${OPENBLAS_VERSION}/OpenBLAS-${OPENBLAS_VERSION}.zip"
unzip -q "OpenBLAS-${OPENBLAS_VERSION}.zip" && mv "OpenBLAS-${OPENBLAS_VERSION}" OpenBLAS && cd OpenBLAS
# OpenBLAS gestisce i propri CFLAGS internamente per i kernel ottimizzati
unset CFLAGS CXXFLAGS LDFLAGS LIBRARY_PATH LD_LIBRARY_PATH CPATH PKG_CONFIG_PATH 2>/dev/null || true
# Su ARM64 macOS DYNAMIC_ARCH non serve (un solo tipo di CPU Apple Silicon)
# Su x86_64 macOS lo attiviamo come su Linux
if [ "$ARCH" = "x86_64" ]; then
  make -s -j"$CORES" NO_SHARED=1 DYNAMIC_ARCH=1 USE_OPENMP=0 CC="$GCC_CC" FC="$GCC_FC" > /dev/null 2>&1
else
  make -s -j"$CORES" NO_SHARED=1 USE_OPENMP=0 CC="$GCC_CC" FC="$GCC_FC" > /dev/null 2>&1
fi
make -s PREFIX="$PREFIX" NO_SHARED=1 install > /dev/null 2>&1
cd ..

# Se il file non si chiama esattamente libopenblas.a, crea symlink
if [ ! -f "$PREFIX/lib/libopenblas.a" ]; then
  OB_LIB=$(find "$PREFIX" -name 'libopenblas*.a' -print -quit)
  if [ -n "$OB_LIB" ]; then
    ln -sf "$OB_LIB" "$PREFIX/lib/libopenblas.a"
  else
    echo "ERRORE: nessuna libopenblas*.a!" && exit 1
  fi
fi
echo "    OK: $(ls -lh "$PREFIX/lib/libopenblas.a" | awk '{print $5}')"


# Flag BLAS/LAPACK condivisi per Mumps e Ipopt
BLAS_LAPACK_LFLAGS="-L$PREFIX/lib -lopenblas -lgfortran -lquadmath -lm"

# -----------------------------------------------------------
# METIS 5 — ordering per Mumps (migliora performance fattorizzazione)
# GKlib è prerequisito di METIS 5
# -----------------------------------------------------------
echo ">>> GKlib + METIS"
cd "$WORK/staticdepsinstall"

wget -q "https://github.com/KarypisLab/GKlib/archive/refs/tags/METIS-v5.1.1-DistDGL-0.5.tar.gz"
tar xf "METIS-v5.1.1-DistDGL-0.5.tar.gz"
cd "GKlib-METIS-v5.1.1-DistDGL-0.5"
# macOS sed: -i '' (BSD)
sed -i '' 's/^CONFIG_FLAGS =/CONFIG_FLAGS = -DCMAKE_POLICY_VERSION_MINIMUM=3.5/' Makefile
make config prefix="$PREFIX" cc=cc "CFLAGS=$OPT_FLAGS" > /dev/null 2>&1
make -j"$CORES" > /dev/null 2>&1 && make install > /dev/null 2>&1
cd ..

wget -q "https://github.com/KarypisLab/METIS/archive/refs/tags/v5.1.1-DistDGL-v0.5.tar.gz"
tar xf "v5.1.1-DistDGL-v0.5.tar.gz"
cd "METIS-5.1.1-DistDGL-v0.5"
sed -i '' 's/^CONFIG_FLAGS =/CONFIG_FLAGS = -DCMAKE_POLICY_VERSION_MINIMUM=3.5/' Makefile
make config prefix="$PREFIX" gklib_path="$WORK/staticdepsinstall/GKlib-METIS-v5.1.1-DistDGL-0.5" cc=cc "CFLAGS=$OPT_FLAGS" > /dev/null 2>&1
make -j"$CORES" > /dev/null 2>&1 && make install > /dev/null 2>&1
cd ..
echo "    OK: $(ls -lh "$PREFIX/lib/libmetis.a" | awk '{print $5}')"

# -----------------------------------------------------------
# ThirdParty-Mumps (build diretta, con METIS)
# -----------------------------------------------------------
echo ">>> ThirdParty-Mumps"
cd "$WORK/staticdepsinstall"
git clone -q https://github.com/coin-or-tools/ThirdParty-Mumps.git
cd ThirdParty-Mumps
./get.Mumps > /dev/null 2>&1
./configure \
  --prefix="$PREFIX" --enable-shared=no --enable-static=yes --with-pic \
  CC=cc CXX=c++ FC="$GCC_FC" \
  CFLAGS="$OPT_FLAGS" FCFLAGS="$OPT_FLAGS" CXXFLAGS="$OPT_FLAGS" \
  --with-metis-cflags="-I$PREFIX/include" \
  --with-metis-lflags="-L$PREFIX/lib -lmetis -lm" \
  --with-lapack-lflags="$BLAS_LAPACK_LFLAGS" > /dev/null 2>&1
make -j"$CORES" > /dev/null 2>&1 && make install > /dev/null 2>&1
cd ..
echo "    OK: $(ls -lh "$PREFIX/lib/libcoinmumps.a" | awk '{print $5}')"

# -----------------------------------------------------------
# Ipopt (build diretta, senza coinbrew)
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
  CC=cc CXX=c++ FC="$GCC_FC" \
  CFLAGS="$OPT_FLAGS" CXXFLAGS="$OPT_FLAGS" FFLAGS="$OPT_FLAGS" \
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
  --with-lapack-lflags="$BLAS_LAPACK_LFLAGS" > /dev/null 2>&1

make -j"$CORES" > /dev/null 2>&1 && make install > /dev/null 2>&1
cd ../..
echo "    OK: $(ls -lh "$PREFIX/lib/libipopt.a" | awk '{print $5}')"

echo ">>> Dipendenze completate."
fi


# ============================================================
# Funzione helper: configura e compila SCIP con flag custom
# $1 = flag extra per C compiler
# $2 = flag extra per CXX compiler
# $3 = flag extra per shared linker
# $4 = flag extra per exe linker
# $5 = etichetta per il log
# ============================================================
build_scip() {
  local EXTRA_C_FLAGS="$1"
  local EXTRA_CXX_FLAGS="$2"
  local EXTRA_SHARED_LINKER_FLAGS="$3"
  local EXTRA_EXE_LINKER_FLAGS="$4"
  local LABEL="$5"

  echo ""
  echo "============================================================"
  echo ">>> Build SCIP — $LABEL"
  echo "============================================================"

  cd "$WORK/scipoptsuite"
  rm -rf build && mkdir -p build && cd build

  LIBGFORTRAN_A=$(find "$PREFIX" -name 'libgfortran.a' -print -quit)
  LIBQUADMATH_A=$(find "$PREFIX" -name 'libquadmath.a' -print -quit)

  # NOTA IMPORTANTE da CMakeLists.txt riga 914:
  #   if(IPOPT_FOUND) → set(LAPACK off)
  # Quando IPOPT è trovato, SCIP forza internamente LAPACK=off.

  # LTO notes:
  #   -DLTO=on abilita -flto su SCIP/SoPlex → ottimizzazione cross-modulo al link-time.
  #   macOS ld64 non supporta -Bsymbolic-functions; l'ottimizzazione cross-modulo
  #   è comunque efficace grazie a -flto=auto + -O3 nei linker flags.

  # macOS ld64 non supporta --start-group / --end-group — elenchiamo le librerie
  # nell'ordine corretto (e ripetiamo se necessario per risolvere dipendenze circolari).
  # macOS ld64 non supporta -Bsymbolic-functions — viene omesso.

  cmake .. \
    -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$WORK/scip_shared" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_C_COMPILER="$GCC_CC" \
    -DCMAKE_CXX_COMPILER="$GCC_CXX" \
    -DCMAKE_Fortran_COMPILER="$GCC_FC" \
    -DCMAKE_C_FLAGS="$OPT_FLAGS $EXTRA_C_FLAGS" \
    -DCMAKE_CXX_FLAGS="$OPT_FLAGS -DCPPAD_MAX_NUM_THREADS=1024 $EXTRA_CXX_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="-O3 $LTO_FLAG $ARCH_FLAGS -L$PREFIX/lib -lipopt -lcoinmumps -lmetis -lopenblas -lgfortran -lquadmath -lm -lpthread $EXTRA_EXE_LINKER_FLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="-O3 $LTO_FLAG $ARCH_FLAGS -L$PREFIX/lib -lmetis -lopenblas -lgfortran -lquadmath -lm $EXTRA_SHARED_LINKER_FLAGS" \
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

  make -s -j"$CORES" libscip soplex
  echo ">>> Build SCIP — $LABEL completata."
}


# ============================================================
# 3. Estrai sorgenti SCIP (una volta, riusati da entrambe le pass)
# ============================================================
cd "$WORK"
tar -xzf "resources/scipoptsuite-${SCIPOPTSUITE_VERSION}.tgz"
mv "scipoptsuite-${SCIPOPTSUITE_VERSION}" scipoptsuite

# Estrai problemi per PGO training
cd "$WORK"
unzip -qo resources/PROBS.zip -d "$WORK/pgo_problems"
CIP_FILES=("$WORK/pgo_problems"/*.cip)
if [ ${#CIP_FILES[@]} -eq 0 ]; then
  echo "Errore: nessun file .cip trovato in PROBS.zip"
  exit 1
fi
echo ">>> PGO: ${#CIP_FILES[@]} problemi .cip per training"


# ============================================================
# 3a. PASS 1 — Build SCIP instrumentato per PGO
# ============================================================
build_scip \
  "-fprofile-generate=$PGO_DIR" \
  "-fprofile-generate=$PGO_DIR" \
  "-fprofile-generate=$PGO_DIR" \
  "-fprofile-generate=$PGO_DIR" \
  "PASS 1/2 — PGO instrument"


# ============================================================
# 3b. PGO TRAINING — compila smoke test, risolvi i .cip
# ============================================================
echo ""
echo "============================================================"
echo ">>> PGO TRAINING — ${#CIP_FILES[@]} problemi"
echo "============================================================"

# Serve make install per avere gli header in scip_shared/include
cd "$WORK/scipoptsuite/build"
make -s install > /dev/null 2>&1

"$GCC_CC" -O2 -o "$WORK/smoke_test_scip" \
    "$WORK/resources/smoke_test_scip.c" \
    -I"$WORK/scip_shared/include" \
    -L"$WORK/scipoptsuite/build/lib" \
    -lscip \
    -lm -lpthread
echo ">>> Smoke test compilato"

# Esegui — ogni solve produce profili in $PGO_DIR
# Su macOS usiamo DYLD_LIBRARY_PATH invece di LD_LIBRARY_PATH
DYLD_LIBRARY_PATH="$WORK/scipoptsuite/build/lib" \
  "$WORK/smoke_test_scip" "${CIP_FILES[@]}" || true

# Verifica profili generati
GCDA_COUNT=$(find "$PGO_DIR" -name '*.gcda' 2>/dev/null | wc -l)
echo ""
echo ">>> Profili PGO: $GCDA_COUNT file .gcda"

if [ "$GCDA_COUNT" -eq 0 ]; then
  echo "ATTENZIONE: nessun profilo PGO generato — fallback a build senza PGO"
  PGO_USE_FLAGS=""
else
  echo ">>> OK: profili pronti per Pass 2"
  PGO_USE_FLAGS="-fprofile-use=$PGO_DIR -fprofile-correction"
fi


# ============================================================
# 3c. PASS 2 — Rebuild SCIP ottimizzato con profili PGO
# ============================================================
build_scip \
  "$PGO_USE_FLAGS" \
  "$PGO_USE_FLAGS" \
  "$PGO_USE_FLAGS" \
  "$PGO_USE_FLAGS" \
  "PASS 2/2 — PGO optimize"


# ============================================================
# Verifiche post-build
# ============================================================
echo ""
echo ">>> Contenuto build/lib/:"
ls -la "$WORK/scipoptsuite/build/lib/"

# Trova la dylib di SCIP (potrebbe essere libscip.9.2.2.0.dylib, libscip.9.2.dylib, o libscip.dylib)
SCIP_DYLIB_BUILD=$(find "$WORK/scipoptsuite/build/lib" -maxdepth 1 -name 'libscip*.dylib' -not -name 'libscipopt*' | head -1)
if [ -z "$SCIP_DYLIB_BUILD" ]; then
  echo "ERRORE: nessuna libscip*.dylib trovata in build/lib/"
  exit 1
fi
echo ">>> Trovata: $SCIP_DYLIB_BUILD"

echo ">>> Verifica dipendenze dinamiche:"
# Su macOS usiamo otool -L al posto di ldd
if otool -L "$SCIP_DYLIB_BUILD" | grep -qE 'libgfortran|libquadmath'; then
  echo "ERRORE: dipendenze Fortran dinamiche ancora presenti!"
  otool -L "$SCIP_DYLIB_BUILD" | grep -E 'gfortran|quadmath'
  exit 1
else
  echo "OK: libgfortran/libquadmath linkate staticamente"
fi

# LTO: su macOS non abbiamo readelf, usiamo nm per una verifica indiretta
echo ">>> Verifica LTO (nm):"
LTO_SYMS=$(nm -g "$SCIP_DYLIB_BUILD" 2>/dev/null | grep -c '__gnu_lto' || true)
if [ "$LTO_SYMS" -gt 0 ]; then
  echo "ATTENZIONE: $LTO_SYMS simboli __gnu_lto residui — LTO potrebbe non aver processato tutti i moduli"
else
  echo "OK: nessun simbolo __gnu_lto residuo"
fi


# ============================================================
# 4. Compila JSCIPOpt (versione modificata con package it.prometeia.jscip)
# ============================================================
cd "$WORK"
unzip -q resources/JSCIPOpt-${SCIPOPTSUITE_VERSION}.zip
cd JSCIPOpt
rm -f src/*cxx src/*h 2>/dev/null || true
rm -rf build && mkdir build && cd build
cmake .. -DSCIP_DIR="$SCIP_BUILD" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DJAVA_AWT_LIBRARY=NotNeeded \
  -DCMAKE_C_COMPILER="$GCC_CC" \
  -DCMAKE_CXX_COMPILER="$GCC_CXX" \
  -DCMAKE_C_FLAGS="$OPT_FLAGS" \
  -DCMAKE_CXX_FLAGS="$OPT_FLAGS"
make -s

# ============================================================
# 5. Genera output
# ============================================================
cd "$WORK"
rm -rf "$OUT"/*

cp "$WORK/JSCIPOpt/build/Release/scip.jar" "$OUT/"
cp -L "$WORK/JSCIPOpt/build/Release/libjscip.dylib" "$OUT/"

# Copia libscip — il nome esatto dipende dalla versione CMake (può essere
# libscip.9.2.2.0.dylib, libscip.9.2.dylib, o libscip.dylib).
# SCIP_DYLIB_BUILD è già stato trovato nella sezione verifiche.
cp -L "$SCIP_DYLIB_BUILD" "$OUT/libscip.${SCIP_MAJOR_MINOR}.dylib"
echo ">>> Copiata $SCIP_DYLIB_BUILD → $OUT/libscip.${SCIP_MAJOR_MINOR}.dylib"
echo ">>> Contenuto out/:"
ls -la "$OUT/"

# Strip — rimuove simboli non necessari
# macOS strip: -x rimuove simboli locali (equivalente di --strip-unneeded)
cd "$OUT"
for f in *.dylib; do
  SIZE_BEFORE=$(stat -f%z "$f")
  strip -x "$f" 2>/dev/null || true
  SIZE_AFTER=$(stat -f%z "$f")
  echo "Strip: $f  $SIZE_BEFORE → $SIZE_AFTER  (-$(( (SIZE_BEFORE - SIZE_AFTER) * 100 / SIZE_BEFORE ))%)"
done

# Fix rpath — @loader_path permette di caricare le dipendenze dalla stessa cartella
# (equivalente di $ORIGIN su Linux con patchelf)
for f in *.dylib; do
  # Rimuovi tutti gli rpath esistenti (ignora errori se non ce ne sono)
  for rp in $(otool -l "$f" 2>/dev/null | grep -A1 'cmd LC_RPATH' | grep 'path ' | awk '{print $2}'); do
    install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true
  done
  # Aggiungi @loader_path come unico rpath
  install_name_tool -add_rpath @loader_path "$f" 2>/dev/null || true
done

# Fix riferimenti interni tra le dylib
# libjscip.dylib deve puntare a libscip.X.Y.dylib nella stessa cartella
SCIP_DYLIB_REF=$(otool -L "$OUT/libjscip.dylib" | grep 'libscip' | head -1 | awk '{print $1}')
if [ -n "$SCIP_DYLIB_REF" ]; then
  install_name_tool -change "$SCIP_DYLIB_REF" "@loader_path/libscip.${SCIP_MAJOR_MINOR}.dylib" "$OUT/libjscip.dylib"
fi

cd "$WORK"
zip -r out.zip out/

mkdir -p test_package
cp -r out test_package/
cp resources/ipeoptimtest.zip test_package/
zip -r test_package.zip test_package/
rm -rf test_package

# Cleanup
rm -rf "$PGO_DIR" "$WORK/pgo_problems" "$WORK/smoke_test_scip"

echo "Build macOS completata (LTO + PGO)."