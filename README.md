# scip-native-jni

Build nativo di SCIP + JSCIPOpt per macOS (arm64) e Linux (x86_64).

## Aggiungere una nuova versione SCIP

1. Aggiungi `resources/scipoptsuite-X.Y.Z.tgz` e `resources/JSCIPOpt-X.Y.Z.zip`
2. Crea `.github/workflows/scripts/deps-versions-X.Y.Z.env` con le versioni dipendenze
3. Aggiungi `"X.Y.Z"` alle options in `.github/workflows/build.yml`

## Scelte di build (Linux)

### Dipendenze compilate da zero

**GCC (libgfortran/libquadmath)**: Le versioni di sistema non sono compilate con `-fPIC`, necessario per linkare in librerie shared. Ricompiliamo solo le target libraries Fortran con `--with-pic`.

**OpenBLAS**: Buildiamo con `DYNAMIC_ARCH=1` per supportare tutte le CPU x86_64 (runtime dispatch). I pacchetti precompilati sono ottimizzati per architetture "moderne" e non sempre compatibili.

### Strategia di linking

Dipendenze statiche (`.a` con `-fPIC`) linkate in `libscip.so` shared. Questo permette:
- Distribuzione semplificata (una sola `.so` + JNI wrapper)
- Nessun conflitto con altre versioni di BLAS/LAPACK nel sistema
- Ottimizzazioni LTO cross-modulo

Le uniche dipendenze che rimangno sono:
TODO!

### Ipopt: MUMPS + METIS

- **MUMPS**: Solver lineare sparso open-source, robusto e senza restrizioni di licenza
- **METIS**: Ordering per ridurre fill-in nella fattorizzazione (migliora performance)
- **No HSL/Pardiso**: Richiedono licenze commerciali o registrazione
- **No SPRAL/Pardiso MKL**: Da paper sono migliori per problemi grandi e sparis, per il nostro use case benissimo MUMP (HSL27 forse migliore ma non open per uso commerciale)

### Componenti SCIP disabilitati

- **GCG/UG**: Decomposizione Dantzig-Wolfe e parallelizzazione distribuita — non necessari per uso JNI single-process
- **PaPILO**: Presolve parallelo per i nostri problemi MIP non dovrebbe servire, boost dato da parallelismo e non da algoritmi, i nostri problemi son "piccoli"e giriamo in ambienti single thread
- **TBB**: Threading Building Blocks — evitiamo dipendenze di appesantire. il parallelismo dato da scip nel BB è tutto ciò che ci serve. Inoltre i nostri problemi sono piccoli e non beneficiano di overhead di TBB
- **ZIMPL**: Linguaggio di modellazione — non usato via API Java
- **MPFR** per risoluzione esatta con SoPlex, noi non la utilizziamo

