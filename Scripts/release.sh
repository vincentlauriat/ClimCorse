#!/usr/bin/env bash
# Compile ClimCorse en Release, le signe avec l'identité Developer ID et le
# Hardened Runtime, le fait notariser par Apple, agrafe le ticket, l'empaquette
# en DMG, puis signe ce DMG avec la clé Sparkle et régénère appcast.xml.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ CLÉ DE SIGNATURE SPARKLE — NE JAMAIS LA RÉGÉNÉRER                        │
# │                                                                          │
# │ Les mises à jour sont signées en EdDSA avec la clé privée du trousseau    │
# │ de session, sous le compte "ClimCorse". Sa moitié publique est embarquée  │
# │ dans l'app via SUPublicEDKey dans project.yml :                          │
# │     NliHXU9oXogFupZWheoNI67G22h5WoCayAugdzEkyQ4=                         │
# │                                                                          │
# │ Ne JAMAIS relancer `generate_keys` sur ce compte ni changer              │
# │ SUPublicEDKey : toute app déjà installée refuserait alors l'intégralité   │
# │ des mises à jour futures, imposant un re-téléchargement manuel à chaque   │
# │ utilisateur. Sauvegarder la clé quelque part de sûr :                    │
# │     .sparkle-tools/bin/generate_keys -x backup.txt --account ClimCorse    │
# └──────────────────────────────────────────────────────────────────────────┘
#
# Usage : ./Scripts/release.sh <version>
#   ex.  ./Scripts/release.sh 0.1.0
#
# Prérequis (installation unique) :
#   - Certificat "Developer ID Application: Vincent LAURIAT (KFLACS69T9)" dans
#     le trousseau de session.
#   - Identifiants notarytool sous le profil de trousseau
#     "AppliMacVincentGithub" — partagé par tous les projets, ne pas en créer
#     un nouveau :
#       xcrun notarytool store-credentials "AppliMacVincentGithub" \
#         --apple-id "vincent@lauriat.fr" --team-id "KFLACS69T9"
#
# Produit release/ClimCorse-<version>.dmg, entièrement notarisé. Ne publie
# rien : affiche les commandes `gh release create` à lancer ensuite.

set -euo pipefail

# Notary credentials: an App Store Connect API key (.p8) when NOTARY_KEY_ID, NOTARY_ISSUER_ID and
# NOTARY_KEY_PATH are set or read from ~/.config/notarytool/api-key.env (it survives a keychain
# reset); otherwise the keychain profile given as first argument. Usage: notary_run <profile> <args>
notary_run() {
  _np="$1"; shift
  _nf="${NOTARY_ENV_FILE:-$HOME/.config/notarytool/api-key.env}"
  if [ -z "${NOTARY_KEY_ID:-}" ] && [ -f "$_nf" ]; then . "$_nf"; fi
  if [ -n "${NOTARY_KEY_ID:-}" ]; then
    xcrun notarytool "$@" --key "${NOTARY_KEY_PATH/#\~/$HOME}" --key-id "$NOTARY_KEY_ID" --issuer "${NOTARY_ISSUER_ID:-}"
  else
    xcrun notarytool "$@" --keychain-profile "$_np"
  fi
}

VERSION="${1:?Usage: ./Scripts/release.sh <version>  (ex. ./Scripts/release.sh 0.1.0)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="ClimCorse"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Vincent LAURIAT (KFLACS69T9)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AppliMacVincentGithub}"
SPARKLE_ACCOUNT="ClimCorse"
SPARKLE_VERSION="2.9.1"

# 1. Cohérence de version : project.yml fait foi.
if ! grep -q "MARKETING_VERSION: \"$VERSION\"" project.yml; then
  echo "✗ MARKETING_VERSION dans project.yml ne correspond pas à $VERSION" >&2
  grep "MARKETING_VERSION" project.yml | sed 's/^/    /' >&2
  echo "  Mettre project.yml à jour, puis relancer." >&2
  exit 1
fi

# 2. Régénération du projet Xcode.
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "✗ XcodeGen absent. brew install xcodegen" >&2
  exit 1
fi
echo "→ xcodegen generate"
xcodegen generate >/dev/null

# 3. Build Release.
# CODE_SIGNING_ALLOWED=NO contourne l'attribut étendu `com.apple.provenance`
# que macOS pose depuis Sequoia et qui fait échouer codesign en ligne de
# commande. La signature est faite manuellement plus bas, après nettoyage.
echo "→ xcodebuild Release"
xcodebuild -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -5

APP="$ROOT/build/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$APP" ]; then
  echo "✗ Le build n'a pas produit $APP" >&2
  exit 1
fi

# 4. Copie vers un dossier propre, puis signature.
# Signer sur place échoue : `lsregister` pose des xattrs que `codesign --force`
# rejette (« resource fork, Finder information, or similar detritus not
# allowed »). `ditto --noextattr` copie sans eux.
STAGING_DIR="$(mktemp -d)"
STAGING="$STAGING_DIR/$APP_NAME.app"
echo "→ Copie vers $STAGING_DIR"
ditto --norsrc --noextattr --noacl "$APP" "$STAGING"

# Le serveur d'horodatage d'Apple est régulièrement capricieux
# (« A timestamp was expected but was not found »). On réessaie.
codesign_ts() {
  local target="$1"
  local attempt
  for attempt in 1 2 3 4 5; do
    if codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$target" 2>&1; then
      return 0
    fi
    if [ "$attempt" -lt 5 ]; then
      echo "  ↻ codesign échoué (tentative $attempt/5), nouvel essai dans 5 s…"
      sleep 5
    fi
  done
  echo "✗ codesign $target a échoué après 5 tentatives" >&2
  return 1
}

