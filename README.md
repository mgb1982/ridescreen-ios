# RideScreen iOS

Aplicación iOS de RideScreen para grabar trayectos GPS, conservarlos localmente y exportarlos a GPX. La app no envía ubicación ni diagnósticos fuera del dispositivo.

## Estado

La pantalla de bienvenida se instaló y abrió anteriormente en un iPhone XS. La nueva función de grabación se ha implementado en código y dispone de tests unitarios; su comportamiento real de GPS y segundo plano todavía requiere las pruebas manuales de esta versión.

## Grabación de trayectos

La aplicación graba trayectos localmente con CoreLocation. Primero pide permiso «Al usar la app»; solicita «Siempre» únicamente después de que el usuario pulsa Empezar y ve la explicación correspondiente. Si «Siempre» no se concede, puede continuar grabando en primer plano; el registro con la pantalla bloqueada requiere el permiso de segundo plano.

Los puntos GPS se filtran por precisión horizontal (0–50 m) y antigüedad (máximo 10 segundos). Se usa la velocidad de CoreLocation cuando es válida; si no, se calcula entre puntos. No se suma distancia a velocidades inferiores a 0,5 m/s.

Los trayectos activos se escriben punto a punto en JSON Lines dentro de Application Support y se sincronizan periódicamente y al pasar la app a segundo plano. Al reabrir la aplicación se puede recuperar o descartar un trayecto interrumpido. Los trayectos finalizados se convierten al esquema JSON de RideScreen AA: `id`, `start`, `end`, `distanceMeters`, `movingTimeMs`, `maxSpeedMs` y puntos `[lat, lon, timeMs, speedMs]`. Se añaden arrays opcionales `altitudesMeters` y `horizontalAccuracyMeters` para conservar datos iOS.

La exportación GPX 1.1 incluye latitud, longitud, altitud, hora UTC y velocidad en una extensión XML RideScreen. La pantalla Diagnóstico muestra las últimas 500 líneas. Ningún dato se envía fuera del dispositivo.

El workflow ejecuta tests unitarios en el simulador además de compilar Debug y generar el IPA Release sin firma.

## Pruebas manuales en iPhone

La simulación y los tests unitarios no pueden garantizar el comportamiento del GPS real, las restricciones de segundo plano ni las decisiones del sistema sobre suspender o terminar el proceso. Antes de considerar la función validada, Manel debe comprobar:

1. Grabar unos 10 minutos andando, bloquear la pantalla y dejar RideScreen en segundo plano. Al volver, comprobar el tiempo, distancia y velocidades.
2. Forzar el cierre de RideScreen a mitad de un trayecto, volver a abrirla y recuperar el trayecto interrumpido. Comprobar que los puntos guardados antes del cierre siguen presentes.
3. Denegar el permiso «Siempre» en el diálogo del sistema. Comprobar que la app ofrece grabación solo en primer plano y explica que el registro puede detenerse al bloquear el iPhone.
4. Iniciar y detener un trayecto con permiso «Siempre» concedido y revisar la lista (fecha, duración y distancia).
5. Exportar el GPX y abrirlo en otra aplicación. Comprobar puntos, altitud, hora UTC y velocidad.
6. Abrir Diagnóstico y comprobar que aparecen inicio/parada, cambios de permiso, descartes y errores de CoreLocation; copiar o compartir el registro.

iOS no garantiza que la app reciba una notificación antes de terminarla por presión de memoria o cierre forzado. El callback de terminación solo se registra cuando el sistema lo entrega; la recuperación depende del diario incremental ya sincronizado.

## Compilación con GitHub Actions

El workflow [`.github/workflows/ios-build.yml`](.github/workflows/ios-build.yml) usa `macos-15` y Xcode 16.4 y ejecuta dos trabajos:

- **Simulador:** compila la app para iOS Simulator en Debug.
- **IPA de dispositivo:** compila en Release sin firma y empaqueta `Payload/RideScreenIOS.app` dentro de un IPA.

Cada ejecución usa `github.run_number` como `CURRENT_PROJECT_VERSION`. El artefacto se nombra `RideScreenIOS-v0.1.0-build-<número>-unsigned-IPA` y se conserva durante 7 días. El IPA es **sin firmar**: no se puede instalar directamente como una app firmada y distribuible.

Para compilar localmente, abre `ios/RideScreenIOS.xcodeproj` con Xcode en macOS. El target incluye una fase de preparación que decodifica las fuentes Archivo desde Base64 antes de compilar.

## Fuentes Archivo

Los archivos fuente están en `tools/ios-fonts/`:
- `Archivo-Regular.ttf.b64`
- `Archivo-Medium.ttf.b64`
- `Archivo-SemiBold.ttf.b64`
- `Archivo-ExtraBold.ttf.b64`
- `ArchivoBlack-Regular.ttf.b64`

Se guardan en Base64 para mantener los ficheros binarios de fuente representables como texto en Git y hacer explícito el proceso de reconstrucción. `scripts/prepare-ios-fonts.sh` usa únicamente Python estándar para decodificarlos en `ios/RideScreenIOS/Fonts/`. Los nombres PostScript, pesos y registros `UIAppFonts` se comprueban en CI mediante `scripts/validate-ios-fonts.py` y fontTools.

Las cuatro variantes Archivo usan nombres PostScript únicos. El código SwiftUI usa esos nombres exactos en `Font.custom`; Archivo Black conserva `ArchivoBlack-Regular`.

## Icono de la app

El SVG de diseño es `design/icon.svg`. El icono compilable ya generado está versionado en `ios/RideScreenIOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png` como PNG opaco RGB de 1024 × 1024.

Si cambias el SVG, ejecuta manualmente:

```sh
./scripts/generate-app-icon.sh
```

El script requiere `rsvg-convert` (librsvg) y Python con Pillow instalados previamente. No instala dependencias y no se ejecuta durante la compilación de Xcode. Revisa el resultado y versiona el PNG regenerado.

## Instalación

TODO: completar las instrucciones de instalación y firma.

No se deben añadir al repositorio certificados de firma, claves privadas, perfiles de aprovisionamiento, credenciales ni secretos de Apple.

## Licencia

GNU Affero General Public License v3.0 o posterior (**AGPL-3.0-or-later**). Consulta [`LICENSE`](LICENSE).
