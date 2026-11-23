# peaktime

App de barra de menú para macOS que avisa cuando la API de DeepSeek entra/sale de **hora pico** (precio doble). Todo se construye desde terminal, sin abrir Xcode.

## Reglas implementadas

Fuente: <https://api-docs.deepseek.com/quick_start/pricing/>

- **Doble:** 01:00–04:00 y 06:00–10:00 **UTC**, lunes a viernes.
- **Mitad de precio:** todo lo demás, incluidos fines de semana y festivos chinos.
- La regla se evalúa siempre en **UTC**, sin husos hardcodeados. En Tijuana equivale a **17:00–20:00 y 22:00–02:00** en invierno (UTC−8) y **18:00–21:00 y 23:00–03:00** en verano (UTC−7), pero la app funciona igual en cualquier país.
- **La decisión de precio no depende del huso de la Mac**; solo la presentación. Los textos usan `TimeZone.autoupdatingCurrent`, así que se adaptan al país del usuario y reaccionan si el sistema cambia de zona con la app abierta (observador `NSSystemTimeZoneDidChange`).
- `Asia/Shanghai` sí queda fijo a propósito: los festivos chinos se definen en fecha de Pekín.
- Aplica solo a la API (`api.deepseek.com`); el chat web/app no tiene cobre doble por hora.

La lógica vive en `Sources/PeakTimeCore` y los festivos chinos (2026–2027) en `ChineseHolidays.swift`. **Actualizar esa lista cada año** cuando DeepSeek/timeanddate publiquen el calendario siguiente.

## Comandos

```bash
./build.sh                  # compila, arma dist/peaktime.app y lo firma
swift test                  # 19 tests de fecha/zona/transiciones/línea de tiempo
open dist/peaktime.app      # abrir
pkill -x peaktime           # cerrar
cp -R dist/peaktime.app /Applications/   # instalar (opcional)
```

## Comportamiento

- La barra superior muestra `Barato · 3h45m` o `Doble · 1h20m` (tiempo hasta el próximo cambio).
- El menú es intencionalmente mínimo: **cuenta atrás** (`Faltan 1h 28m para precio doble`), **barra horizontal** de 8 h desde ahora (🟢 verde = mitad de precio, 🟠 naranja = precio doble), **hora local en que empieza el siguiente tramo** (`Empieza: lun 23 nov 17:00`) y **Salir**. Nada más.
- El menú es **AppKit puro** (`NSStatusItem` + `NSMenu`): `MenuBarExtra` de SwiftUI descartaba la vista personalizada y la barra nunca aparecía. Ahora la barra es un `NSMenuItem` con una `NSView` nativa dibujada con `NSBezierPath` (ancho fijo de 240 px, extremos redondeados). El ancho de cada bloque es proporcional a su duración real: si el próximo pico está a más de 8 h sale toda verde; al acercarse el verde se acorta y el naranja crece (y al revés durante el pico).
- Cada 1 s se recalcula la cuenta atrás y la línea de tiempo. Avisos (una vez por transición, con dedup en `UserDefaults`):
  - `⏰ DeepSeek sube en 15 min`
  - `⚠️ Precio doble en DeepSeek`
  - `✅ Mitad de precio en DeepSeek`
- **Los avisos solo funcionan mientras la app está abierta** (no se programan notificaciones del sistema para cuando esté cerrada).

## Prueba rápida de avisos sin esperar

Se puede adelantar el reloj de la app con una variable de entorno (ISO 8601, UTC):

```bash
pkill -x peaktime
defaults delete com.local.peaktime peaktime.lastNotified
env PEAKTIME_SIMULATE=2026-11-23T00:59:00Z open dist/peaktime.app
/usr/bin/log show --last 2m --info --style compact | grep 'Aviso enviado'
```

A ese valor le quedan 60 s para el pico de las 01:00 UTC: dispara el pre-aviso al arrancar y el aviso de "doble" al minuto. Al terminar, borra la preferencia y vuelve a abrir sin la variable.
