package main

import (
	"embed"
	"log/slog"
	"net/http"
	"os"

	"github.com/pe-workflow/services/internal/api"
	"github.com/pe-workflow/services/internal/auth"
	"github.com/pe-workflow/services/internal/proxy"
	"github.com/prometheus/client_golang/prometheus"
)

//go:embed static/*
var static embed.FS

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	tokens, err := auth.NewTokenManagerFromEnv()
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(1)
	}
	metrics := api.NewMetrics(prometheus.DefaultRegisterer)
	p, err := proxy.NewClient(os.Getenv("ZEEBE_REST_ADDRESS"), tokens, nil)
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(1)
	}
	p.On401(metrics.TokenRefresh.Inc)
	handler := api.NewRouter(p, static, logger, metrics)
	addr := os.Getenv("BFF_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	logger.Info("webapp listening", "address", addr)
	if err := http.ListenAndServe(addr, handler); err != nil {
		logger.Error("server stopped", "error", err)
		os.Exit(1)
	}
}
