#!/usr/bin/env bash
# M1 端到端验证:用户A上传→A可见→admin publish→用户B可见→B下载包校验 sha256。
# 凭证一律从环境变量读取,缺省即失败(fail fast,禁止硬编码):
#   WANLING_BASE_URL  服务地址,如 http://localhost:18008
#   ADMIN_USERNAME / ADMIN_PASSWORD   已配置在 ADMIN_USERNAMES 的账号
#   USER_A_USERNAME / USER_A_PASSWORD 普通用户A
#   USER_B_USERNAME / USER_B_PASSWORD 普通用户B
set -euo pipefail

: "${WANLING_BASE_URL:?缺少 WANLING_BASE_URL}"
: "${ADMIN_USERNAME:?缺少 ADMIN_USERNAME}" ; : "${ADMIN_PASSWORD:?缺少 ADMIN_PASSWORD}"
: "${USER_A_USERNAME:?缺少 USER_A_USERNAME}" ; : "${USER_A_PASSWORD:?缺少 USER_A_PASSWORD}"
: "${USER_B_USERNAME:?缺少 USER_B_USERNAME}" ; : "${USER_B_PASSWORD:?缺少 USER_B_PASSWORD}"

BASE="$WANLING_BASE_URL"

TMP_ZIP=$(mktemp)
trap 'rm -f "$TMP_ZIP"' EXIT
# 登录响应 envelope 为 {ok,data:{user,token,refresh_token}},取 data.token
login() {
    local resp
    resp=$(curl -sf -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' -d "{\"username\":\"$1\",\"password\":\"$2\"}") \
        || { echo "登录失败($1，可能限流或凭证错误)" >&2; exit 1; }
    printf '%s' "$resp" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["data"]["token"])'
}

TOKEN_A=$(login "$USER_A_USERNAME" "$USER_A_PASSWORD")
TOKEN_B=$(login "$USER_B_USERNAME" "$USER_B_PASSWORD")
TOKEN_ADMIN=$(login "$ADMIN_USERNAME" "$ADMIN_PASSWORD")

bash "$(dirname "$0")/build_example_miniprogram.sh"
ZIP="scripts/examples/hello-demo.zip"

echo "== A 上传私有小程序"
MP_ID=$(curl -sf -X POST "$BASE/api/mini-programs" -H "Authorization: Bearer $TOKEN_A" -F "file=@$ZIP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
echo "   id=$MP_ID"

echo "== B 此刻不可见(private)"
# 先落变量让 set -e 接管 curl 失败(5xx/401/429 不允许静默落到 OK 分支)
LIST_B=$(curl -sf "$BASE/api/mini-programs" -H "Authorization: Bearer $TOKEN_B")
if grep -q "\"id\":\"$MP_ID\"" <<<"$LIST_B"; then
    echo "   FAIL: B 看到了 private"
    exit 1
fi
echo "   OK"

echo "== admin publish"
curl -sf -X PUT "$BASE/api/mini-programs/$MP_ID/status" -H "Authorization: Bearer $TOKEN_ADMIN" -H 'Content-Type: application/json' -d '{"status":"published"}' > /dev/null

echo "== B 可见且可下载,sha256 一致"
LISTED_SHA=$(curl -sf "$BASE/api/mini-programs" -H "Authorization: Bearer $TOKEN_B" | python3 -c "import sys,json;print([m['sha256'] for m in json.load(sys.stdin)['data'] if m['id']=='$MP_ID'][0])")
curl -sf "$BASE/api/mini-programs/$MP_ID/package" -H "Authorization: Bearer $TOKEN_B" -o "$TMP_ZIP"
ACTUAL_SHA=$(sha256sum "$TMP_ZIP" | cut -d' ' -f1)
[ "$LISTED_SHA" = "$ACTUAL_SHA" ] || { echo "   FAIL: sha256 不一致"; exit 1; }
echo "   OK"
echo "M1 端到端验证通过"
