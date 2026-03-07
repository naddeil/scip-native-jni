#!/usr/bin/env bash
# ===========================================================================
#  build-fortran-static-pic.sh
#  Compila libgfortran.a e libquadmath.a statiche con -fPIC dai sorgenti GCC.
#
#  Uso:
#    ./build-fortran-static-pic.sh [GCC_VERSION] [PREFIX]
#
#  Esempio:
#    ./build-fortran-static-pic.sh 13.2.0 /opt/fortran-pic
#
#  Variabili d'ambiente opzionali:
#    GCC_VERSION  – versione GCC (default: 13.2.0)
#    PREFIX       – directory di installazione (default: /opt/fortran-pic)
#    JOBS         – parallelismo make (default: nproc)
#    WORKDIR      – directory di lavoro temporanea (default: /tmp/gcc-build)
# ===========================================================================
set -euo pipefail

# ── Parametri ──────────────────────────────────────────────────────────────
GCC_VERSION="${1:-${GCC_VERSION:-13.2.0}}"
PREFIX="${2:-${PREFIX:-/opt/fortran-pic}}"
JOBS="${JOBS:-$(nproc)}"
WORKDIR="${WORKDIR:-/tmp/gcc-build}"

GCC_MAJOR="${GCC_VERSION%%.*}"
GCC_TARBALL="gcc-${GCC_VERSION}.tar.xz"
GCC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/${GCC_TARBALL}"
GCC_SRC="${WORKDIR}/gcc-${GCC_VERSION}"

ARCH="$(uname -m)"

# ── Colori (se tty) ───────────────────────────────────────────────────────
if [ -t 1 ]; then
  BOLD='\033[1m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; RESET='\033[0m'
else
  BOLD=''; GREEN=''; CYAN=''; RESET=''
fi

info()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
step()  { echo -e "${CYAN}${BOLD}══► $*${RESET}"; }

# ── Dipendenze di sistema ────────────────────────────────────────────────
install_deps() {
  step "Controllo dipendenze di build"
  if command -v apt-get &>/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
      build-essential wget xz-utils \
      libgmp-dev libmpfr-dev libmpc-dev flex
  elif command -v yum &>/dev/null; then
    sudo yum install -y gcc gcc-c++ make wget xz \
      gmp-devel mpfr-devel libmpc-devel flex
  elif command -v dnf &>/dev/null; then
    sudo dnf install -y gcc gcc-c++ make wget xz \
      gmp-devel mpfr-devel libmpc-devel flex
  else
    info "Package manager non riconosciuto – assicurati di avere gcc, make, gmp, mpfr, mpc"
  fi
}

# ── Download & estrazione sorgenti ───────────────────────────────────────
download_gcc() {
  step "Download GCC ${GCC_VERSION}"
  mkdir -p "${WORKDIR}"
  cd "${WORKDIR}"

  if [ ! -f "${GCC_TARBALL}" ]; then
    wget -q --show-progress "${GCC_URL}"
  else
    info "Tarball già presente, skip download"
  fi

  if [ ! -d "${GCC_SRC}" ]; then
    info "Estrazione..."
    tar xf "${GCC_TARBALL}"
  else
    info "Sorgenti già estratti"
  fi
}

# ── Build host GCC minimale (solo C + Fortran) se necessario ─────────────
#    Serve un gfortran funzionante per compilare libgfortran.
ensure_gfortran() {
  if command -v gfortran &>/dev/null; then
    info "gfortran trovato: $(gfortran --version | head -1)"
    return 0
  fi

  step "gfortran non trovato – build minimale del compilatore"
  local build_dir="${GCC_SRC}/build-compiler"
  mkdir -p "${build_dir}"
  cd "${build_dir}"

  ../configure \
    --prefix="${PREFIX}/bootstrap" \
    --enable-languages=c,fortran \
    --disable-multilib \
    --disable-bootstrap \
    --disable-libsanitizer \
    --disable-libgomp \
    --disable-libvtv \
    --with-pic

  make -j"${JOBS}"
  make install

  export PATH="${PREFIX}/bootstrap/bin:${PATH}"
  export LD_LIBRARY_PATH="${PREFIX}/bootstrap/lib64:${LD_LIBRARY_PATH:-}"
  info "Bootstrap gfortran installato in ${PREFIX}/bootstrap"
}

# ── Configurazione host triplet ──────────────────────────────────────────
detect_host() {
  case "${ARCH}" in
    x86_64)  HOST_TRIPLET="x86_64-linux-gnu" ;;
    aarch64) HOST_TRIPLET="aarch64-linux-gnu" ;;
    *)       HOST_TRIPLET="${ARCH}-linux-gnu"  ;;
  esac
  info "Host triplet: ${HOST_TRIPLET}"
}

