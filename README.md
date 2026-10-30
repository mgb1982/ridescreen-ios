# RideScreen iOS

Aplicación iOS complementaria de RideScreen, escrita en SwiftUI. El proyecto se distribuye bajo **AGPL-3.0-or-later**.

> **Estado actual:** prototipo de bienvenida/preview. La app se ha instalado y abierto en un iPhone XS; por ahora solo muestra la pantalla de presentación. No implementa todavía grabación de rutas, ubicación, importación de vídeo, superposición de telemetría ni otras funciones de RideScreen AA.

## Estado y alcance

- Plataforma objetivo: iPhone, orientación vertical.
- Bundle identifier: `com.mgb1982.RideScreenIOS`.
- Versión de marketing: `0.1.0`.
- La pantalla usa el sistema visual RideScreen y la familia tipográfica Archivo.
- El proyecto conserva la configuración de launch screen de Xcode para iniciar a pantalla completa.
- No se incluyen certificados, perfiles de aprovisionamiento, claves, cuentas de Apple ni secretos.

## Compilación

La compilación CI se ejecuta en GitHub Actions sobre `macos-15` y selecciona explícitamente Pinned Xcode. Consulta [ios-build.yml](.github/workflows/ios-build.yml) para ver la versión fijada.

El workflow produce dos comprobaciones:

1. **iOS Simulator:** compilación Debug sin firma.
2. **Dispositivo físico:** compilación Release sin firma, empaquetada como IPA.

El número de ejecución de GitHub Actions se pasa como `CURRENT_PROJECT_VERSION`, por lo que cada IPA tiene un número de build distinto. El artefacto se publica con un nombre de la forma:

`RideScreenIOS-v0.1.0-build-N-unsigned-IPA`

El IPA es **unsigned**. El workflow no firma la app ni crea certificados o perfiles de aprovisionamiento.

Para compilar manualmente desde un Mac con Xcode seleccionado y las dependencias indicadas más abajo:

```bash
./scripts/prepare-ios-fonts.sh

xcodebuild \
  -project ios/RideScreenIOS.xcodeproj \
  -scheme RideScreenIOS \
  -sdk iphonesimulator \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

La fase de preparación del target ejecuta únicamente `scripts/prepare-ios-fonts.sh`: decodifica los archivos TTF desde Base64 con Python estándar. No instala herramientas ni genera recursos gráficos.

## Fuentes Archivo

Los cinco archivos de fuente de entrada están en `tools/ios-fonts/`:

- `Archivo-Regular.ttf.b64`
- `Archivo-Medium.ttf.b64`
- `Archivo-SemiBold.ttf.b64`
- `Archivo-ExtraBold.ttf.b64`
- `ArchivoBlack-Regular.ttf.b64`

Se almacenan en Base64 para mantener los TTF como recursos de texto portables y reproducibles dentro del repositorio. Antes de compilar, CI usa **fontTools** para normalizar los metadatos de Archivo, decodifica los TTF a `ios/RideScreenIOS/Fonts/` y valida sus nombres PostScript. También comprueba que `UIAppFonts` y los nombres usados por `Font.custom` coincidan.

Los cuatro pesos de Archivo tienen nombres PostScript distintos. `ArchivoBlack-Regular` se conserva sin modificar. La licencia OFL de las fuentes se encuentra junto a los recursos en `ios/RideScreenIOS/Fonts/OFL-Archivo.txt`.

Scripts relacionados:

- `scripts/repair-archivo-fonts.py`: normaliza los nombres y pesos usando fontTools.
- `scripts/prepare-ios-fonts.sh`: decodifica Base64 a TTF usando únicamente Python estándar.
- `scripts/validate-ios-fonts.py`: valida los cinco nombres PostScript y su correspondencia con Info.plist y SwiftUI.

## Icono de la aplicación

El recurso vectorial fuente está en `design/icon.svg`. Cuando se modifique ese SVG, regenera el icono de iOS y confirma el PNG resultante en el repositorio:

```bash
brew install librsvg
python3 -m pip install Pillow
./scripts/generate-app-icon.sh
git add ios/RideScreenIOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

El generador crea un PNG opaco RGB de 1024 × 1024, sin canal alfa. La generación se mantiene separada de la fase de compilación de Xcode; CI ejecuta el script como paso previo para validar y compilar el recurso derivado.

## Localización

La pantalla inicial usa el String Catalog `ios/RideScreenIOS/Localizable.xcstrings`, con español como idioma base y traducciones para catalán e inglés. La estructura queda preparada para añadir otros idiomas posteriormente.

## Instalación

TODO: documentar aquí el procedimiento de instalación que decida el mantenedor.

## Licencia

AGPL-3.0-or-later. Consulta [LICENSE](LICENSE).
