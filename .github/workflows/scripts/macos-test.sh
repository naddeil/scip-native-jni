#!/usr/bin/env bash
set -euo pipefail

# Test su macOS pulito — verifica che out/ sia autocontenuto
WORK="$GITHUB_WORKSPACE"
OUT="$WORK/out"
SCIP_MAJOR_MINOR=$(echo "$SCIPOPTSUITE_VERSION" | cut -d. -f1-2)

brew install openjdk@11 maven python3 unzip
export JAVA_HOME="$(/usr/libexec/java_home -v 11 2>/dev/null || brew --prefix openjdk@11)"
export PATH="$JAVA_HOME/bin:$PATH"

java --version

# ============================================================
# 1. Checker — carica le .dylib da out/ senza dipendenze di build
# ============================================================
echo "=== Checker: verifica caricamento librerie ==="
cd "$WORK"

DYLD_LIBRARY_PATH="$OUT" python3 -c "
import ctypes, sys, os
os.environ['DYLD_LIBRARY_PATH'] = '$OUT'
for lib in ['$OUT/libscip.${SCIP_MAJOR_MINOR}.dylib', '$OUT/libjscip.dylib']:
    print(f'Carico {lib}...')
    try:
        ctypes.CDLL(lib)
        print('OK')
    except OSError as e:
        print(f'ERRORE: {e}')
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