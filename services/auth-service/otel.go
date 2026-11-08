package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// initTelemetry configura o tracing OpenTelemetry (OTLP/HTTP -> OTel Collector).
//
// Configuração 100% por variáveis de ambiente padrão do OTel:
//   OTEL_EXPORTER_OTLP_ENDPOINT  ex.: http://otel-gateway.monitoring.svc:4318
//   OTEL_SERVICE_NAME            nome do serviço no APM / Service Map
//
// Sem OTEL_EXPORTER_OTLP_ENDPOINT o tracing fica desligado (dev local / docker-compose),
// mas o propagador W3C continua registrado para não quebrar a propagação de contexto.
func initTelemetry(defaultServiceName string) func(context.Context) error {
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{}))

	if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" && os.Getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") == "" {
		log.Println("OpenTelemetry desativado (OTEL_EXPORTER_OTLP_ENDPOINT não definido).")
		return func(context.Context) error { return nil }
	}

	ctx := context.Background()
	exporter, err := otlptracehttp.New(ctx)
	if err != nil {
		log.Printf("Aviso: falha ao criar exporter OTLP, tracing desativado: %v", err)
		return func(context.Context) error { return nil }
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(semconv.ServiceName(defaultServiceName)),
		resource.WithFromEnv(), // OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES sobrescrevem o default
		resource.WithTelemetrySDK(),
		resource.WithHost(),
	)
	if err != nil {
		log.Printf("Aviso: falha ao montar resource OTel: %v", err)
		res = resource.Default()
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter, sdktrace.WithBatchTimeout(2*time.Second)),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)
	log.Println("OpenTelemetry ativado: traces enviados via OTLP/HTTP.")
	return tp.Shutdown
}

// instrumentHandler envolve o mux com o middleware OTel (um span SERVER por requisição).
// /health é filtrado: as probes do Kubernetes gerariam ruído nos traces e nas métricas RED.
func instrumentHandler(h http.Handler) http.Handler {
	return otelhttp.NewHandler(h, "http.server",
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/health" }),
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
			return r.Method + " " + r.URL.Path
		}),
	)
}
