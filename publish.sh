#!/bin/bash
# Публикует свежую сборку каталога: релиз на GitHub и, если есть логин, зеркало в npm.
# Запуск: ./publish.sh [папка-сборки]   (по умолчанию ~/tools/curator/dist)
set -euo pipefail

DIST="${1:-$HOME/tools/curator/dist}"
REPO="${WHEEL_CATALOG_REPO:-kalpakprod/wheel-catalog}"
HERE="$(cd "$(dirname "$0")" && pwd)"

for f in manifest.json catalog.jsonl.gz; do
    [ -f "$DIST/$f" ] || { echo "нет $DIST/$f — сначала: curator.py export"; exit 1; }
done

VER=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$DIST/manifest.json" | head -1)
CNT=$(sed -n 's/.*"count"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$DIST/manifest.json" | head -1)
[ -n "$VER" ] || { echo "в манифесте нет version"; exit 1; }

if gh release view "$VER" --repo "$REPO" > /dev/null 2>&1; then
    # пересборка того же дня заменяет артефакты: релиз на дату один
    gh release upload "$VER" "$DIST/catalog.jsonl.gz" "$DIST/manifest.json" --repo "$REPO" --clobber
    echo "релиз $VER обновлён"
else
    gh release create "$VER" "$DIST/catalog.jsonl.gz" "$DIST/manifest.json" \
        --repo "$REPO" --title "$VER" \
        --notes "Каталог проектов для плагина wheel: $CNT записей."
    echo "релиз $VER создан"
fi

# своё зеркало: файлы едут на PVE и оттуда в контейнер сайта.
# Каталог лежит в /srv/wheel, а не в корне сайта: деплой сайта очищает его целиком.
KEY="${HOMELAB_KEY:-$HOME/.ssh/homelab_ed25519}"
PVE="${HOMELAB_PVE:-root@192.168.1.20}"
if [ -r "$KEY" ] && scp -q -i "$KEY" -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
        "$DIST/catalog.jsonl.gz" "$DIST/manifest.json" "$PVE":/tmp/ 2> /dev/null; then
    ssh -i "$KEY" -o StrictHostKeyChecking=no "$PVE" '
        for f in catalog.jsonl.gz manifest.json; do
            pct push 163 /tmp/$f /srv/wheel/$f --perms 644
            rm -f /tmp/$f
        done
        pct exec 163 -- chown www-data:www-data /srv/wheel/catalog.jsonl.gz /srv/wheel/manifest.json
    ' && echo "своё зеркало обновлено: kukuruza.kalpak.dev/wheel"
else
    echo "своё зеркало пропущено: нет доступа к $PVE"
fi

# npm — ещё одно зеркало: публикация сразу даёт CDN unpkg и jsDelivr
if npm whoami > /dev/null 2>&1; then
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    cp "$DIST/catalog.jsonl.gz" "$DIST/manifest.json" "$HERE/README.md" "$TMP/"
    sed "s/\"version\": \"[^\"]*\"/\"version\": \"$VER\"/" "$HERE/package.json" > "$TMP/package.json"
    (cd "$TMP" && npm publish --access public)
    echo "npm-зеркало обновлено: $VER"
else
    echo "npm: не залогинен, зеркало пропущено (npm login)"
fi