# ── Common flags ─────────────────────────────────────────────────────────
PIC_CFLAGS="-fPIC -O2"
PIC_FCFLAGS="-fPIC -O2"

# ── Build libquadmath ────────────────────────────────────────────────────
build_libquadmath() {
  step "Build libquadmath (static + PIC)"
  local build_dir="${GCC_SRC}/libquadmath/build-pic"
  rm -rf "${build_dir}"
  mkdir -p "${build_dir}"
  cd "${build_dir}"

  CFLAGS="${PIC_CFLAGS}" \
  FCFLAGS="${PIC_FCFLAGS}" \
  CXXFLAGS="${PIC_CFLAGS}" \
  ../configure \
    --host="${HOST_TRIPLET}" \
    --prefix="${PREFIX}" \
    --disable-shared \
    --enable-static

  make -j"${JOBS}"
  make install

  info "libquadmath.a installata in ${PREFIX}/lib"
}

# ── Build libgfortran ────────────────────────────────────────────────────
build_libgfortran() {
  step "Build libgfortran (static + PIC)"
  local build_dir="${GCC_SRC}/libgfortran/build-pic"
  rm -rf "${build_dir}"
  mkdir -p "${build_dir}"
  cd "${build_dir}"

  CFLAGS="${PIC_CFLAGS}" \
  FCFLAGS="${PIC_FCFLAGS}" \
  CXXFLAGS="${PIC_CFLAGS}" \
  LDFLAGS="-L${PREFIX}/lib" \
  ../configure \
    --host="${HOST_TRIPLET}" \
    --prefix="${PREFIX}" \
    --disable-shared \
    --enable-static \
    --with-libquadmath-support

  make -j"${JOBS}"
  make install

  info "libgfortran.a installata in ${PREFIX}/lib"
}

# ── Verifica PIC ─────────────────────────────────────────────────────────
verify_pic() {
  step "Verifica PIC"
  local fail=0

  for lib in libquadmath.a libgfortran.a; do
    local path="${PREFIX}/lib/${lib}"
    if [ ! -f "${path}" ]; then
      echo "  ✗ ${lib} non trovata in ${PREFIX}/lib"
      fail=1
      continue
    fi

    # Conta rilocazioni assolute 32-bit (non-PIC)
    local abs32
    abs32=$(objdump -r "${path}" 2>/dev/null | grep -c 'R_X86_64_32\b' || true)

    if [ "${abs32}" -eq 0 ]; then
      echo "  ✓ ${lib} – PIC OK (0 rilocazioni R_X86_64_32)"
    else
      echo "  ⚠ ${lib} – ${abs32} rilocazioni R_X86_64_32 trovate (potrebbe non essere full-PIC)"
    fi

    # Size
    local size
    size=$(du -h "${path}" | cut -f1)
    echo "    dimensione: ${size}"
  done

  return ${fail}
}

# ── Riepilogo ────────────────────────────────────────────────────────────
summary() {
  step "Riepilogo"
  echo ""
  echo "  GCC version:    ${GCC_VERSION}"
  echo "  Architettura:   ${ARCH}"
  echo "  Prefix:         ${PREFIX}"
  echo "  Librerie:       ${PREFIX}/lib/libgfortran.a"
  echo "                  ${PREFIX}/lib/libquadmath.a"
  echo ""
  echo "  Uso nel tuo progetto:"
  echo "    gfortran -shared -o libmia.so codice.o \\"
  echo "      -L${PREFIX}/lib \\"
  echo "      -Wl,-Bstatic -lgfortran -lquadmath \\"
  echo "      -Wl,-Bdynamic -lm -lpthread"
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────
main() {
  step "Build libgfortran + libquadmath static-PIC (GCC ${GCC_VERSION})"
  echo "  prefix=${PREFIX}  jobs=${JOBS}  arch=${ARCH}"
  echo ""

  install_deps
  download_gcc
  detect_host
  ensure_gfortran
  build_libquadmath
  build_libgfortran
  verify_pic
  summary

  step "Done!"
}

main "$@"
