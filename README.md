# IPMX Phase 0 — bucle RTP puro

ScreenCaptureKit → x264 → RFC 6184 → UDP multicast → VideoToolbox → ventana.

Sin RTCP, sin NMOS, sin PTP. El objetivo de esta fase es **ver imagen**: cerrar el bucle
extremo a extremo para tener sobre qué construir la conformidad de las fases siguientes.

El plan completo y la justificación normativa están en
[IPMX-macOS-encoder-decoder.md](IPMX-macOS-encoder-decoder.md). Los PDF de VSF fijados
están en [specs/](specs/).

---

## Requisitos

- macOS 14+ (probado en macOS 26.5, Apple Silicon)
- Swift 6. Para **compilar y ejecutar** bastan las Command Line Tools; para `swift test`
  hace falta **Xcode completo**, porque XCTest y swift-testing se distribuyen con Xcode y no
  con las CLT. Si `swift test` falla con `no such module 'XCTest'`, comprueba a dónde apunta
  el toolchain:

  ```bash
  xcode-select -p
  ```

  Si responde `/Library/Developer/CommandLineTools`, cámbialo con
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- `brew install x264 pkg-config`
- Permiso de **Screen Recording** para la aplicación de terminal desde la que lances el
  encoder: System Settings → Privacy & Security → Screen Recording. macOS atribuye el
  permiso al terminal, no al binario; tras concederlo hay que reiniciar el terminal.

## Compilar

```bash
swift build -c release
```

## Probar sin red

Todo en un solo Mac, sobre loopback, sin switch ni multicast:

```bash
./scripts/run-local-loop.sh
```

O a mano, en dos terminales:

```bash
swift run ipmx-encoder --dest 127.0.0.1 --iface 127.0.0.1 --width 1280 --height 720 --fps 30
```

```bash
swift run ipmx-decoder --sdp sdp/stream.sdp --iface 127.0.0.1
```

El encoder escribe `sdp/stream.sdp` en cuanto tiene SPS/PPS; el decoder puede leer de ahí el
destino, el puerto y los parameter sets, que es lo que le entregaría una conexión IS-05 real.

## Probar en multicast

```bash
swift run ipmx-encoder --dest 239.10.10.10 --port 50000
swift run ipmx-decoder --group 239.10.10.10 --port 50000
```

Sin `--iface`, ambos eligen la primera interfaz IPv4 no-loopback activa. En un Mac con Wi-Fi
más un adaptador Thunderbolt querrás fijarla a mano. El switch necesita IGMP snooping **con
querier**; sin querier el tráfico se inunda o desaparece a los pocos minutos.

## Verificar

```bash
swift test
```

El target usa **los dos frameworks a la vez**, con un reparto deliberado:

- **swift-testing** (`import Testing`) para todo el comportamiento: 39 tests en 8 suites.
  Los casos parametrizados con `@Test(arguments:)` son la razón principal — la tabla de
  atributos que exigen las TR, los tamaños de NAL alrededor del umbral de fragmentación y
  la clasificación de tipos de NAL se expresan como datos en vez de como copia-pega, y cada
  fallo se reporta con su argumento concreto.
- **XCTest** para las medidas de rendimiento en
  [ThroughputTests.swift](Tests/IPMXCoreTests/ThroughputTests.swift). swift-testing todavía
  no tiene API de medición, así que `measure` sigue siendo la única forma de fijar líneas
  base y detectar regresiones.

Para ejecutar solo una parte:

```bash
swift test --filter "RFC 6184"
```

Cifras medidas en un M4 Pro, que son las que importan para la Fase 3: paquetizar un keyframe
de 1080p de 200 KB cuesta **~80 µs**, en torno al 0.5 % de un intervalo de frame a 60 fps.
El hilo real-time que hará el shaping CINST/CMAX tiene margen de sobra.

---

## Estructura

