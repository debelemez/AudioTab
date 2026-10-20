#!/bin/bash
# AudioTab'ı GitHub'a yükler, otomatik derlemeyi kurar, ilk sürümü yayınlar ve istersen kurar.
# Kullanım: ./publish.sh
set -euo pipefail
cd "$(dirname "$0")"
NAME="AudioTab"

if ! command -v gh >/dev/null; then
  if command -v brew >/dev/null; then
    echo "▶ GitHub komut satırı aracı (gh) kuruluyor..."
    brew install gh
  else
    echo "❌ 'gh' gerekli. https://cli.github.com adresinden indirip kur, sonra ./publish.sh'i tekrar çalıştır."
    exit 1
  fi
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "▶ GitHub'a giriş: tarayıcı açılacak, ekrandaki kodu gir ve izin ver."
  gh auth login --hostname github.com --git-protocol https --web --scopes "repo,workflow"
fi
gh auth setup-git >/dev/null 2>&1 || true

OWNER="$(gh api user --jq .login)"
REPO="$OWNER/$NAME"
echo "▶ Repo: $REPO"

# Repo adresini güncelleyiciye ve kurulum betiğine yaz
if grep -q "__GITHUB_REPO__" Sources/Updater.swift install.sh README.md 2>/dev/null; then
  sed -i '' "s#__GITHUB_REPO__#$REPO#g" Sources/Updater.swift install.sh README.md
  git add Sources/Updater.swift install.sh README.md
  git commit -q -m "Güncelleme kaynağı: github.com/$REPO"
fi

# Repoyu oluştur (varsa sadece bağla) ve yükle
if gh repo view "$REPO" >/dev/null 2>&1; then
  git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$REPO.git"
  git push -u origin main
else
  gh repo create "$REPO" --public --source . --remote origin \
    --description "macOS menü çubuğu: glassmorphism ⌘Tab, ses çıkışı değiştirici, ekran bölme, ekran görüntüsü ve MP4 kayıt" --push
fi

# İmza sertifikası (sürümler hep aynı sertifikayla imzalanır → izinler güncellemede korunur)
if [ -d signing-secrets ]; then
  echo "▶ İmza sertifikası GitHub'a gizli değişken olarak ekleniyor..."
  gh secret set CERT_P12 --repo "$REPO" < signing-secrets/cert.b64
  gh secret set CERT_PASSWORD --repo "$REPO" < signing-secrets/password
  rm -rf signing-secrets
fi

# İlk sürümü yayınla
VERSION="$(cat VERSION)"
TAG="v$VERSION"
if ! git rev-parse "$TAG" >/dev/null 2>&1; then git tag "$TAG"; fi
git push origin "$TAG"

echo "▶ GitHub Mac'te derliyor (3-5 dk)..."
sleep 15
RUN_ID="$(gh run list --repo "$REPO" --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
if ! gh run watch "$RUN_ID" --repo "$REPO" --exit-status; then
  echo ""
  echo "❌ Derleme başarısız. Aşağıdakini kopyalayıp Claude'a gönder:"
  echo "----------------------------------------------------------------"
  gh run view "$RUN_ID" --repo "$REPO" --log-failed | grep -E "error:|❌" | head -30
  exit 1
fi

echo ""
echo "✅ Yayında: https://github.com/$REPO/releases/tag/$TAG"
read -r -p "AudioTab $VERSION şimdi kurulsun mu? (e/h) " ans
if [[ "$ans" == "e" || "$ans" == "E" ]]; then
  ./install.sh
  echo ""
  echo "ℹ️  Bu ilk kurulumda Erişilebilirlik ve Ekran Kaydı iznini bir kez daha ver (eski AudioTab'ı listeden – ile kaldırıp yenisini ekle)."
  echo "    Bundan sonraki güncellemelerde izinler korunur."
fi
