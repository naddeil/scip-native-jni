/**
 * smoke_test_scip.c — Smoke test per libscip.so
 *
 * Compila:
 *   gcc -O2 -o smoke_test_scip smoke_test_scip.c \
 *       -I$WORK/scip_shared/include -L$OUT -lscip -Wl,-rpath,'$ORIGIN'
 *
 * Uso:
 *   ./smoke_test_scip problem1.cip [problem2.cip ...]
 *
 * Per ogni file .cip:
 *   1. Crea un'istanza SCIP
 *   2. Carica tutti i plugin di default (include SoPlex, presolvers, heuristics)
 *   3. Legge il .cip
 *   4. Risolve (con time limit)
 *   5. Verifica che lo status sia OPTIMAL o almeno FEASIBLE
 *   6. Stampa obiettivo e statistiche base
 *   7. Libera la memoria
 *
 * Exit code:
 *   0 = tutti i problemi risolti con successo
 *   1 = almeno un problema fallito
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "scip/scip.h"
#include "scip/scipdefplugins.h"

/* Time limit per singolo problema (secondi) */
#define TIME_LIMIT 120.0

static int solve_one(const char* filename)
{
    SCIP* scip = NULL;
    SCIP_RETCODE rc;
    int success = 0;

    printf("\n========================================\n");
    printf("File: %s\n", filename);
    printf("========================================\n");

    /* Crea istanza */
    rc = SCIPcreate(&scip);
    if (rc != SCIP_OKAY) {
        fprintf(stderr, "ERRORE: SCIPcreate fallito (rc=%d)\n", rc);
        return 0;
    }

    /* Carica plugin di default — include SoPlex, tutti i presolvers,
     * heuristics, separators, propagators. Esercita la stessa code path
     * che JSCIPOpt usa via SCIPincludeDefaultPlugins(). */
    rc = SCIPincludeDefaultPlugins(scip);
    if (rc != SCIP_OKAY) {
        fprintf(stderr, "ERRORE: SCIPincludeDefaultPlugins fallito (rc=%d)\n", rc);
        goto cleanup;
    }

    /* Parametri: time limit e output ridotto */
    SCIPsetRealParam(scip, "limits/time", TIME_LIMIT);
    SCIPsetIntParam(scip, "display/verblevel", 0);

    /* Leggi il problema */
    rc = SCIPreadProb(scip, filename, NULL);
    if (rc != SCIP_OKAY) {
        fprintf(stderr, "ERRORE: SCIPreadProb fallito (rc=%d) — file corrotto o formato non supportato?\n", rc);
        goto cleanup;
    }

    printf("  Variabili:  %d\n", SCIPgetNVars(scip));
    printf("  Vincoli:    %d\n", SCIPgetNConss(scip));
    printf("  Intere:     %d\n", SCIPgetNBinVars(scip) + SCIPgetNIntVars(scip));

    /* Risolvi */
    rc = SCIPsolve(scip);
    if (rc != SCIP_OKAY) {
        fprintf(stderr, "ERRORE: SCIPsolve fallito (rc=%d)\n", rc);
        goto cleanup;
    }

    /* Verifica status */
    SCIP_STATUS status = SCIPgetStatus(scip);
    const char* status_str;
    switch (status) {
        case SCIP_STATUS_OPTIMAL:         status_str = "OPTIMAL";         success = 1; break;
        case SCIP_STATUS_INFEASIBLE:      status_str = "INFEASIBLE";      success = 1; break;
        case SCIP_STATUS_UNBOUNDED:       status_str = "UNBOUNDED";       success = 1; break;
        case SCIP_STATUS_INFORUNBD:       status_str = "INFEASIBLE_OR_UNBOUNDED"; success = 1; break;
        case SCIP_STATUS_TIMELIMIT:       status_str = "TIME_LIMIT";      success = 0; break;
        case SCIP_STATUS_MEMLIMIT:        status_str = "MEM_LIMIT";       success = 0; break;
        case SCIP_STATUS_GAPLIMIT:        status_str = "GAP_LIMIT";       success = 1; break;
        case SCIP_STATUS_SOLLIMIT:        status_str = "SOL_LIMIT";       success = 1; break;
        case SCIP_STATUS_BESTSOLLIMIT:    status_str = "BESTSOL_LIMIT";   success = 1; break;
        default:                          status_str = "UNKNOWN";         success = 0; break;
    }

    printf("  Status:     %s\n", status_str);

    if (SCIPgetNSols(scip) > 0) {
        SCIP_SOL* best = SCIPgetBestSol(scip);
        printf("  Obiettivo:  %.10g\n", SCIPgetSolOrigObj(scip, best));
        printf("  Gap:        %.4f%%\n", 100.0 * SCIPgetGap(scip));
    } else {
        printf("  Nessuna soluzione trovata\n");
        /* INFEASIBLE senza soluzioni è legittimo */
        if (status != SCIP_STATUS_INFEASIBLE) {
            success = 0;
        }
    }

    printf("  Tempo:      %.2fs\n", SCIPgetSolvingTime(scip));
    printf("  Nodi:       %lld\n", SCIPgetNNodes(scip));
    printf("  Risultato:  %s\n", success ? "OK" : "FALLITO");

cleanup:
    if (scip != NULL) {
        SCIPfree(&scip);
    }
    return success;
}

int main(int argc, char** argv)
{
    if (argc < 2) {
        fprintf(stderr, "Uso: %s <file.cip> [file2.cip ...]\n", argv[0]);
        return 1;
    }

    printf("SCIP smoke test — %d problemi\n", argc - 1);
    printf("SCIP version: %s\n", SCIPversion() >= 900 ?  "9.x" : "pre-9");

    int total = argc - 1;
    int passed = 0;
    int failed = 0;
    const char* failed_files[256];
    int failed_count = 0;

    for (int i = 1; i < argc; i++) {
        if (solve_one(argv[i])) {
            passed++;
        } else {
            failed++;
            if (failed_count < 256) {
                failed_files[failed_count++] = argv[i];
            }
        }
    }

    printf("\n========================================\n");
    printf("RIEPILOGO: %d/%d passati", passed, total);
    if (failed > 0) {
        printf(", %d FALLITI:\n", failed);
        for (int i = 0; i < failed_count; i++) {
            printf("  - %s\n", failed_files[i]);
        }
    } else {
        printf(" — tutti OK\n");
    }
    printf("========================================\n");

    return failed > 0 ? 1 : 0;
}
