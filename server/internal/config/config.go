package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Server      ServerConfig
	DB          DBConfig
	Redis       RedisConfig
	JWT         JWTConfig
	Storage     StorageConfig
	CORS        CORSConfig
	WS          WSConfig
	Hub         HubConfig
	Message     MessageConfig
	Admin       AdminConfig
	MiniProgram MiniProgramConfig
}

// AdminConfig 平台管理员(自部署语义:管理员=部署者)。
type AdminConfig struct {
	Usernames []string // ADMIN_USERNAMES,登录命中签发 role=admin
}

// MiniProgramConfig 小程序容器配置。
type MiniProgramConfig struct {
	MaxZipBytes int64 // 单包上限(字节),上传用 MaxBytesReader 拦截
}

type ServerConfig struct {
	Port              string
	ReadHeaderTimeout time.Duration // 读完整请求头的超时，防 Slowloris；不影响 WS 长连接（hijack 后脱离 http.Server）
	IdleTimeout       time.Duration // keep-alive 空闲超时；不影响已 hijack 的 WS 连接
	MaxJSONBodyBytes  int64         // 全局 JSON 路由请求体上限(文件上传路由有自己的 MaxBytesReader,不受此限制)
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
	Secret     string
	AccessTTL  time.Duration
	RefreshTTL time.Duration
}

type StorageConfig struct {
	Path           string
	MaxUploadBytes int64 // 单文件上传上限（字节），handler 用 MaxBytesReader 拦截
}

type CORSConfig struct {
	AllowedOrigins []string
}

// WSConfig 配置 WebSocket CheckOrigin 行为:
// - AllowedOrigins 非空 → 仅白名单内 Origin 放行(开发多域名场景)
// - AllowedOrigins 为空 → 同源校验(Origin host == Host header,单域名生产)
// - 无 Origin 头(plugin adapter 等非浏览器 client)始终放行
type WSConfig struct {
	AllowedOrigins []string
}

// HubConfig 配置 hub.Hub 运行时参数。
// BufferSize 是 dispatchBuffer 实现细节(const 包级定义),不在此暴露。
type HubConfig struct {
	HeartbeatTimeout time.Duration // 心跳超时,超时则 gcStaleClients 关连接
}

// MessageConfig 配置 message handler 业务参数。
type MessageConfig struct {
	MaxBatchDelete int           // 单次批量删除上限
	RecallWindow   time.Duration // 撤回时间窗口
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
			Port:              getEnv("SERVER_PORT", "18008"),
			ReadHeaderTimeout: getEnvDuration("SERVER_READ_HEADER_TIMEOUT", 10*time.Second),
			IdleTimeout:       getEnvDuration("SERVER_IDLE_TIMEOUT", 60*time.Second),
			MaxJSONBodyBytes:  getEnvInt64("SERVER_MAX_JSON_BODY_BYTES", 1<<20),
		},
		DB: DBConfig{
			Host:     getEnv("DB_HOST", "localhost"),
			Port:     getEnvInt("DB_PORT", 5432),
			User:     getEnv("DB_USER", "postgres"),
			Password: dbPassword,
			DBName:   getEnv("DB_NAME", "wanling"),
			SSLMode:  getEnv("DB_SSLMODE", "disable"),
		},
		Redis: RedisConfig{
			Host:     getEnv("REDIS_HOST", "localhost"),
			Port:     getEnvInt("REDIS_PORT", 6379),
			Password: os.Getenv("REDIS_PASSWORD"),
			DB:       getEnvInt("REDIS_DB", 0),
		},
		JWT: JWTConfig{
			Secret:     jwtSecret,
			AccessTTL:  getEnvDuration("JWT_ACCESS_TTL", 2*time.Hour),
			RefreshTTL: getEnvDuration("JWT_REFRESH_TTL", 30*24*time.Hour),
		},
		Storage: StorageConfig{
			Path:           getEnv("STORAGE_PATH", "./uploads"),
			MaxUploadBytes: getEnvInt64("UPLOAD_MAX_BYTES", 32<<20),
		},
		CORS: CORSConfig{
			AllowedOrigins: parseCSV(os.Getenv("CORS_ALLOWED_ORIGINS")),
		},
		WS: WSConfig{
			AllowedOrigins: parseCSV(os.Getenv("WS_ALLOWED_ORIGINS")),
		},
		Hub: HubConfig{
			HeartbeatTimeout: getEnvDuration("HUB_HEARTBEAT_TIMEOUT", 90*time.Second),
		},
		Message: MessageConfig{
			MaxBatchDelete: getEnvInt("MSG_MAX_BATCH_DELETE", 100),
			RecallWindow:   getEnvDuration("MSG_RECALL_WINDOW", 5*time.Minute),
		},
		Admin: AdminConfig{
			Usernames: parseCSV(getEnv("ADMIN_USERNAMES", "")),
		},
		MiniProgram: MiniProgramConfig{
			MaxZipBytes: getEnvInt64("MINIPROGRAM_MAX_ZIP_BYTES", 20<<20),
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
		i, err := strconv.Atoi(v)
		if err != nil {
			return fallback
		}
		return i
	}
	return fallback
}

// getEnvInt64 读取 int64 环境变量，解析失败回退默认值（不返 0）。
//
// 用于大小限制等场景：0 表示"禁用/禁止"，若解析失败误返 0 会禁掉全部合法请求，
// 故必须回退 fallback。
func getEnvInt64(key string, fallback int64) int64 {
	if v := os.Getenv(key); v != "" {
		i, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return fallback
		}
		return i
	}
	return fallback
}

// getEnvDuration 读取 duration 环境变量（如 "10s"、"2m"），解析失败回退默认值。
func getEnvDuration(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
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
