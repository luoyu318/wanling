package config

import (
	"os"
	"testing"
	"time"
)

// TestLoad_Defaults 验证关键默认值，防止运维未配置时回退到危险值（如 0 = 禁用上传）。
//
// 仅覆盖带安全含义的默认值（超时 / 上传上限），必填项（JWT_SECRET / DB_PASSWORD）
// 在 Load() 内强制校验，缺则报错，不需断言。
func TestLoad_Defaults(t *testing.T) {
	t.Setenv("JWT_SECRET", "test-secret-for-defaults-check")
	t.Setenv("DB_PASSWORD", "test-pwd")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if cfg.Server.ReadHeaderTimeout != 10*time.Second {
		t.Errorf("ReadHeaderTimeout default: want 10s, got %v", cfg.Server.ReadHeaderTimeout)
	}
	if cfg.Server.IdleTimeout != 60*time.Second {
		t.Errorf("IdleTimeout default: want 60s, got %v", cfg.Server.IdleTimeout)
	}
	// 32MB = 32<<20，0 表示禁所有上传，必须回退到合理默认
	if cfg.Storage.MaxUploadBytes != 32<<20 {
		t.Errorf("MaxUploadBytes default: want %d, got %d", 32<<20, cfg.Storage.MaxUploadBytes)
	}
}

func TestGetEnvInt_NormalValue(t *testing.T) {
	os.Setenv("TEST_ENV_INT", "8080")
	defer os.Unsetenv("TEST_ENV_INT")
	if got := getEnvInt("TEST_ENV_INT", 3000); got != 8080 {
		t.Errorf("期望 8080, 实际 %d", got)
	}
}

func TestGetEnvInt_InvalidValue_ReturnsFallback(t *testing.T) {
	os.Setenv("TEST_ENV_INT", "abc")
	defer os.Unsetenv("TEST_ENV_INT")
	if got := getEnvInt("TEST_ENV_INT", 3000); got != 3000 {
		t.Errorf("非数值应返回 fallback 3000, 实际 %d", got)
	}
}

func TestGetEnvInt_EmptyValue_ReturnsFallback(t *testing.T) {
	os.Setenv("TEST_ENV_INT", "")
	defer os.Unsetenv("TEST_ENV_INT")
	if got := getEnvInt("TEST_ENV_INT", 3000); got != 3000 {
		t.Errorf("空值应返回 fallback 3000, 实际 %d", got)
	}
}

func TestGetEnvInt_NotSet_ReturnsFallback(t *testing.T) {
	os.Unsetenv("TEST_ENV_INT_NOT_SET")
	if got := getEnvInt("TEST_ENV_INT_NOT_SET", 3000); got != 3000 {
		t.Errorf("未设置应返回 fallback 3000, 实际 %d", got)
	}
}

// TestGetEnvInt64_InvalidFallback 验证非法值回退默认值而非 0。
//
// getEnvInt 的旧实现对非法值返回 0（陷阱），对 MaxUploadBytes 场景会禁掉全部上传。
// getEnvInt64 必须回退 fallback。
func TestGetEnvInt64_InvalidFallback(t *testing.T) {
	t.Setenv("UPLOAD_MAX_BYTES", "not-a-number")
	got := getEnvInt64("UPLOAD_MAX_BYTES", 32<<20)
	if got != 32<<20 {
		t.Errorf("invalid UPLOAD_MAX_BYTES: want fallback %d, got %d", 32<<20, got)
	}
}
