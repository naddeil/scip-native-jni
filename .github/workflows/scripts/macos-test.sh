#!/usr/bin/env bash
set -euo pipefail

# Test su runner macOS pulito — verifica che out/ sia autocontenuto
WORK="$GITHUB_WORKSPACE"
OUT="$WORK/out"
SCIP_MAJOR_MINOR=$(echo "$SCIPOPTSUITE_VERSION" | cut -d. -f1-2)
SCIP_DYLIB="libscip.${SCIP_MAJOR_MINOR}.dylib"

# ============================================================
# 1. Checker — carica le dylib da out/ senza dipendenze di build
# ============================================================
echo "=== Checker: verifica dipendenze ==="
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
echo "Checker OK."

# ============================================================
# 2. Test Java
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
