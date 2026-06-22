package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	Server  ServerConfig
	DB      DBConfig
	Redis   RedisConfig
	JWT     JWTConfig
	Storage StorageConfig
	CORS    CORSConfig
}

type ServerConfig struct {
	Port string
}

type DBConfig struct {
	Host     string
	Port     int
	User     string
	Password string
	DBName   string
	SSLMode  string
}

type RedisConfig struct {
	Host     string
	Port     int
	Password string
	DB       int
}

type JWTConfig struct {
	Secret string
}

type StorageConfig struct {
	Path string
}

type CORSConfig struct {
	AllowedOrigins []string
}

func Load() (*Config, error) {
	// 必填项校验
	jwtSecret := os.Getenv("JWT_SECRET")
	if jwtSecret == "" {
		return nil, fmt.Errorf("环境变量 JWT_SECRET 未设置")
	}

	dbPassword := os.Getenv("DB_PASSWORD")
	if dbPassword == "" {
		return nil, fmt.Errorf("环境变量 DB_PASSWORD 未设置")
	}

	return &Config{
		Server: ServerConfig{
			Port: getEnv("SERVER_PORT", "18008"),
		},
		DB: DBConfig{
			Host:     getEnv("DB_HOST", "localhost"),
			Port:     getEnvInt("DB_PORT", 5432),
			User:     getEnv("DB_USER", "postgres"),
			Password: dbPassword,
			DBName:   getEnv("DB_NAME", "agent_chat"),
			SSLMode:  getEnv("DB_SSLMODE", "disable"),
		},
		Redis: RedisConfig{
			Host:     getEnv("REDIS_HOST", "localhost"),
			Port:     getEnvInt("REDIS_PORT", 6379),
			Password: os.Getenv("REDIS_PASSWORD"),
			DB:       getEnvInt("REDIS_DB", 0),
		},
		JWT: JWTConfig{
			Secret: jwtSecret,
		},
		Storage: StorageConfig{
			Path: getEnv("STORAGE_PATH", "./uploads"),
		},
		CORS: CORSConfig{
			AllowedOrigins: parseCSV(getEnv("CORS_ALLOWED_ORIGINS", "*")),
		},
	}, nil
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getEnvInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		i, _ := strconv.Atoi(v)
		return i
	}
	return fallback
}

func parseCSV(s string) []string {
	if s == "" {
		return nil
	}
	var result []string
	for _, v := range strings.Split(s, ",") {
		v = strings.TrimSpace(v)
		if v != "" {
			result = append(result, v)
		}
	}
	return result
}
