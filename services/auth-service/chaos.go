package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"sync/atomic"
)

// Injeção de falha para a DEMONSTRAÇÃO do self-healing (Fase 4).
//
// Só existe quando CHAOS_ENABLED=true (desligado por padrão) e o endpoint é protegido
// pela MASTER_KEY, como o resto de /admin. O estado "quebrado" fica na MEMÓRIA do
// processo: um `kubectl rollout restart` (o que o self-healer executa) elimina a falha,
// que é exatamente o cenário "reiniciar resolve" (ex.: estado corrompido/leak em memória).
var chaosBroken atomic.Bool

func chaosEnabled() bool { return os.Getenv("CHAOS_ENABLED") == "true" }

// chaosHandler: POST /admin/chaos?mode=break | fix ; GET para consultar o estado.
func (a *App) chaosHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if r.Method == http.MethodPost {
		switch r.URL.Query().Get("mode") {
		case "break":
			chaosBroken.Store(true)
			log.Println("[CHAOS] falha injetada: /validate passará a responder 500 neste pod")
		case "fix":
			chaosBroken.Store(false)
			log.Println("[CHAOS] falha removida")
		default:
			http.Error(w, `{"error":"use ?mode=break ou ?mode=fix"}`, http.StatusBadRequest)
			return
		}
	}
	_ = json.NewEncoder(w).Encode(map[string]bool{"broken": chaosBroken.Load()})
}