```
Package.swift
Sources/
  CX264/                    módulo de sistema para libx264
    module.modulemap
    shim.h                  envuelve el macro x264_encoder_open y los arrays de x264_picture_t
  IPMXCore/                 todo lo que comparten los dos extremos
    NALUnit.swift           tipos de NAL H.264, troceado Annex B, conversión a AVCC
    RTPPacket.swift         cabecera RTP fija (RFC 3550 §5.1)
    H264Packetizer.swift    RFC 6184 packetization-mode 1: Single NAL + FU-A
    H264Depacketizer.swift  reensamblado, detección de huecos de secuencia
    RTPStreamSender.swift   sella timestamps y marker bit, empuja al socket
    UDPSocket.swift         emisión/recepción UDP, membresía multicast, selección de interfaz
    MediaClock.swift        reloj de 90 kHz de marcha libre (ts-refclk:localmac)
    SDP.swift               generación y parseo mínimo, sprop-parameter-sets
    CommandLineOptions.swift
  ipmx-encoder/
    main.swift
    ScreenSource.swift      captura ScreenCaptureKit en NV12
    X264Encoder.swift       libx264
  ipmx-decoder/
    main.swift
    VideoToolboxDecoder.swift
    PlayerWindow.swift      AVSampleBufferDisplayLayer
Tests/IPMXCoreTests/
  RTPHeaderTests.swift      swift-testing: cabecera RTP y reloj de 90 kHz
  PacketizationTests.swift  swift-testing: Annex B, FU-A, round trip, pérdidas
  SDPTests.swift            swift-testing: SDP, direccionamiento, parseo de flags
  ThroughputTests.swift     XCTest: medidas de rendimiento del camino de paquetes
scripts/
  net-tuning.sh             sysctl de buffers UDP
  run-local-loop.sh
sdp/stream.sdp              generado por el encoder
```

---

## Qué ya cumple la norma, y qué no

Ya alineado con las TR, porque cambiarlo después sale caro:

- Reloj RTP de **90 kHz** y timestamp compartido por todos los paquetes de un frame (TR-10-7 §9)
- **Un solo VCL NAL por paquete UDP** (TR-10-15 §9) — nunca se agrega con STAP-A
- Puerto UDP **par y > 5000**, con aviso si lo cambias (TR-10-7 §7)
- Random access point cada ≤ 5 s, con el flag limitado a ese máximo (TR-10-15 §11)
- **Decode order = output order**, sin B-frames (TR-10-15 §10)
- Perfil **High** forzado de verdad: los presets rápidos de x264 apagan CABAC y el
  transform 8x8, y `x264_param_apply_profile` solo restringe, nunca eleva, así que
  `--preset ultrafast` produce en silencio Constrained Baseline — que TR-10-15 §12 no admite
- VUI con colorimetría BT.709 y rango limitado, coherente con el `RANGE=NARROW` del SDP
- SDP con `TP=2110TPW`, `ts-refclk:localmac`, `mediaclk:direct=0`, `b=AS:`

Deliberadamente fuera de esta fase:

| Falta | Fase | Nota |
|---|---|---|
| RTCP Sender Reports + IPMX Info Block | 2 | Nada de esto existe en ninguna librería; hay que escribirlo entero |
| HRD Type II, Buffering Period / Picture Timing SEI | 1 | `--hrd` ya enciende el señalizado de x264; falta validar el SPS |
| Traffic shaping CINST/CMAX | 3 | Necesita hilo real-time; macOS no tiene `SO_TXTIME` |
| NMOS IS-04 / IS-05 / IS-11 | 4 | `sony/nmos-cpp` cubre IS-04 e IS-05; IS-11 es propio |
| PTP | — | Innecesario mientras se opere en `ts-refclk:localmac` |
| Buffer de recepción y reordenado | 4 | Ahora se asume entrega en orden en una LAN tranquila |
| H.265 | 5 | Cambia RFC 7798, Media Info Block 0x0009, VPS, y `vui_time_scale` sin ×2 |

---

## Siguiente paso concreto

```bash
swift run ipmx-encoder --hrd --dest 127.0.0.1 --iface 127.0.0.1
```

y después volcar el SPS del stream para comprobar que
`nal_hrd_parameters_present_flag = 1`. Ese es el primer entregable de la Fase 1, y es
también la medición que decide si VideoToolbox puede llegar a sustituir a x264 en el
camino de producción.
