#!/usr/bin/env bash
# 打包示例小程序为 hello-demo.zip(供上传验证)。
set -euo pipefail
cd "$(dirname "$0")/examples/miniprogram-hello"
rm -f ../hello-demo.zip
zip -X ../hello-demo.zip manifest.json index.html
echo "已生成: scripts/examples/hello-demo.zip"
