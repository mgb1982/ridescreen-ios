# Pantalla de inicio · identidad de RideScreen

`inicio-1125x2436.png` es la referencia visual de la pantalla de inicio (iPhone XS, 375×812 pt @3x).
`inicio.html` es su fuente (ábrela en el navegador; los tamaños en px CSS = puntos de iOS).

## Para pasarlo a SwiftUI
- **Fuentes:** Archivo Black (títulos: marca, «Tus rutas. Tus historias.», «Lo que estamos preparando») y
  Archivo 400/500/600/700 (resto). Son las de la app Android (`ridescreen-aa/app/src/main/res/font`),
  licencia OFL. Hay que añadirlas al target e incluirlas en `UIAppFonts`. Sustituyen a AvenirNextCondensed-Heavy
  y a `.system(design: .rounded)`.
- **Colores:** los mismos tokens que ya tiene `RideScreenIOSApp.swift` (fondo `#1A231D`, superficie `#243028`,
  contorno `#3D4F42`, dorado `#D1A955`, texto `#F1F4EC`, secundario `#AEBAAA`).
- **Marca:** icono redondo (`icon.svg`, el de ridescreen.app) + «Ride» blanco y «Screen» dorado en una línea, en
  Archivo Black 24 pt; debajo «iOS EDITION» 10,5 pt, tracking 2,2.
- **Medidas clave (pt):** márgenes laterales 20; tarjeta principal 318 de alto, radio 26, borde 1,5; título 39/1,04;
  etiquetas doradas 11 pt mayúsculas, tracking 2,4; tarjetas de funciones en 3 columnas, separación 9, radio 18;
  iconos de línea dorados 24 pt, trazo 1,8.
- **Textos:** los actuales, salvo dos descripciones algo más largas: «Graba cada salida en segundo plano» y
  «Velocidad, distancia y recorrido».
- **Pantalla completa:** necesita `INFOPLIST_KEY_UILaunchScreen_Generation = YES` (PR #1); sin eso iOS la muestra
  con bordes en modo de compatibilidad.
