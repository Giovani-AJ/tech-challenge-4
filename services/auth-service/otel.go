package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
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

	// Métricas (http.server.request.duration etc., geradas pelo otelhttp): o APM do New Relic
	// monta o resumo do serviço (tempo de resposta, vazão, erros) a partir delas. A temporalidade
	// "delta" exigida pelo New Relic vem de OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE.
	var mp *sdkmetric.MeterProvider
	if mexp, merr := otlpmetrichttp.New(ctx); merr != nil {
		log.Printf("Aviso: falha ao criar exporter de métricas OTLP: %v", merr)
	} else {
		mp = sdkmetric.NewMeterProvider(
			sdkmetric.WithReader(sdkmetric.NewPeriodicReader(mexp, sdkmetric.WithInterval(15*time.Second))),
			sdkmetric.WithResource(res),
		)
		otel.SetMeterProvider(mp)
	}

	log.Println("OpenTelemetry ativado: traces e métricas enviados via OTLP/HTTP.")
	return func(c context.Context) error {
		if mp != nil {
			_ = mp.Shutdown(c)
		}
		return tp.Shutdown(c)
	}
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