# Signature du plus imbriqué vers l'extérieur : signer le conteneur avant son
# contenu invaliderait la signature du conteneur.
echo "→ Signature des binaires internes de Sparkle.framework"
SPARKLE_FW="$STAGING/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  SPARKLE_VER="$SPARKLE_FW/Versions/B"
  codesign_ts "$SPARKLE_VER/Autoupdate"
  codesign_ts "$SPARKLE_VER/XPCServices/Downloader.xpc"
  codesign_ts "$SPARKLE_VER/XPCServices/Installer.xpc"
  codesign_ts "$SPARKLE_VER/Updater.app"
  codesign_ts "$SPARKLE_FW"
fi

echo "→ Signature de l'application (Developer ID + Hardened Runtime)"
codesign_ts "$STAGING"
codesign --verify --strict --deep "$STAGING"

RELEASE_DIR="$ROOT/release"
mkdir -p "$RELEASE_DIR"
DMG="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"

# 5. DMG d'installation : l'app à gauche, l'alias /Applications à droite.
DMG_VOLNAME="$APP_NAME $VERSION"
DMG_LAYOUT_DIR="$STAGING_DIR/dmg-layout"
mkdir -p "$DMG_LAYOUT_DIR"
ditto --norsrc --noextattr --noacl "$STAGING" "$DMG_LAYOUT_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_LAYOUT_DIR/Applications"

echo "→ Création d'un DMG inscriptible pour la mise en page Finder"
RW_DMG="$STAGING_DIR/temp.dmg"
hdiutil create -volname "$DMG_VOLNAME" -srcfolder "$DMG_LAYOUT_DIR" \
  -fs HFS+ -format UDRW -ov "$RW_DMG" >/dev/null

DMG_MOUNT=$(hdiutil attach -nobrowse -noverify -noautoopen "$RW_DMG" \
  | awk -F '\t' 'END {print $NF}')
echo "→ Monté sur $DMG_MOUNT — mise en page via AppleScript"

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$DMG_VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 100, 740, 460}
        set view_options to the icon view options of container window
        set arrangement of view_options to not arranged
        set icon size of view_options to 128
        set position of item "$APP_NAME.app" of container window to {140, 180}
        set position of item "Applications" of container window to {400, 180}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Le .DS_Store porte la mise en page : il doit être écrit avant le démontage.
sync
hdiutil detach "$DMG_MOUNT" -quiet

echo "→ Conversion en DMG compressé en lecture seule"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null

rm -rf "$STAGING_DIR"

# 6. Notarisation, puis agrafage du ticket pour que l'app se lance aussi sur
# une machine hors ligne.
echo "→ Envoi de $DMG au service de notarisation Apple (2 à 5 min)"
notary_run "$NOTARY_PROFILE" submit "$DMG" \
  --wait

echo "→ Agrafage du ticket de notarisation"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# 7. Signature Sparkle du DMG et régénération de l'appcast.
SPARKLE_TOOLS="$ROOT/.sparkle-tools"
if [ ! -x "$SPARKLE_TOOLS/bin/sign_update" ]; then
  echo "→ Récupération des outils Sparkle $SPARKLE_VERSION"
  mkdir -p "$SPARKLE_TOOLS"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$SPARKLE_TOOLS"
fi

echo "→ Signature de $DMG avec la clé EdDSA Sparkle"
# `sign_update` renvoie déjà : sparkle:edSignature="…" length="<octets>"
# — ne pas rajouter d'attribut `length` sur <enclosure>, il ferait doublon.
SPARKLE_SIG_LINE=$("$SPARKLE_TOOLS/bin/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")

# Sparkle compare <sparkle:version> au CFBundleVersion de l'app installée — un
# numéro de build entier, croissant — et non à la version marketing. Y écrire
# « 0.1.0 » face à un CFBundleVersion « 1 » ferait conclure au comparateur que
# [0,1,0] < [1], donc « déjà à jour ». On lit donc la valeur réelle du bundle.
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")

echo "→ Écriture de appcast.xml (sparkle:version=$BUILD_NUMBER, shortVersionString=$VERSION)"
PUB_DATE=$(date -R)
cat > "$ROOT/appcast.xml" <<APPCAST
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <link>https://raw.githubusercontent.com/vincentlauriat/$APP_NAME/main/appcast.xml</link>
    <description>$APP_NAME release feed</description>
    <language>en</language>
    <item>
      <title>v$VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/vincentlauriat/$APP_NAME/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure
        url="https://github.com/vincentlauriat/$APP_NAME/releases/download/v$VERSION/$APP_NAME-$VERSION.dmg"
        type="application/octet-stream"
        $SPARKLE_SIG_LINE />
    </item>
  </channel>
</rss>
APPCAST

DMG_SIZE=$(ls -lh "$DMG" | awk '{print $5}')
echo ""
echo "✅ Compilé, signé, notarisé, agrafé et signé Sparkle : $DMG ($DMG_SIZE)"
echo "✅ appcast.xml écrit pour v$VERSION"
echo ""
echo "Pour publier sur GitHub :"
echo "  1. gh release create v$VERSION ./release/$APP_NAME-$VERSION.dmg --title \"v$VERSION\" --notes-file release/release-notes-$VERSION.md"
echo "  2. git add appcast.xml && git commit -m 'docs: appcast for v$VERSION' && git push"
echo ""
echo "L'appcast doit être poussé sur main : c'est lui que Sparkle interroge."
