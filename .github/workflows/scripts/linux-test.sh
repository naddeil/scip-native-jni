#!/usr/bin/env bash
set -euo pipefail

# Test in container AL2023 pulito — verifica che out/ sia autocontenuto
WORK="$GITHUB_WORKSPACE"
OUT="$WORK/out"
SCIP_MAJOR_MINOR=$(echo "$SCIPOPTSUITE_VERSION" | cut -d. -f1-2)

dnf install -y --allowerasing \
  java-11-amazon-corretto-devel maven.noarch \
  python3 unzip which

export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which javac))))

java --version

# ============================================================
# 1. Checker — carica le .so da out/ senza dipendenze di build
# ============================================================
echo "=== Checker: verifica caricamento librerie ==="
cd "$WORK"

LD_LIBRARY_PATH="$OUT" python3 -c "
import ctypes, sys, os
os.environ['LD_LIBRARY_PATH'] = '$OUT'
for lib in ['$OUT/libscip.so.${SCIP_MAJOR_MINOR}', '$OUT/libjscip.so']:
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
