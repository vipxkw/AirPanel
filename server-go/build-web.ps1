# 前端构建脚本：编译 Tailwind CSS 并复制静态资源到 static/
# 依赖：E:\tool\go-sdk\tailwindcss.exe（Tailwind standalone CLI，无需 Node）
$ErrorActionPreference = "Stop"

$Tailwind = "E:\tool\go-sdk\tailwindcss.exe"
$WebDir   = Join-Path $PSScriptRoot "web"
$StaticDir = Join-Path $PSScriptRoot "static"

if (-not (Test-Path $Tailwind)) {
    Write-Error "未找到 Tailwind CLI: $Tailwind"
    exit 1
}

# 1. 编译 CSS
New-Item -ItemType Directory -Force -Path (Join-Path $StaticDir "css"), (Join-Path $StaticDir "js") | Out-Null
Push-Location $WebDir
try {
    & $Tailwind -c "tailwind.config.js" -i "src\input.css" -o (Join-Path $StaticDir "css\style.css") --minify
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}

# 2. 复制 HTML 与 JS
Copy-Item (Join-Path $WebDir "index.html") (Join-Path $StaticDir "index.html") -Force
Copy-Item (Join-Path $WebDir "js\*.js") (Join-Path $StaticDir "js\") -Force

Write-Output "前端构建完成 -> $StaticDir"
