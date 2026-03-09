# scip-native-jni

Build nativo di SCIP + JSCIPOpt per macOS (arm64) e Linux (x86_64).

## Aggiungere una nuova versione SCIP

1. Aggiungi `resources/JSCIPOpt-X.Y.Z.zip`
2. Crea `.github/workflows/scripts/deps-versions-X.Y.Z.env` con le versioni dipendenze
3. Aggiungi `"X.Y.Z"` alle options in `.github/workflows/build.yml`
